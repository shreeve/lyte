// Session: the host's session stub (HS-7) — the sans-IO core that
// assembles the full send path into one live Lyte-UDP stream and feeds
// J-G1. It owns, in one place:
//
//   • the Noise IK handshake as RESPONDER (W5): consume the client's
//     message 1, produce message 2, derive the NoiseTransport. The
//     client knows the host's static out-of-band (pinned at pairing;
//     printed by the executable for the J-G1 debug client). There is no
//     hello beyond the handshake — IK's own payloads carry the version
//     byte (W5's first-payload rule), and the session-start beacon is
//     the host's first sealed word.
//   • the seal discipline: every outbound datagram — video shards from
//     VideoChannel, beacons, path challenges, later audio — is sealed
//     under the transport with the exact header bytes (fixed envelope +
//     TLV block) as AAD, mirroring the client seam (CL-1/CL-3) so both
//     directions speak identical crypto. `--insecure` (CP-3 fallback,
//     §4.1) is the same wiring with a passthrough seal; the default is
//     Noise, and geometry/pacing are mode-identical by construction.
//   • the 1 Hz clock beacon on CTRL (§4.6, W4a): beaconSeq from 0 at
//     session start plus one beacon at establishment; t1 is the host
//     graph-clock µs the caller injects. Client BeaconEchoes come back
//     sealed; each yields one offset/RTT sample (NTP arithmetic in the
//     codec) and the next beacon mirrors the last echo per W4a's layout.
//   • HS-12 integration: the session mints its ConnectionId, every
//     outbound datagram carries the TLV, inbound datagrams feed the
//     PathValidator's demux trigger, challenges ride CTRL to the exact
//     unvalidated tuple, and `takeFreshKeyframeRequest()` merges the
//     validator's promotion IDR with client 0x10 IDR requests into one
//     encoder-loop poll.
//   • HS-6 integration: all traffic classes through one Pacer schedule
//     (VideoChannel owns it; control enters via `enqueueControl`).
//   • HS-8 integration: reliable CTRL rides an `ArqEndpoint` (W3).
//     `sendReliable`/`sendReliableOneShot` queue messages; inbound
//     payloads whose first byte is 0x07/0x08 route wholly to
//     `ArqEndpoint.ingest` (the one-byte peek); delivered messages and
//     one-shot acknowledgments surface as events. ARQ datagrams are
//     sealed CTRL like everything else — conn-id TLV, header-as-AAD,
//     the control pacer class — which is why the endpoint's output
//     repacks to the session's real 1101 B plaintext budget (the HS-7
//     accounting fix, applied to the reliable sublayer: poll packs to
//     the bare 1112 B table, exact only without TLV + tag). The
//     deliberately ARQ-EXEMPT registry traffic is untouched: beacons
//     and echoes are time-sensitive samples (a late beacon is a lie),
//     path messages must travel on the exact unvalidated tuple
//     (HS-12), handshake datagrams predate the transport, and a lost
//     IDR request is superseded by the requester's next coalesced
//     emission. ARQ retransmit timers ride the session's wake
//     machinery: `nextWake` folds the endpoint's PTO deadline in, and
//     `advance` services it — on the Linux host that is the idle-floor
//     tick, the between-frames service point.
//
// Sans-IO in the house style: no sockets, no threads, no clock. Entry
// points take `now` (monotonic ns — the pacer/validator domain) and
// `hostMicroseconds` (the PipeWire graph-clock µs — the envelope
// timestamp and beacon-t1 domain); outputs leave through the injected
// send sink as `VideoChannelDatagram`s in pacer order, and everything
// the caller must react to comes back as `SessionEvent` values. The
// Linux loop (lyte-host) is deliberately thin over this; the macOS gate
// test drives the whole session in-process against a LyteWire initiator.

import HostCore
import LyteWire

/// How the session's transport keys come to exist.
public enum SessionCryptoMode: Sendable {
    /// Real Noise IK (the default): the host responds with this pinned
    /// static keypair; the transport derives from the completed
    /// handshake.
    case noise(hostStatic: NoiseKeyPair)
    /// The CP-3 recorded `--insecure` fallback (§4.1): passthrough seal,
    /// no handshake — the session is established from init and streams
    /// to the configured peer. Same wiring, same geometry, mandatory
    /// re-gate with Noise.
    case insecure
}

public struct SessionConfig: Sendable {
    public var crypto: SessionCryptoMode
    /// Pacer rate; the configured session ceiling until HS-16 negotiates.
    public var rateBitsPerSecond: Int
    public var regime: FecRegime
    public var pacerQuantumNS: UInt64
    /// §4.6: 1 Hz. A beacon also goes out at establishment.
    public var beaconIntervalNS: UInt64
    public var path: PathValidatorConfig
    /// The reliable-CTRL sublayer's knobs (HS-8). The session clamps
    /// `maxSegmentBodyByteCount` to its own CTRL plaintext budget
    /// (1101 B with the conn-id TLV + AEAD tag) at init — a caller
    /// cannot configure a segment that would burst a datagram.
    public var arq: ArqConfig
    /// When set, a completing handshake whose authenticated client
    /// static is not in this set is rejected. Nil accepts any static —
    /// honest for the stub: pairing (W6 PIN-PAKE) is what mints this
    /// set, and J-G1 runs statics-pinned-out-of-band in both directions.
    public var allowedClientStaticPublicKeys: [[UInt8]]?
    /// The pre-handshake flood throttle (HS-9): message 1s beyond this
    /// budget are dropped before any Noise state is allocated.
    public var handshakeGate: HandshakeGate.Config
    /// What this host declares in the W7 capability exchange. The
    /// declaration is the session's FIRST ARQ-carried message
    /// post-establishment; the agreed set is the intersection with the
    /// client's declaration.
    public var capabilities: Capabilities
    /// The W4b lifecycle machine's knobs: the 350 ms blackout detector,
    /// the 30 s liveness clock, RECOVERY's clean-window count.
    public var lifecycle: SessionMachineConfig

