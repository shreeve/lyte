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
    /// When set, a completing handshake whose authenticated client
    /// static is not in this set is rejected. Nil accepts any static —
    /// honest for the stub: pairing (W6 PIN-PAKE) is what mints this
    /// set, and J-G1 runs statics-pinned-out-of-band in both directions.
    public var allowedClientStaticPublicKeys: [[UInt8]]?

    public init(
        crypto: SessionCryptoMode,
        rateBitsPerSecond: Int,
        regime: FecRegime = .clean,
        pacerQuantumNS: UInt64 = 1_000_000,
        beaconIntervalNS: UInt64 = 1_000_000_000,
        path: PathValidatorConfig = PathValidatorConfig(),
        allowedClientStaticPublicKeys: [[UInt8]]? = nil
    ) {
        self.crypto = crypto
        self.rateBitsPerSecond = rateBitsPerSecond
        self.regime = regime
        self.pacerQuantumNS = pacerQuantumNS
        self.beaconIntervalNS = beaconIntervalNS
        self.path = path
        self.allowedClientStaticPublicKeys = allowedClientStaticPublicKeys
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
    case path(PathValidatorEvent)
    case dropped(SessionDropReason)
    /// An outbound build step refused (seal before establishment, a
    /// budget breach) — loud, because control sends must never fail
    /// silently, but never fatal to the session.
    case sendFailed(String)
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
    /// Chan 3 arrivals: counted, not parsed — the estimator is HS-16.
    public var feedbackDatagrams = 0

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

    private var channel: VideoChannel!
    /// Nil until the handshake completes; always nil in insecure mode.
    private var transport: NoiseTransport?

    private var ctrlSeq = ChannelSeq(rawValue: 0)
    private var nextVideoFrameNumber = FrameNumber(rawValue: 0)

    private var beaconSeq: UInt32 = 0
    private var nextBeaconAt: UInt64?
    private var lastEcho: ClockBeacon.LastEcho?
    private var clientKeyframePending = false

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
            // No handshake to wait for; the session-start beacon leaves
            // on the first `advance`.
            self.phase = .established
            self.nextBeaconAt = now
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
                  payload.first == HostCtrlMessageType.noiseHandshake1
            else {
                counters.dropped += 1
                events.append(.dropped(.notEstablished(envelope.channel.rawValue)))
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
            events += dispatchCtrl(
                plaintext, from: tuple,
                now: now, hostMicroseconds: hostMicroseconds
            )
        case .feedback:
            counters.feedbackDatagrams += 1
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
    /// a fresh IDR is owed — either HS-12's path promotion or a client
    /// 0x10 IDR request. Clears both sources; fires once per demand.
    public func takeFreshKeyframeRequest() -> Bool {
        let fromValidator = validator.takeFreshKeyframeRequest()
        let fromClient = clientKeyframePending
        clientKeyframePending = false
        return fromValidator || fromClient
    }

    // MARK: Timers and pumping

    /// Clock advance with no datagram — the loop's timer wake. Emits due
    /// beacons and the validator's expiries.
    public func advance(now: UInt64, hostMicroseconds: UInt64) -> [SessionEvent] {
        var events = process(
            validator.advance(now: now),
            now: now, hostMicroseconds: hostMicroseconds
        )
        guard phase == .established else { return events }
        if let due = nextBeaconAt, now >= due {
            events += emitBeacon(now: now, hostMicroseconds: hostMicroseconds)
            // Re-arm from the due instant so cadence does not drift; a
            // stalled loop emits one catch-up beacon, never a burst.
            var next = due + config.beaconIntervalNS
            if next <= now { next = now + config.beaconIntervalNS }
            nextBeaconAt = next
        }
        return events
    }

    /// Drains due pacer batches to the sink. Returns the datagram count.
    @discardableResult
    public func pump(now: UInt64) -> Int {
        channel.pump(now: now)
    }

    /// The earliest instant anything here has work: the pacer's wake,
    /// the next beacon, or a validator deadline. The loop sleeps until
    /// this (Pacer semantics).
    public func nextWake(now: UInt64) -> UInt64? {
        var wake = channel.nextWake(now: now)
        for candidate in [nextBeaconAt, validator.nextDeadline] {
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
                body: [HostCtrlMessageType.noiseHandshake2] + message2,
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
        case CtrlMessageType.beaconEcho:
            guard let echo = try? BeaconEcho.decode(payload) else {
                counters.dropped += 1
                return [.dropped(.malformedCtrl)]
            }
            return accept(echo: echo, hostMicroseconds: hostMicroseconds)
        case HostCtrlMessageType.pathResponse:
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
        case HostCtrlMessageType.idrRequest:
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