    public init(
        crypto: SessionCryptoMode,
        rateBitsPerSecond: Int,
        regime: FecRegime = .clean,
        pacerQuantumNS: UInt64 = 1_000_000,
        beaconIntervalNS: UInt64 = 1_000_000_000,
        path: PathValidatorConfig = PathValidatorConfig(),
        arq: ArqConfig = ArqConfig(),
        allowedClientStaticPublicKeys: [[UInt8]]? = nil,
        handshakeGate: HandshakeGate.Config = HandshakeGate.Config(),
        capabilities: Capabilities = .wireDefault,
        lifecycle: SessionMachineConfig = SessionMachineConfig()
    ) {
        self.crypto = crypto
        self.rateBitsPerSecond = rateBitsPerSecond
        self.regime = regime
        self.pacerQuantumNS = pacerQuantumNS
        self.beaconIntervalNS = beaconIntervalNS
        self.path = path
        self.arq = arq
        self.allowedClientStaticPublicKeys = allowedClientStaticPublicKeys
        self.handshakeGate = handshakeGate
        self.capabilities = capabilities
        self.lifecycle = lifecycle
    }
}

/// What the caller must know about. Values, not callbacks — the loop
/// executes/logs them in order (the PathValidator precedent).
public enum SessionEvent: Equatable, Sendable {
    /// The Noise handshake completed; the transport is live. The key is
    /// the client's authenticated static — the identity pairing checks.
    case handshakeCompleted(remoteStaticPublicKey: [UInt8])
    case beaconSent(beaconSeq: UInt32)
    /// One echo consumed: one raw offset/RTT sample recorded (filtering
    /// is CL-10's HostClockModel on the client; the host keeps the
    /// min-RTT-gated estimate for logs and glass-to-glass math).
    case beaconEchoAccepted(
        beaconSeq: UInt32,
        offsetMicroseconds: Int64,
        rttMicroseconds: Int64
    )
    /// A client 0x10 arrived; `takeFreshKeyframeRequest()` is now true.
    case idrRequested(IdrRequest)
    /// The ARQ delivered one reliable CTRL message — exactly once, in
    /// order within its group (HS-8). The bytes start with the
    /// message's own CTRL type byte; dispatch registers types as the
    /// reliable consumers (capabilities at W7, mode transitions at
    /// HS-11) land.
    case reliableCtrl(group: ArqGroupId, message: [UInt8])
    /// A one-shot group this session sent is fully acknowledged — the
    /// HS-11 "final frame landed, flip to IDLE" signal, surfaced.
    case reliableOneShotAcknowledged(ArqGroupId)
    /// The ARQ endpoint ignored (part of) an ingested payload. Some
    /// reasons are routine protocol weather (a duplicate from a
    /// retransmit crossing its ACK); the shell decides what to log.
    case arqIgnored(ArqIgnoreReason)
    case path(PathValidatorEvent)
    case dropped(SessionDropReason)
    /// An outbound build step refused (seal before establishment, a
    /// budget breach) — loud, because control sends must never fail
    /// silently, but never fatal to the session.
    case sendFailed(String)
    /// The W7 exchange settled: both declarations met, this is the
    /// session's agreed set (the intersection).
    case capabilitiesAgreed(Capabilities)
    /// The peer's declaration produced an unworkable intersection (no
    /// common video codec / chroma mode) — the typed teardown follows
    /// in the same event batch.
    case capabilitiesFailed(String)
    /// The client answered our outstanding renegotiation proposal
    /// (0x12). On accept the operative datagram ceiling already moved;
    /// apply at the next IDR boundary.
    case capabilityUpdateAcknowledged(accepted: Bool)
    /// A ModeTransition (0x09) left on the reliable stream — the
    /// mediaSender's ACTIVE⇄IDLE flip, as the wire hears it.
    case modeTransitionSent(SessionWireMode)
    /// The converged ratchet frame left on its reliable one-shot group
    /// (HS-11). Its `.reliableOneShotAcknowledged` is the idle flip.
    case finalFrameSent(ArqGroupId)
    /// A typed SessionTeardown (0x0A) left on the reliable stream.
    case teardownSent(SessionTeardownReason)
    /// The W4b machine changed state (wire modes and the local
    /// FROZEN/RECOVERY overlay both surface here).
    case lifecycleChanged(SessionState)
    /// The session reached `closed`: a teardown either way, or the
    /// 30 s liveness timeout (which sends nothing — the peer that
    /// would read the message is the one that died).
    case sessionClosed(SessionCloseReason)
}

/// Why an inbound datagram went no further. Counted and surfaced, never
/// thrown — hostile bytes must not unwind the receive loop.
public enum SessionDropReason: Equatable, Sendable {
    case malformedEnvelope
    case reservedChannel(UInt8)
    /// Payload traffic before the handshake completed (carries the
    /// channel). In Noise mode only bare message 1 is admissible first.
    case notEstablished(UInt8)
    case unsealFailed(UInt8)
    case malformedCtrl
    case unexpectedCtrlType(UInt8)
    case unhandledChannel(UInt8)
    case handshakeFailed(String)
    case duplicateConnectionIdTlv
    /// A message 1 beyond the HandshakeGate budget: dropped unread,
    /// before any Noise state was allocated (HS-9's flood posture).
    case handshakeThrottled
}

public enum SessionError: Error, Equatable, Sendable {
    /// Video cannot flow before the transport exists.
    case notEstablished
}

/// Raw clock-mapping samples from the beacon/echo exchange.
public struct SessionClockStats: Equatable, Sendable {
    public var samples = 0
    public var lastOffsetMicroseconds: Int64?
    public var lastRttMicroseconds: Int64?
    public var minRttMicroseconds: Int64?
    /// The offset carried by the min-RTT sample — the least
    /// queue-polluted estimate (the min-filter idea, one sample deep).
    public var minRttOffsetMicroseconds: Int64?

    public init() {}
}

public struct SessionCounters: Equatable, Sendable {
    public var datagramsReceived = 0
    public var dropped = 0
    public var unsealFailures = 0
    public var beaconsSent = 0
    public var beaconEchoes = 0
    public var idrRequests = 0
    /// Reliable CTRL messages the ARQ delivered (HS-8).
    public var arqMessages = 0
    /// Ingested ARQ bytes the endpoint refused or deduplicated.
    public var arqIgnored = 0
    /// Sealed CTRL datagrams carrying ARQ frames, both fresh and
    /// retransmit — the loss-gate's retransmission evidence.
    public var arqDatagramsSent = 0
    /// Chan 3 arrivals: counted, not parsed — the estimator is HS-16.
    public var feedbackDatagrams = 0
    /// Message 1s the HandshakeGate refused (HS-9's flood evidence).
    public var handshakesThrottled = 0
    /// Video frames the lifecycle machine refused to put on the wire
    /// (FROZEN's freezeDatagramSends, or a closed session).
    public var videoFramesSuppressed = 0
    /// ModeTransitions emitted (HS-11's live evidence).
    public var modeTransitionsSent = 0

    public init() {}
}

public final class Session {
    public enum Phase: Equatable, Sendable {
        case awaitingHandshake
        case established
    }

    public let config: SessionConfig
    /// Minted at init; rides every outbound datagram as TLV 0x01.
    public let connectionId: ConnectionId
    /// HS-12's decision machine; public for the loop's routing queries
    /// (primary tuple, send allowances) and the tests' state checks.
    public let validator: PathValidator
    public private(set) var phase: Phase
    public private(set) var clock = SessionClockStats()
    public private(set) var counters = SessionCounters()

    /// The completed Noise handshake's transcript hash — the sid the
    /// W6 pairing run binds to (decision §8.2). Nil before
    /// establishment and in insecure mode (nothing to pair against).
    public var handshakeHash: [UInt8]? { transport?.handshakeHash }

    private var channel: VideoChannel!
    /// Nil until the handshake completes; always nil in insecure mode.
    private var transport: NoiseTransport?

    private var ctrlSeq = ChannelSeq(rawValue: 0)
    private var nextVideoFrameNumber = FrameNumber(rawValue: 0)

    /// The reliable CTRL sublayer (HS-8). Host clock domain: the
    /// endpoint's instants derive from the loop's monotonic `now`
    /// (µs = ns/1000) — the same CLOCK_MONOTONIC family the host-µs
    /// beacon/envelope domain bottoms out in on Linux.
    private var arq: ArqEndpoint<HostClock>
    /// The endpoint's next PTO deadline, in the `now` ns domain.
    private var nextArqWakeNS: UInt64?
    /// The session's CTRL plaintext ceiling: 1101 B with the conn-id
    /// TLV block and the AEAD tag both on every datagram (the HS-7
    /// accounting fix). ARQ poll output repacks to this.
    private let arqPayloadBudget: Int

    /// Message-1 admissions, consulted before any handshake allocation.
    private var handshakeGate: HandshakeGate

    private var beaconSeq: UInt32 = 0
    private var nextBeaconAt: UInt64?
    private var lastEcho: ClockBeacon.LastEcho?
    private var clientKeyframePending = false

    // MARK: HS-11 lifecycle + W7 capabilities state

    /// The W4b machine, mediaSender role — nil until establishment
    /// (the machine "begins at establishment, in ACTIVE").
    private var machine: SessionStateMachine<HostClock>?
    /// The machine's next poll deadline, in the `now` ns domain.
    private var machineDeadlineNS: UInt64?
    /// The W7 negotiation machine, host role.
    private var negotiator: CapabilityNegotiator
    private var capabilitiesDeclared = false
    /// FROZEN's freezeDatagramSends: video ingest suppressed until
    /// RECOVERY's resume.
    private var videoFrozen = false
    /// A machine-demanded IDR (WAKE's arm or RECOVERY's force), merged
    /// into `takeFreshKeyframeRequest`. The pacing name is retained for
    /// the HS-16 estimator; until it exists the pacer rate is the
    /// configured ceiling either way.
    private var machineIdrPacing: IdrPacing?
    /// The converged ratchet frame awaiting its one-shot ride.
    private var convergedFrame:
        (annexB: [UInt8], frame: FrameNumber, captureMicros: UInt64)?
    /// The in-flight final-frame one-shot; its full acknowledgment is
    /// the machine's `.finalFrameAcknowledged`.
    private var finalFrameGroup: ArqGroupId?
    /// One-shot group ids are session-allocated, serially ascending.
    private var nextOneShotGroup: UInt16 = 1
    /// The RECOVERY window stub's last window boundary (see
    /// `recoveryWindowTick`).
    private var recoveryWindowNS: UInt64?

    /// The lifecycle machine's state; nil before establishment.
    public var lifecycleState: SessionState? { machine?.state }
    /// The wire mode beneath any overlay; nil before establishment.
    public var wireMode: SessionWireMode? { machine?.wireMode }
    /// Why the session closed, once it has.
    public var sessionCloseReason: SessionCloseReason? { machine?.closeReason }
    /// The agreed capability set; nil until the client's declaration
    /// lands (the CL-7 client does not send one yet — nil is the
    /// grandfathered pre-W7 posture, not an error).
    public var agreedCapabilities: Capabilities? { negotiator.agreed }

    /// - Parameters:
    ///   - clientTuple: the peer's 4-tuple at session start — the
    ///     validator's initial (trusted) path. In Noise mode this is
    ///     where message 1 arrived from; in insecure mode the fixed
    ///     configured peer.
    ///   - send: receives every outbound datagram in pacer order. The
    ///     loop maps `pacerClass` → TOS and `destination` (nil = the
    ///     primary path) → the socket call.
    public init(
        config: SessionConfig,
        clientTuple: FourTuple,
        now: UInt64,
        rng: some RandomNumberGenerator = SystemRandomNumberGenerator(),
        send: @escaping (VideoChannelDatagram) -> Void
    ) {
        var rng = rng
        self.config = config
        self.connectionId = ConnectionId.random(using: &rng)
        // Every session datagram carries the conn-id TLV (11 B) and
        // reserves the AEAD tag (16 B) — insecure mode included, the
        // §4.2 geometry rule — so the reliable sublayer's segments must
        // fit 1101 B, not the bare table's 1112 B.
        self.arqPayloadBudget = min(
            WireBudget.maxPlaintextShardByteCount,
            WireBudget.maxWirePayloadByteCount
                - WireBudget.aeadTagByteCount
                - (1 + 2 + ConnectionId.byteCount)
        )
        var arqConfig = config.arq
        arqConfig.maxSegmentBodyByteCount = min(
            arqConfig.maxSegmentBodyByteCount,
            arqPayloadBudget - ArqBounds.segmentHeaderByteCount
        )
        self.arq = ArqEndpoint(channel: .ctrl, config: arqConfig)
        self.handshakeGate = HandshakeGate(config: config.handshakeGate)
        self.negotiator = CapabilityNegotiator(
            role: .host, local: config.capabilities
        )
        self.validator = PathValidator(
            connectionId: connectionId,
            initialPath: clientTuple,
            now: now,
            config: config.path,
            rng: rng
        )
        switch config.crypto {
        case .noise:
            self.phase = .awaitingHandshake
        case .insecure:
            // No handshake to wait for; the session-start beacon (and
            // the capability declaration) leave on the first `advance`.
            self.phase = .established
            self.nextBeaconAt = now
            self.machine = SessionStateMachine(
                role: .mediaSender,
                config: config.lifecycle,
                now: HostTimestamp(microseconds: now / 1_000)
            )
        }
        self.channel = VideoChannel(
            config: VideoChannelConfig(
                channel: .videoActive,
                regime: config.regime,
                rateBitsPerSecond: config.rateBitsPerSecond,
                pacerQuantumNS: config.pacerQuantumNS,
                connectionId: connectionId
            ),
            now: now,
            seal: { [unowned self] plaintext, aad, envelope in
                try self.sealPayload(plaintext, aad: aad, envelope: envelope)
            },
            send: send
        )
    }

    // MARK: Inbound

    /// Feeds one raw received datagram. Never throws: hostile bytes
    /// become `.dropped` events (the demux doctrine).
    public func receive(
        _ datagram: ArraySlice<UInt8>,
        from tuple: FourTuple,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        counters.datagramsReceived += 1

        let envelope: Envelope
        let payload: ArraySlice<UInt8>
        do {
            (envelope, payload) = try Envelope.decode(datagram)
        } catch {
            counters.dropped += 1
            return [.dropped(.malformedEnvelope)]
        }
        guard !envelope.channel.isReserved else {
            counters.dropped += 1
            return [.dropped(.reservedChannel(envelope.channel.rawValue))]
        }

        let claimed: ConnectionId?
        do {
            claimed = try ConnectionId.decode(extensions: envelope.extensions)
        } catch {
            counters.dropped += 1
            return [.dropped(.duplicateConnectionIdTlv)]
        }

        // The HS-12 demux trigger fires on the raw arrival, before any
        // unseal — path probing must work exactly when decryption of a
        // migrated datagram would (the challenge, not the AEAD, proves
        // the address).
        var events = process(
            validator.datagramReceived(
                from: tuple,
                connectionId: claimed,
                byteCount: datagram.count,
                now: now
            ),
            now: now,
            hostMicroseconds: hostMicroseconds
        )

        if phase == .awaitingHandshake {
            guard case .noise(let hostStatic) = config.crypto else {
                counters.dropped += 1 // unreachable: insecure never waits
                events.append(.dropped(.notEstablished(envelope.channel.rawValue)))
                return events
            }
            guard envelope.channel == .ctrl,
                  payload.first == CtrlMessageType.noiseHandshake1
            else {
                counters.dropped += 1
                events.append(.dropped(.notEstablished(envelope.channel.rawValue)))
                return events
            }
            guard handshakeGate.admit(now: now) else {
                counters.dropped += 1
                counters.handshakesThrottled += 1
                events.append(.dropped(.handshakeThrottled))
                return events
            }
            events += completeHandshake(
                message1: payload.dropFirst(),
                hostStatic: hostStatic,
                now: now,
                hostMicroseconds: hostMicroseconds
            )
            return events
        }

        // Established: exact received header bytes as AAD, then unseal.
        let aad = datagram[datagram.startIndex..<payload.startIndex]
        let plaintext: [UInt8]
        do {
            plaintext = try unsealPayload(payload, aad: aad, envelope: envelope)
        } catch {
            counters.unsealFailures += 1
            events.append(.dropped(.unsealFailed(envelope.channel.rawValue)))
            return events
        }

        switch envelope.channel {
        case .ctrl:
            // Any authenticated CTRL arrival is liveness/FROZEN-exit
            // evidence, but deliberately NOT the 350 ms detector's
            // (W4b: 1 Hz beacons cannot drive a 350 ms detector).
            events += runMachine(
                .ctrlEvidence, now: now, hostMicroseconds: hostMicroseconds
            )
            events += dispatchCtrl(
                plaintext, from: tuple,
                now: now, hostMicroseconds: hostMicroseconds
            )
        case .feedback:
            counters.feedbackDatagrams += 1
            // The media-path proof stream: feeds the blackout detector.
            events += runMachine(
                .mediaPathEvidence, now: now, hostMicroseconds: hostMicroseconds
            )
            events += recoveryWindowTick(
                now: now, hostMicroseconds: hostMicroseconds
            )
        default:
            counters.dropped += 1
            events.append(.dropped(.unhandledChannel(envelope.channel.rawValue)))
        }
        return events
    }

    public func receive(
        _ datagram: [UInt8],
        from tuple: FourTuple,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        receive(datagram[...], from: tuple,
                now: now, hostMicroseconds: hostMicroseconds)
    }

    // MARK: Video

    /// One encoded frame into the sealed, paced, conn-id-tagged stream.
    /// The session owns frame numbering (from 0). Throws
    /// `SessionError.notEstablished` before the transport exists, and
    /// whatever the packetize/seal path throws — loud, per W2.
    @discardableResult
    public func ingestVideoFrame(
        _ annexB: [UInt8],
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        now: UInt64
    ) throws -> Int {
        guard phase == .established else {
            throw SessionError.notEstablished
        }
        // FROZEN's freezeDatagramSends (and the terminal state): the
        // encoder may keep producing, the wire goes quiet. Suppressed
        // frames are counted, never thrown — the loop must not die
        // because the path did.
        if videoFrozen || machine?.state == .closed {
            counters.videoFramesSuppressed += 1
            return 0
        }
        let shards = try channel.ingest(
            frame: annexB,
            frameNumber: nextVideoFrameNumber,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            isKeyframe: isKeyframe,
            now: now
        )
        nextVideoFrameNumber = nextVideoFrameNumber.next
        return shards
    }

    /// The encoder-loop poll (one per tick, before encoding): true when
    /// a fresh IDR is owed — HS-12's path promotion, a client 0x10 IDR
    /// request, or the lifecycle machine's demand (WAKE's
    /// armNextDamageAsIdr, RECOVERY's forceIdr). Clears every source;
    /// fires once per demand.
    public func takeFreshKeyframeRequest() -> Bool {
        let fromValidator = validator.takeFreshKeyframeRequest()
        let fromClient = clientKeyframePending
        let fromMachine = machineIdrPacing != nil
        clientKeyframePending = false
        machineIdrPacing = nil
        return fromValidator || fromClient || fromMachine
    }

    // MARK: Lifecycle inputs (HS-11)

    /// The encoder loop's damage note: call when a FRESH damage frame
    /// arrives from capture, BEFORE encoding it. In IDLE this is the
    /// WAKE — mode=active leaves on the reliable stream and the damage
    /// frame is owed as an IDR (`takeFreshKeyframeRequest` turns true,
    /// paced at the healthy-path rate once HS-16 owns numbers). In
    /// ACTIVE it aborts a pending idle flip: new damage during the
    /// convergence handoff means the session never left ACTIVE.
    public func noteDamage(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        convergedFrame = nil
        return runMachine(.damage, now: now, hostMicroseconds: hostMicroseconds)
    }

    /// The HS-13 seam: an injected input event pre-arms the wake IDR
    /// before its damage exists (W4b's pre-arm rule — a keypress during
    /// a blackout persists through FROZEN and is consumed exactly once
    /// by RECOVERY's IDR). No caller until input lands.
    public func notePreArmInput(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        runMachine(.preArmInput, now: now, hostMicroseconds: hostMicroseconds)
    }

    /// The ratchet's all-skip stop (HS-3's detector via HS-11): retains
    /// the final converged frame and starts the idle handoff — the
    /// frame rides a reliable one-shot group, and ONLY its full
    /// acknowledgment flips the wire mode to IDLE (the receiver must
    /// hold the converged frame before it learns the session went
    /// idle). When the agreed capabilities say the client does not
    /// speak idle silence, the session stays ACTIVE.
    public func noteRatchetConverged(
        finalFrame annexB: [UInt8],
        captureTimestampMicroseconds: UInt64,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        if let agreed = negotiator.agreed, !agreed.idleSilence { return [] }
        guard !annexB.isEmpty, nextVideoFrameNumber.rawValue > 0 else {
            return []
        }
        convergedFrame = (
            annexB,
            FrameNumber(rawValue: nextVideoFrameNumber.rawValue &- 1),
            captureTimestampMicroseconds
        )
        return runMachine(
            .ratchetConverged, now: now, hostMicroseconds: hostMicroseconds
        )
    }

    /// An orderly local close: the typed SessionTeardown leaves on the
    /// reliable stream and the machine closes. The teardown segment
    /// retransmits until acknowledged — keep servicing `advance` until
    /// `arqIsQuiescent` (or patience runs out) before exiting.
    public func beginTeardown(
        reason: SessionTeardownReason, now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        runMachine(
            .teardownRequest(reason),
            now: now, hostMicroseconds: hostMicroseconds
        )
    }

    // MARK: Reliable CTRL (HS-8)

    /// Queues one message on the reliable ordered CTRL stream (ARQ
    /// group 0): exactly-once, in-order delivery, RTT-adaptive
    /// retransmit until acknowledged. The message must start with its
    /// own CTRL type byte (the registry rule). Throws
    /// `SessionError.notEstablished` before the transport exists —
    /// reliable CTRL is sealed traffic — and `ArqSendError` for an
    /// empty or over-budget message.
    public func sendReliable(
        _ message: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) throws {
        guard phase == .established else {
            throw SessionError.notEstablished
        }
        try arq.send(message: message, now: arqInstant(now))
        _ = serviceArq(now: now, hostMicroseconds: hostMicroseconds)
    }

    /// Queues one one-shot group's single message (non-zero, serially
    /// ascending group ids — caller-allocated). The group retransmits
    /// independently of the ordered stream and of every other one-shot;
    /// full acknowledgment surfaces as `.reliableOneShotAcknowledged`.
    public func sendReliableOneShot(
        _ message: [UInt8],
        group: ArqGroupId,
        now: UInt64,
        hostMicroseconds: UInt64
    ) throws {
        guard phase == .established else {
            throw SessionError.notEstablished
        }
        try arq.sendOneShot(message: message, group: group, now: arqInstant(now))
        _ = serviceArq(now: now, hostMicroseconds: hostMicroseconds)
    }

    /// True when the reliable sublayer has nothing left to send,
    /// retransmit, or acknowledge (the W-G4 termination property,
    /// exposed for the loop's idle accounting and the gate tests).
    public var arqIsQuiescent: Bool { arq.isQuiescent }

    private func arqInstant(_ now: UInt64) -> HostTimestamp {
        HostTimestamp(microseconds: now / 1_000)
    }

    /// Ingest events → session events, with the counters kept honest.
    /// Lifecycle (0x09/0x0A) and capability (0x0F/0x11/0x12) messages
    /// are consumed here — the session IS their registered consumer
    /// (the HS-9 dispatch pattern, one layer down); everything else
    /// (the pairing quartet, future types) surfaces as `.reliableCtrl`
    /// for the shell.
    private func absorbArq(
        _ arqEvents: [ArqEvent], now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        var events: [SessionEvent] = []
        for event in arqEvents {
            switch event {
            case .message(let group, let bytes):
                counters.arqMessages += 1
                if let consumed = consumeReliable(
                    bytes, now: now, hostMicroseconds: hostMicroseconds
                ) {
                    events += consumed
                } else {
                    events.append(.reliableCtrl(group: group, message: bytes))
                }
            case .oneShotAcknowledged(let group):
                events.append(.reliableOneShotAcknowledged(group))
                if group == finalFrameGroup {
                    // The converged frame landed: this ack IS the
                    // idle-flip signal (W4b's ordering rule).
                    finalFrameGroup = nil
                    convergedFrame = nil
                    events += runMachine(
                        .finalFrameAcknowledged,
                        now: now, hostMicroseconds: hostMicroseconds
                    )
                }
            case .ignored(let reason):
                counters.arqIgnored += 1
                events.append(.arqIgnored(reason))
            }
        }
        return events
    }

    /// The session's own reliable-CTRL consumers. Returns nil when the
    /// type byte belongs to some other consumer (the shell dispatches
    /// those). Never throws: hostile bytes become drop events.
    private func consumeReliable(
        _ message: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent]? {
        switch message.first {
        case CtrlMessageType.sessionTeardown:
            guard let teardown = try? SessionTeardown.decode(message) else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            return runMachine(
                .teardownMessage(teardown.reason),
                now: now, hostMicroseconds: hostMicroseconds
            )
        case CtrlMessageType.capabilityDeclaration:
            return receiveDeclaration(
                message, now: now, hostMicroseconds: hostMicroseconds
            )
        case CtrlMessageType.capabilityUpdateAck:
            guard let ack = try? CapabilityUpdateAck.decode(message),
                  let event = try? negotiator.receive(ack) else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            switch event {
            case .updateAccepted:
                return [.capabilityUpdateAcknowledged(accepted: true)]
            case .updateRejected:
                return [.capabilityUpdateAcknowledged(accepted: false)]
            case .agreed, .answerUpdate:
                counters.dropped += 1 // unreachable from receive(ack)
                return [.dropped(.malformedCtrl)]
            }
        case CtrlMessageType.modeTransition, CtrlMessageType.capabilityUpdate:
            // Receiver-role messages arriving at the mediaSender /
            // sole proposer: hostile or confused. Dropped loud.
            counters.dropped += 1
            return [.dropped(.unexpectedCtrlType(message.first!))]
        default:
            return nil
        }
    }

    /// The client's 0x0F: the intersection settles the session — or
    /// proves it unworkable, in which case the typed teardown is the
    /// answer (never silence: the client must learn why).
    private func receiveDeclaration(
        _ message: [UInt8], now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        let declaration: CapabilityDeclaration
        do {
            declaration = try CapabilityDeclaration.decode(message)
        } catch {
            counters.dropped += 1
            return [.dropped(.malformedCtrl)]
        }
        do {
            guard case .agreed(let agreed) = try negotiator.receive(declaration)
            else {
                counters.dropped += 1 // unreachable from receive(declaration)
                return [.dropped(.malformedCtrl)]
            }
            return [.capabilitiesAgreed(agreed)]
        } catch let failure as CapabilityNegotiationError
            where failure == .noCommonVideoCodec
                || failure == .noCommonChromaMode {
            var events: [SessionEvent] = [
                .capabilitiesFailed(String(describing: failure))
            ]
            events += runMachine(
                .teardownRequest(.shuttingDown),
                now: now, hostMicroseconds: hostMicroseconds
            )
            return events
        } catch {
            // A duplicate declaration or other protocol violation:
            // dropped loud, never fatal.
            counters.dropped += 1
            return [.dropped(.malformedCtrl)]
        }
    }

    // MARK: The lifecycle machine's runner (HS-11)

    /// Applies one input (nil = timers only), polls, executes the
    /// resulting actions, and surfaces state changes. The machine's own
    /// doctrine: apply never fires timers, so poll always follows.
    private func runMachine(
        _ input: SessionInput?, now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard machine != nil else { return [] }
        let before = machine!.state
        var actions: [SessionAction] = []
        if let input {
            actions += machine!.apply(input, now: arqInstant(now))
        }
        let (polled, deadline) = machine!.poll(now: arqInstant(now))
        actions += polled
        machineDeadlineNS = deadline.map { $0.microseconds &* 1_000 }
        var events: [SessionEvent] = []
        if machine!.state != before {
            events.append(.lifecycleChanged(machine!.state))
        }
        events += execute(actions, now: now, hostMicroseconds: hostMicroseconds)
        return events
    }

    /// Everything the machine can ask for, done.
    private func execute(
        _ actions: [SessionAction], now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        var events: [SessionEvent] = []
        for action in actions {
            switch action {
            case .sendModeMessage(let mode):
                do {
                    try sendReliable(
                        ModeTransition(mode: mode).encode(),
                        now: now, hostMicroseconds: hostMicroseconds
                    )
                    counters.modeTransitionsSent += 1
                    events.append(.modeTransitionSent(mode))
                } catch {
                    events.append(.sendFailed("mode transition: \(error)"))
                }
            case .sendTeardownMessage(let reason):
                do {
                    try sendReliable(
                        SessionTeardown(reason: reason).encode(),
                        now: now, hostMicroseconds: hostMicroseconds
                    )
                    events.append(.teardownSent(reason))
                } catch {
                    events.append(.sendFailed("teardown: \(error)"))
                }
            case .sendFinalFrameReliably:
                events += sendFinalFrame(
                    now: now, hostMicroseconds: hostMicroseconds
                )
            case .armNextDamageAsIdr(let pacing), .forceIdr(let pacing):
                machineIdrPacing = pacing
            case .freezeDatagramSends:
                videoFrozen = true
            case .resumeDatagramSends:
                videoFrozen = false
            case .sessionClosed(let reason):
                events.append(.sessionClosed(reason))
            }
        }
        return events
    }

    /// The converged frame onto its one-shot group. A refused send is
    /// loud, not fatal: the pending flip simply never completes, and
    /// the next damage/convergence cycle starts fresh.
    private func sendFinalFrame(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard let converged = convergedFrame else {
            return [.sendFailed("final frame: no converged frame retained")]
        }
        let message = IdleFrame(
            frame: converged.frame,
            captureTimestampMicroseconds: converged.captureMicros,
            annexB: converged.annexB
        ).encode()
        let group = ArqGroupId(rawValue: nextOneShotGroup)
        do {
            try sendReliableOneShot(
                message, group: group,
                now: now, hostMicroseconds: hostMicroseconds
            )
            nextOneShotGroup &+= 1
            if nextOneShotGroup == 0 { nextOneShotGroup = 1 }
            finalFrameGroup = group
            return [.finalFrameSent(group)]
        } catch {
            return [.sendFailed("final frame one-shot: \(error)")]
        }
    }

    /// The W7 declaration: the session's first ARQ-carried message.
    private func declareCapabilities(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard !capabilitiesDeclared else { return [] }
        capabilitiesDeclared = true
        do {
            try sendReliable(
                try negotiator.start().encode(),
                now: now, hostMicroseconds: hostMicroseconds
            )
            return []
        } catch {
            return [.sendFailed("capability declaration: \(error)")]
        }
    }

    /// HS-16's estimator will own window verdicts; until it exists, a
    /// feedback arrival ≥25 ms after the previous one while in RECOVERY
    /// counts as one clean window — enough to graduate a genuinely
    /// flowing path, and honest about what is measurable today (loss
    /// judgment needs the estimator; absence of feedback re-freezes via
    /// the silence detector regardless).
    private func recoveryWindowTick(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard machine?.state == .recovery else {
            recoveryWindowNS = nil
            return []
        }
        guard let start = recoveryWindowNS else {
            recoveryWindowNS = now
            return []
        }
        guard now &- start >= 25_000_000 else { return [] }
        recoveryWindowNS = now
        return runMachine(
            .feedbackWindow(clean: true),
            now: now, hostMicroseconds: hostMicroseconds
        )
    }

    /// Polls the endpoint and puts its output on the wire: repack to
    /// the session's 1101 B plaintext budget (poll packs to the bare
    /// 1112 B table — exact only without TLV + tag; frames are
    /// self-delimiting, so re-cutting datagram boundaries is
    /// protocol-neutral), then each datagram sealed through the
    /// control class like every other CTRL send. Re-arms the PTO wake.
    private func serviceArq(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard phase == .established else { return [] }
        let (payloads, deadline) = arq.poll(now: arqInstant(now))
        nextArqWakeNS = deadline.map { $0.microseconds &* 1_000 }
        guard !payloads.isEmpty else { return [] }

        var events: [SessionEvent] = []
        do {
            for payload in try repackArq(payloads) {
                try sendCtrl(
                    body: payload, sealed: true,
                    now: now, hostMicroseconds: hostMicroseconds
                )
                counters.arqDatagramsSent += 1
            }
        } catch {
            // Segments the poll marked sent stay armed on their PTO
            // timers — a refused send here heals like a lost datagram.
            events.append(.sendFailed("arq: \(error)"))
        }
        return events
    }

    /// Re-cuts the endpoint's datagram payloads at the session's real
    /// budget. Every frame fits alone by construction: segment bodies
    /// were clamped at init (≤ budget − 8) and an ACK frame's ceiling
    /// (3 + 16·38 B) is far below it.
    private func repackArq(_ payloads: [[UInt8]]) throws -> [[UInt8]] {
        var out: [[UInt8]] = []
        var current: [UInt8] = []
        for payload in payloads {
            if payload.count <= arqPayloadBudget {
                // Already within budget — keep the endpoint's packing
                // (ACK piggybacked ahead of segments) byte-verbatim.
                if !current.isEmpty {
                    out.append(current)
                    current = []
                }
                out.append(payload)
                continue
            }
            for frame in try ArqFrame.decodeAll(payload) {
                let bytes = frame.encode()
                if !current.isEmpty,
                   current.count + bytes.count > arqPayloadBudget {
                    out.append(current)
                    current = []
                }
                current.append(contentsOf: bytes)
            }
        }
        if !current.isEmpty {
            out.append(current)
        }
        return out
    }

    // MARK: Timers and pumping

    /// Clock advance with no datagram — the loop's timer wake. Emits due
    /// beacons, services the ARQ's retransmit timers, runs the
    /// lifecycle machine's timers (the 350 ms blackout detector, the
    /// 30 s liveness clock), and runs the validator's expiries.
    public func advance(now: UInt64, hostMicroseconds: UInt64) -> [SessionEvent] {
        var events = process(
            validator.advance(now: now),
            now: now, hostMicroseconds: hostMicroseconds
        )
        guard phase == .established else { return events }
        // Insecure mode reaches establishment without a handshake; the
        // declaration leaves on the first wake (Noise mode declared at
        // `completeHandshake`, so this is a no-op there).
        if !capabilitiesDeclared {
            events += declareCapabilities(
                now: now, hostMicroseconds: hostMicroseconds
            )
        }
        if let due = nextBeaconAt, now >= due {
            events += emitBeacon(now: now, hostMicroseconds: hostMicroseconds)
            // Re-arm from the due instant so cadence does not drift; a
            // stalled loop emits one catch-up beacon, never a burst.
            var next = due + config.beaconIntervalNS
            if next <= now { next = now + config.beaconIntervalNS }
            nextBeaconAt = next
        }
        if let due = nextArqWakeNS, now >= due {
            events += serviceArq(now: now, hostMicroseconds: hostMicroseconds)
        }
        if let machine, machine.state != .closed,
           machineDeadlineNS.map({ now >= $0 }) ?? true {
            events += runMachine(
                nil, now: now, hostMicroseconds: hostMicroseconds
            )
        }
        return events
    }

    /// Drains due pacer batches to the sink. Returns the datagram count.
    @discardableResult
    public func pump(now: UInt64) -> Int {
        channel.pump(now: now)
    }

    /// The earliest instant anything here has work: the pacer's wake,
    /// the next beacon, the ARQ's retransmit deadline, or a validator
    /// deadline. The loop sleeps until this (Pacer semantics).
    public func nextWake(now: UInt64) -> UInt64? {
        var wake = channel.nextWake(now: now)
        for candidate in [
            nextBeaconAt, nextArqWakeNS, machineDeadlineNS,
            validator.nextDeadline,
        ] {
            guard let candidate else { continue }
            wake = wake.map { min($0, candidate) } ?? candidate
        }
        return wake
    }

    public var isIdle: Bool { channel.isIdle }

    /// The HS-16 seam, passed through to the shared pacer.
    public func setRate(bitsPerSecond: Int, now: UInt64) {
        channel.setRate(bitsPerSecond: bitsPerSecond, now: now)
    }

    public var pacerTelemetry: PacerTelemetry { channel.pacerTelemetry }
    public var videoCounters: VideoChannelCounters { channel.counters }

    // MARK: Handshake (responder)

    private func completeHandshake(
        message1: ArraySlice<UInt8>,
        hostStatic: NoiseKeyPair,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        // Fresh responder state per attempt: a failed message 1 (bad
        // version, wrong static, garbage) burns nothing — the client's
        // retry meets a clean slate.
        var responder: NoiseSession
        do {
            responder = try NoiseSession(role: .responder, staticKeys: hostStatic)
            _ = try responder.readMessage1(message1)
        } catch {
            counters.dropped += 1
            return [.dropped(.handshakeFailed(String(describing: error)))]
        }
        if let allowed = config.allowedClientStaticPublicKeys,
           let remote = responder.remoteStaticPublicKey,
           !allowed.contains(remote) {
            counters.dropped += 1
            return [.dropped(.handshakeFailed("client static not in the paired set"))]
        }
        do {
            let message2 = try responder.writeMessage2()
            try sendCtrl(
                body: [CtrlMessageType.noiseHandshake2] + message2,
                sealed: false,
                now: now, hostMicroseconds: hostMicroseconds
            )
            transport = try responder.makeTransport()
        } catch {
            return [.dropped(.handshakeFailed(String(describing: error)))]
        }
        phase = .established
        var events: [SessionEvent] = [.handshakeCompleted(
            remoteStaticPublicKey: responder.remoteStaticPublicKey ?? []
        )]
        // "1 Hz plus session start" (§4.6): message 2 is already queued
        // ahead of this beacon in the control FIFO, so the client can
        // derive its transport before the first sealed datagram lands.
        events += emitBeacon(now: now, hostMicroseconds: hostMicroseconds)
        nextBeaconAt = now + config.beaconIntervalNS
        // The machine begins at establishment, in ACTIVE (W4b), and the
        // capability declaration is the first ARQ-carried word (W7) —
        // beacons are ARQ-exempt, so it is first on the reliable stream
        // by construction.
        machine = SessionStateMachine(
            role: .mediaSender,
            config: config.lifecycle,
            now: arqInstant(now)
        )
        events += declareCapabilities(
            now: now, hostMicroseconds: hostMicroseconds
        )
        events += runMachine(nil, now: now, hostMicroseconds: hostMicroseconds)
        return events
    }

    // MARK: CTRL dispatch

    private func dispatchCtrl(
        _ payload: [UInt8],
        from tuple: FourTuple,
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        guard let type = payload.first else {
            counters.dropped += 1
            return [.dropped(.malformedCtrl)]
        }
        switch type {
        case CtrlMessageType.arqSegment, CtrlMessageType.arqAck:
            // The one-byte peek: a payload starting with either ARQ
            // byte is wholly ARQ — a sequence of self-delimiting
            // frames. Ingest, then poll immediately: the ACK the
            // ingest owes (and any fast retransmit it triggered)
            // leaves in this same service pass.
            var events = absorbArq(
                arq.ingest(payload: payload[...], now: arqInstant(now)),
                now: now, hostMicroseconds: hostMicroseconds
            )
            events += serviceArq(now: now, hostMicroseconds: hostMicroseconds)
            return events
        case CtrlMessageType.beaconEcho:
            guard let echo = try? BeaconEcho.decode(payload) else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            return accept(echo: echo, hostMicroseconds: hostMicroseconds)
        case CtrlMessageType.pathResponse:
            guard let response = try? PathResponse.decode(payload) else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            return process(
                validator.pathResponseReceived(
                    from: tuple, response: response, now: now
                ),
                now: now, hostMicroseconds: hostMicroseconds
            )
        case CtrlMessageType.idrRequest:
            guard let request = try? IdrRequest.decode(payload) else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            clientKeyframePending = true
            counters.idrRequests += 1
            return [.idrRequested(request)]
        default:
            counters.dropped += 1
            return [.dropped(.unexpectedCtrlType(type))]
        }
    }

    private func accept(
        echo: BeaconEcho, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        let hostReceive = HostTimestamp(microseconds: hostMicroseconds)
        let sample = echo.clockSample(hostReceive: hostReceive)
        clock.samples += 1
        clock.lastOffsetMicroseconds = sample.offsetMicroseconds
        clock.lastRttMicroseconds = sample.rttMicroseconds
        if clock.minRttMicroseconds.map({ sample.rttMicroseconds < $0 }) ?? true {
            clock.minRttMicroseconds = sample.rttMicroseconds
            clock.minRttOffsetMicroseconds = sample.offsetMicroseconds
        }
        // W4a's mirror: the next beacon reports this echo's t3 verbatim
        // and our locally measured t4.
        lastEcho = ClockBeacon.LastEcho(
            beaconSeq: echo.beaconSeq,
            clientSend: echo.clientSend,
            hostReceive: hostReceive
        )
        counters.beaconEchoes += 1
        return [.beaconEchoAccepted(
            beaconSeq: echo.beaconSeq,
            offsetMicroseconds: sample.offsetMicroseconds,
            rttMicroseconds: sample.rttMicroseconds
        )]
    }

    // MARK: Outbound plumbing

    private func emitBeacon(
        now: UInt64, hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        let beacon = ClockBeacon(
            beaconSeq: beaconSeq,
            hostSend: HostTimestamp(microseconds: hostMicroseconds),
            lastEcho: lastEcho
        )
        do {
            try sendCtrl(
                body: beacon.encode(), sealed: true,
                now: now, hostMicroseconds: hostMicroseconds
            )
        } catch {
            return [.sendFailed("beacon \(beaconSeq): \(error)")]
        }
        counters.beaconsSent += 1
        defer { beaconSeq &+= 1 }
        return [.beaconSent(beaconSeq: beaconSeq)]
    }

    /// Executes the validator's decisions (a challenge is a CTRL send on
    /// the probed tuple) and surfaces every event to the caller.
    private func process(
        _ pathEvents: [PathValidatorEvent],
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> [SessionEvent] {
        var events: [SessionEvent] = []
        for event in pathEvents {
            if case .sendChallenge(let tuple, let challenge) = event {
                do {
                    try sendCtrl(
                        body: challenge.encode(), sealed: true,
                        destination: tuple,
                        now: now, hostMicroseconds: hostMicroseconds
                    )
                } catch {
                    events.append(.sendFailed("path challenge: \(error)"))
                }
            }
            // .freshKeyframeNeeded needs no execution here: the encoder
            // loop polls takeFreshKeyframeRequest(), which reads the
            // validator's latch directly.
            events.append(.path(event))
        }
        return events
    }

    /// One CTRL body onto the wire: conn-id-tagged envelope, header
    /// bytes as AAD, sealed under the transport (`sealed: false` only
    /// for the bare handshake message 2), then the control class of the
    /// shared pacer.
    private func sendCtrl(
        body: [UInt8],
        sealed: Bool,
        destination: FourTuple? = nil,
        now: UInt64,
        hostMicroseconds: UInt64
    ) throws {
        let envelope = Envelope(
            channel: .ctrl,
            seq: ctrlSeq,
            frame: FrameNumber(rawValue: 0),
            timestamp: hostMicroseconds,
            fec: 0,
            extensions: [connectionId.wireExtension]
        )
        let payload: [UInt8]
        if sealed {
            let header = try envelope.encode(payload: [])
            payload = try sealPayload(body[...], aad: header[...], envelope: envelope)
        } else {
            payload = body
        }
        let bytes = try envelope.encode(payload: payload)
        ctrlSeq = ctrlSeq.next
        channel.enqueueControl(
            bytes, seq: envelope.seq, destination: destination, now: now
        )
    }

    // MARK: The crypto seam

    private func sealPayload(
        _ plaintext: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        switch config.crypto {
        case .insecure:
            return Array(plaintext)
        case .noise:
            guard transport != nil else { throw SessionError.notEstablished }
            return try transport!.seal(
                plaintext: plaintext, aad: aad, envelope: envelope
            )
        }
    }

    private func unsealPayload(
        _ wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        switch config.crypto {
        case .insecure:
            return Array(wirePayload)
        case .noise:
            guard transport != nil else { throw SessionError.notEstablished }
            return try transport!.unseal(
                wirePayload: wirePayload, aad: aad, envelope: envelope
            )
        }
    }
}
