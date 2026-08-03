import XCTest
import CoreMedia
import Foundation
import LyteCore
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE GATE (build plan CL-8 + CL-7's deferred session slice): the
// client's REAL production session core — NoiseTransportCrypto
// initiator (with the W8 0x13→0x14 retry answer in the dial),
// ReceiveDemux unseal, TransportSender seal, ReliableCtrlEndpoint,
// CapabilityNegotiator(client), SessionStateMachine(mediaReceiver),
// the 0x15 idle-frame render seam through the shared factory, and the
// typed teardown both directions — driven end to end in virtual time
// against a LyteWire host build-up running the REAL mediaSender
// machine, through SimNet impairment schedules (the established
// ReliableCtrlGateTests/PairingGateTests pattern; this gate keeps an
// isolated stand-in assembled from the same Wire parts that pin the
// HS-11 Session's discipline).
//
// The scripted lifecycle mirrors the W4b simulation's G6 shape, now
// over the production client object: capabilities as the first
// reliable word both ways → datagram video (real corpus frames) → the
// ratchet convergence handoff (idle frame one-shot, ack-gated flip,
// mode=idle) → WAKE (damage → mode=active) → a second convergence
// whose idle frame DEDUPES (the datagram path already delivered that
// frame) → a full blackout deriving the FROZEN pill → recovery
// clearing it → the host's typed teardown closing the client with its
// reason. Client-initiated teardown and the unworkable-intersection
// refusal run as separate legs.

final class LyteUdpSessionGateTests: XCTestCase {

    // MARK: - Corpus

    private static var corpusDirectory: String {
        ClientTestPaths.videoCorpus
    }

    /// The decodable corpus prefix, in order (IDR first).
    private func loadCorpus(_ count: Int) throws -> [[UInt8]] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: Self.corpusDirectory)
            .filter { $0.hasPrefix("frame-0") && $0.hasSuffix(".annexb") }
            .sorted()
            .prefix(count)
        return try names.map {
            [UInt8](try Data(contentsOf: URL(
                fileURLWithPath: Self.corpusDirectory + "/" + $0)))
        }
    }

    // MARK: - The host stand-in

    /// The HS-11 host discipline from LyteWire parts: Noise responder
    /// (optionally behind W8 retry challenges), mediaSender machine,
    /// host-clock ARQ, capability negotiator (declaration = first
    /// reliable word), the idle-frame one-shot whose ack flips to
    /// IDLE, conn-id-tagged sealed CTRL, and corpus video on chan 2.
    private final class HostStandIn: NoiseHandshakeIO {
        let staticKeys = NoiseKeyPair.generate()
        let connectionId: ConnectionId
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var arq: ArqEndpoint<HostClock>
        var machine: SessionStateMachine<HostClock>?
        var negotiator: CapabilityNegotiator
        var capabilitiesDeclared = false
        var nextOneShot: UInt16 = 1
        var packetizer = VideoPacketizer()
        var beaconSeq: UInt32 = 0
        var lastBeaconAt: UInt64 = 0
        private var handshakeOutbox: [[UInt8]] = []

        // W8 retry posture: refuse this many message 1s with a
        // stateless challenge before establishing.
        var retryChallengesToIssue: Int
        let retrySecret: [UInt8] = (0..<32).map { UInt8($0) }
        // The host's own serialization of the source tuple — opaque to
        // the client, bound into the cookie's MAC.
        let clientTuple: [UInt8] = Array("192.0.2.7:41009".utf8)
        var challengedMessage1: [UInt8] = []
        var retryResubmissionsVerified = 0

        // Evidence the gate asserts against.
        var receivedReliableTypes: [UInt8] = []
        var agreed: Capabilities?
        var negotiationFailed = false
        var sentModeMessages: [SessionWireMode] = []
        var forceIdrPacings: [IdrPacing] = []
        var armedIdrPacings: [IdrPacing] = []
        var freezeCount = 0
        var resumeCount = 0
        var idrRequestsSeen = 0
        var echoesSeen = 0
        var feedbackSeen = 0
        var replayDrops = 0
        var peerTeardownReason: SessionTeardownReason?
        /// The bytes the next .sendFinalFrameReliably action ships —
        /// the test scripts the converged frame before converging.
        var pendingIdleFrame: [UInt8] = []

        init(
            localCapabilities: Capabilities = .wireDefault,
            retryChallenges: Int = 0
        ) {
            var rng = SplitMix64(seed: 0xC1_08)
            connectionId = ConnectionId.random(using: &rng)
            var config = ArqConfig()
            config.maxSegmentBodyByteCount = min(
                config.maxSegmentBodyByteCount,
                ReliableCtrlEndpoint.ctrlPlaintextBudget
                    - ArqBounds.segmentHeaderByteCount
            )
            arq = ArqEndpoint(channel: .ctrl, config: config)
            negotiator = CapabilityNegotiator(
                role: .host, local: localCapabilities)
            retryChallengesToIssue = retryChallenges
        }

        // NoiseHandshakeIO — the pre-thread handshake window, answered
        // in-process, with the W8 challenge leg in front when scripted.

        func sendToHost(_ datagram: [UInt8]) throws {
            guard let (envelope, payload) = try? Envelope.decode(datagram[...]),
                  envelope.channel == .ctrl
            else { return }
            switch payload.first {
            case CtrlMessageType.noiseHandshake1
                where retryChallengesToIssue > 0:
                // Flood posture: no Noise work — mint from (tuple,
                // msg1, now, secret) and forget the exchange entirely.
                retryChallengesToIssue -= 1
                challengedMessage1 = Array(payload.dropFirst())
                let cookie = try RetryCookie.mint(
                    clientTuple: clientTuple,
                    message1: challengedMessage1,
                    now: 1_000_000_000,
                    secret: retrySecret
                )
                handshakeOutbox.append(try bareCtrl(
                    payload: try RetryChallenge(cookie: cookie).encode()))
            case CtrlMessageType.noiseHandshake1:
                try establish(message1: Array(payload.dropFirst()))
            case CtrlMessageType.retryHandshake1:
                let resubmission = try RetryHandshake1.decode(payload)
                XCTAssertTrue(
                    RetryCookie.verify(
                        cookie: resubmission.cookie,
                        clientTuple: clientTuple,
                        message1: resubmission.message1,
                        now: 2_000_000_000,
                        secrets: [retrySecret]
                    ),
                    "the echoed cookie must verify for this exact (tuple, msg1)"
                )
                XCTAssertEqual(
                    resubmission.message1, challengedMessage1,
                    "the resubmission must carry message 1 byte-verbatim (0443beb's rule)"
                )
                retryResubmissionsVerified += 1
                try establish(message1: resubmission.message1)
            default:
                XCTFail("unexpected pre-transport type \(payload.first ?? 0)")
            }
        }

        func receiveDatagram(timeoutMilliseconds: Int) throws -> [UInt8]? {
            handshakeOutbox.isEmpty ? nil : handshakeOutbox.removeFirst()
        }

        private func establish(message1: [UInt8]) throws {
            var responder = try NoiseSession(
                role: .responder, staticKeys: staticKeys)
            _ = try responder.readMessage1(message1[...])
            let message2 = try responder.writeMessage2()
            transport = try responder.makeTransport()
            // The machine begins at establishment, ACTIVE (W4b).
            machine = SessionStateMachine(
                role: .mediaSender,
                now: HostTimestamp(microseconds: 0)
            )
            let carriage = Envelope(
                channel: .ctrl,
                seq: ChannelSeq(rawValue: ctrlSeq),
                frame: FrameNumber(rawValue: 0),
                timestamp: 0,
                fec: 0,
                extensions: [connectionId.wireExtension]
            )
            ctrlSeq &+= 1
            handshakeOutbox.append(try carriage.encode(
                payload: [CtrlMessageType.noiseHandshake2] + message2))
        }

        private func bareCtrl(payload: [UInt8]) throws -> [UInt8] {
            let envelope = Envelope(
                channel: .ctrl,
                seq: ChannelSeq(rawValue: 0),
                frame: FrameNumber(rawValue: 0),
                timestamp: 0,
                fec: 0
            )
            return try envelope.encode(payload: payload)
        }

        // The established send path: conn-id-tagged envelope, header
        // bytes as AAD, sealed under the transport.

        func sealedCtrl(body: [UInt8], hostMicros: UInt64) throws -> [UInt8] {
            let envelope = Envelope(
                channel: .ctrl,
                seq: ChannelSeq(rawValue: ctrlSeq),
                frame: FrameNumber(rawValue: 0),
                timestamp: hostMicros,
                fec: 0,
                extensions: [connectionId.wireExtension]
            )
            ctrlSeq &+= 1
            let header = try envelope.encode(payload: [])
            let payload = try transport!.seal(
                plaintext: body[...], aad: header[...], envelope: envelope
            )
            let datagram = try envelope.encode(payload: payload)
            XCTAssertLessThanOrEqual(
                datagram.count, WireBudget.maxDatagramByteCount)
            return datagram
        }

        /// Real corpus video on the datagram path (chan 2): packetized
        /// by the real VideoPacketizer, sealed shard by shard. Bare
        /// envelopes (no conn-id TLV) so the frozen 1112 B shard
        /// geometry stays exact — the CTRL side teaches the conn-id.
        func videoDatagrams(
            annexB: [UInt8], frameNumber: UInt32, hostMicros: UInt64
        ) throws -> [[UInt8]] {
            let shards = try packetizer.packetize(
                frame: annexB,
                frameNumber: FrameNumber(rawValue: frameNumber),
                captureTimestamp: HostTimestamp(microseconds: hostMicros),
                isIDR: AnnexBCheck.containsIrap(annexB),
                regime: .clean
            )
            return try shards.map { shard in
                let header = try shard.envelope.encode(payload: [])
                let sealed = try transport!.seal(
                    plaintext: shard.payload[...],
                    aad: header[...],
                    envelope: shard.envelope
                )
                let datagram = try shard.envelope.encode(payload: sealed)
                XCTAssertLessThanOrEqual(
                    datagram.count, WireBudget.maxDatagramByteCount)
                return datagram
            }
        }

        /// One client datagram: unseal → route. Feedback (chan 3) is
        /// the 350 ms detector's food; CTRL splits at the one-byte
        /// peek (HS-11's evidence discipline).
        func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            let (envelope, payload) = try Envelope.decode(bytes)
            let aad = bytes[bytes.startIndex..<payload.startIndex]
            let plaintext: [UInt8]
            do {
                plaintext = try transport!.unseal(
                    wirePayload: payload, aad: aad, envelope: envelope
                )
            } catch NoiseError.replayedSequence, NoiseError.staleSequence {
                replayDrops += 1
                return
            }
            if envelope.channel == .feedback {
                feedbackSeen += 1
                runMachine(.mediaPathEvidence, nowMicros: nowMicros)
                return
            }
            guard envelope.channel == .ctrl else {
                return XCTFail("unexpected channel \(envelope.channel.rawValue)")
            }
            switch plaintext.first {
            case CtrlMessageType.arqSegment, CtrlMessageType.arqAck:
                runMachine(.ctrlEvidence, nowMicros: nowMicros)
                for event in arq.ingest(
                    payload: plaintext,
                    now: HostTimestamp(microseconds: nowMicros)
                ) {
                    switch event {
                    case .message(_, let message):
                        receivedReliableTypes.append(message.first ?? 0)
                        dispatchReliable(message, nowMicros: nowMicros)
                    case .oneShotAcknowledged:
                        runMachine(.finalFrameAcknowledged,
                                   nowMicros: nowMicros)
                    case .ignored:
                        break
                    }
                }
            case CtrlMessageType.beaconEcho:
                echoesSeen += 1
                runMachine(.ctrlEvidence, nowMicros: nowMicros)
            case CtrlMessageType.idrRequest:
                idrRequestsSeen += 1
                runMachine(.ctrlEvidence, nowMicros: nowMicros)
            default:
                XCTFail("unexpected client CTRL type \(plaintext.first ?? 0)")
            }
        }

        private func dispatchReliable(
            _ message: [UInt8], nowMicros: UInt64
        ) {
            switch message.first {
            case CtrlMessageType.capabilityDeclaration:
                guard let declaration =
                    try? CapabilityDeclaration.decode(message)
                else { return XCTFail("malformed client declaration") }
                do {
                    if case .agreed(let intersection) =
                        try negotiator.receive(declaration) {
                        agreed = intersection
                    }
                } catch {
                    // The unworkable-intersection leg: the real host
                    // answers with its own typed 0x0A; the client's
                    // symmetric refusal already closes the exchange,
                    // which is what that test asserts.
                    negotiationFailed = true
                }
            case CtrlMessageType.sessionTeardown:
                guard let teardown = try? SessionTeardown.decode(message)
                else { return XCTFail("malformed client teardown") }
                peerTeardownReason = teardown.reason
                runMachine(.teardownMessage(teardown.reason),
                           nowMicros: nowMicros)
            default:
                XCTFail("unexpected reliable type \(message.first ?? 0)")
            }
        }

        /// One host beat: the first-word declaration, machine timers,
        /// the 1 Hz beacon, and the ARQ's due output (repacked to the
        /// 1101 B ceiling, sealed). Returns datagrams for the net.
        func advance(nowMicros: UInt64) throws -> [[UInt8]] {
            guard transport != nil else { return [] }
            var out: [[UInt8]] = []
            if !capabilitiesDeclared {
                // HS-11's rule: the declaration is the FIRST
                // sendReliable post-establishment.
                capabilitiesDeclared = true
                try arq.send(
                    message: try negotiator.start().encode(),
                    now: HostTimestamp(microseconds: nowMicros)
                )
            }
            runMachine(nil, nowMicros: nowMicros)
            if nowMicros == 0 || nowMicros - lastBeaconAt >= 1_000_000 {
                lastBeaconAt = nowMicros
                let beacon = ClockBeacon(
                    beaconSeq: beaconSeq,
                    hostSend: HostTimestamp(microseconds: nowMicros),
                    lastEcho: nil
                )
                beaconSeq &+= 1
                out.append(try sealedCtrl(
                    body: beacon.encode(), hostMicros: nowMicros))
            }
            let (payloads, _) = arq.poll(
                now: HostTimestamp(microseconds: nowMicros))
            for payload in payloads {
                for repacked in try ReliableRepack.cut(payload) {
                    out.append(try sealedCtrl(
                        body: repacked, hostMicros: nowMicros))
                }
            }
            return out
        }

        /// Apply + poll, actions executed — the W4b shell discipline.
        func runMachine(_ input: SessionInput?, nowMicros: UInt64) {
            guard machine != nil else { return }
            let instant = HostTimestamp(microseconds: nowMicros)
            var actions: [SessionAction] = []
            if let input {
                actions += machine!.apply(input, now: instant)
            }
            let (polled, _) = machine!.poll(now: instant)
            actions += polled
            for action in actions {
                switch action {
                case .sendModeMessage(let mode):
                    sentModeMessages.append(mode)
                    try? arq.send(
                        message: ModeTransition(mode: mode).encode(),
                        now: instant)
                case .sendTeardownMessage(let reason):
                    try? arq.send(
                        message: SessionTeardown(reason: reason).encode(),
                        now: instant)
                case .sendFinalFrameReliably:
                    XCTAssertFalse(pendingIdleFrame.isEmpty,
                                   "converged with no scripted idle frame")
                    try? arq.sendOneShot(
                        message: pendingIdleFrame,
                        group: ArqGroupId(rawValue: nextOneShot),
                        now: instant)
                    nextOneShot += 1
                case .armNextDamageAsIdr(let pacing):
                    armedIdrPacings.append(pacing)
                case .forceIdr(let pacing):
                    forceIdrPacings.append(pacing)
                case .freezeDatagramSends:
                    freezeCount += 1
                case .resumeDatagramSends:
                    resumeCount += 1
                case .sessionClosed:
                    break
                }
            }
        }
    }

    /// The HS-8 repack, shared shape (poll packs to the bare 1112 B
    /// table; the session's real plaintext ceiling is 1101 B with the
    /// conn-id TLV + AEAD tag on the datagram).
    private enum ReliableRepack {
        static func cut(_ payload: [UInt8]) throws -> [[UInt8]] {
            let budget = ReliableCtrlEndpoint.ctrlPlaintextBudget
            if payload.count <= budget { return [payload] }
            var out: [[UInt8]] = []
            var current: [UInt8] = []
            for frame in try ArqFrame.decodeAll(payload) {
                let bytes = frame.encode()
                if !current.isEmpty, current.count + bytes.count > budget {
                    out.append(current)
                    current = []
                }
                current.append(contentsOf: bytes)
            }
            if !current.isEmpty { out.append(current) }
            return out
        }
    }

    // MARK: - The client harness

    /// The REAL production core minus the socket: crypto + demux +
    /// sender feed LyteUdpSessionCore exactly as UdpReceiveEndpoint
    /// does, on a virtual clock.
    private final class Harness: @unchecked Sendable {
        let host: HostStandIn
        let clientStatic = NoiseKeyPair.generate()
        let crypto: NoiseTransportCrypto
        let demux: ReceiveDemux
        var core: LyteUdpSessionCore!
        let outbound = LockedDatagramPile()
        let clock = LockedMicros()

        var events: [LyteUdpSessionEvent] = []
        var samples: [(CMSampleBuffer, DecodeUnit)] = []

        init(
            host: HostStandIn,
            coreConfig: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig()
        ) throws {
            self.host = host
            let crypto = try NoiseTransportCrypto(
                hostAddress: "10.0.0.249", hostPort: 41_009,
                hostStaticPublicKey: host.staticKeys.publicKey,
                staticKeys: clientStatic,
                attempts: 3, attemptTimeoutMilliseconds: 200)
            try crypto.performHandshake(io: host)
            self.crypto = crypto
            self.demux = ReceiveDemux(crypto: crypto)
            let outbound = self.outbound
            let clock = self.clock
            let sender = TransportSender(crypto: crypto, transmit: {
                outbound.append($0)
                return true
            })
            self.core = LyteUdpSessionCore(
                demux: demux,
                sender: sender,
                config: coreConfig,
                now: { ClientTimestamp(microseconds: clock.value) },
                videoSink: HeadlessVideoSink(receive: {
                    [weak self] sample, unit in
                    self?.samples.append((sample, unit))
                    if unit.isIDR {
                        self?.core.noteVideoIrapEnqueued()
                    }
                }),
                onEvent: { [weak self] event in
                    self?.events.append(event)
                })
        }

        /// The endpoint's routing, verbatim: demux → core.
        func absorb(_ bytes: [UInt8], tMicros: UInt64) {
            let outcome = demux.ingest(
                datagram: bytes[...], arrivalMicroseconds: tMicros)
            switch outcome {
            case .accepted:
                core.handleDatagram(outcome, arrivalMicroseconds: tMicros)
            case .unsealFailed:
                break   // byte-identical duplicate: replay window
            default:
                XCTFail("host datagram refused: \(outcome)")
            }
        }

        var observedModes: [SessionWireMode] {
            events.compactMap {
                if case .modeChanged(let mode) = $0 { return mode }
                return nil
            }
        }

        var observedStates: [SessionState] {
            events.compactMap {
                if case .stateChanged(let state) = $0 { return state }
                return nil
            }
        }

        var idleFrameOutcomes: [(UInt32, ReliableFrameOutcome)] {
            events.compactMap {
                if case .idleFrameReceived(let frame, let outcome) = $0 {
                    return (frame, outcome)
                }
                return nil
            }
        }

        var closedReason: SessionCloseReason? {
            for event in events {
                if case .closed(let reason) = event { return reason }
            }
            return nil
        }
    }

    final class LockedDatagramPile: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[UInt8]] = []
        func append(_ d: [UInt8]) { lock.lock(); stored.append(d); lock.unlock() }
        var all: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return stored }
        var count: Int { lock.lock(); defer { lock.unlock() }; return stored.count }
    }

    final class LockedMicros: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64 = 1_000
        var value: UInt64 {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    // MARK: - W8: the dial answers a retry challenge

    func testDialAnswersRetryChallengeWithVerbatimMessage1() throws {
        let host = HostStandIn(retryChallenges: 1)
        let harness = try Harness(host: host)

        XCTAssertEqual(host.retryResubmissionsVerified, 1,
                       "the 0x14 resubmission verified against the minted cookie")
        XCTAssertEqual(harness.crypto.retryChallengesAnsweredSnapshot, 1)
        XCTAssertNotNil(host.transport, "the handshake completed after the retry loop")
        XCTAssertNotNil(harness.crypto.handshakeMillisecondsSnapshot)
    }

    // MARK: - The 0x15 codec mirror (bytes pinned before promotion)

    func testIdleFrameCodecMatchesHostPinnedLayout() throws {
        let annexB: [UInt8] = [0, 0, 0, 1, 0x26, 0x01, 0xAB]
        let message = IdleFrame(
            frame: FrameNumber(rawValue: 0x0403_0201),
            captureTimestampMicroseconds: 0x0807_0605_0403_0201,
            annexB: annexB
        ).encode()
        // Hand-built layout: type ‖ frame u32 LE ‖ capture u64 LE ‖ Annex-B.
        XCTAssertEqual(
            message,
            [0x15,
             0x01, 0x02, 0x03, 0x04,
             0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
                + annexB
        )
        let decoded = try IdleFrame.decode(message)
        XCTAssertEqual(decoded.frame.rawValue, 0x0403_0201)
        XCTAssertEqual(
            decoded.captureTimestampMicroseconds, 0x0807_0605_0403_0201)
        XCTAssertEqual(decoded.annexB, annexB)

        // Refusals: truncation, an empty body, a foreign type.
        XCTAssertThrowsError(
            try IdleFrame.decode(Array(message.prefix(13))))
        XCTAssertThrowsError(try IdleFrame.decode([UInt8]()))
        var foreign = message
        foreign[0] = 0x09
        XCTAssertThrowsError(try IdleFrame.decode(foreign))
    }

    // MARK: - The full lifecycle gate

    func testGateFullLifecycleIdleCyclesBlackoutPillAndHostTeardown() throws {
        let corpus = try loadCorpus(5)
        let host = HostStandIn()
        let harness = try Harness(host: host)
        var net = SimNet(
            config: SimNetConfig(
                baseDelayMicroseconds: 4_000,
                jitterMicroseconds: 2_000
            ),
            seed: 0xC1_8_1
        )

        // The declaration leaves before anything else (open() is what
        // the production shell calls right after the handshake).
        try harness.core.open(now: ClientTimestamp(microseconds: 1_000))

        // Script (virtual µs):
        //   1.0 s  frames 0+1 ride the datagram path; frame 2 is
        //          "sent" but lost in full (the mechanism's reason)
        //   1.5 s  ratchet converges → IdleFrame(2) one-shot →
        //          ack-gated flip → mode=idle
        //   3.0 s  damage → WAKE → mode=active; frame 3 datagram
        //   3.5 s  converges again → IdleFrame(3) DEDUPES client-side
        //   4.5 s  the W-G4 storm (5% loss, 2% dup, jitter)
        //   5.0 s  blackout (100% loss) → both ends derive FROZEN;
        //          the client pill by 7.5 s (2.5 s beacon-bounded
        //          detector)
        //   8.5 s  recovery at 5% loss → pill clears, host RECOVERY
        //          re-signals mode=active through the loss
        //  10.5 s  clean; host tears down (shutting-down)
        let blackoutStart: UInt64 = 5_000_000
        let blackoutEnd: UInt64 = 8_500_000
        let recoveryEnd: UInt64 = 10_500_000
        let horizon: UInt64 = 12_000_000

        var videoSent = false
        var converged1 = false
        var damaged = false
        var converged2 = false
        var toreDown = false
        var stormApplied = false
        var blackoutApplied = false
        var recoveryApplied = false
        var clearedApplied = false
        var lastFeedbackAt: UInt64 = 0
        var lastWindowAt: UInt64 = 0
        var feedbackSinceWindow = 0
        var frozenSeenAt: UInt64?
        var pillClearedAt: UInt64?
        var forwarded = 0

        var t: UInt64 = 1_000
        while t <= horizon {
            harness.clock.value = t

            // Impairment schedule (>= with latches: t steps 5 ms from
            // 1 ms, so exact-equality beats would silently never fire).
            if t >= 4_500_000, !stormApplied {
                stormApplied = true
                net.setConfig(SimNetConfig(
                    lossRate: 0.05, duplicateRate: 0.02,
                    baseDelayMicroseconds: 4_000,
                    jitterMicroseconds: 2_000))
            }
            if t >= blackoutStart, !blackoutApplied {
                blackoutApplied = true
                net.setConfig(SimNetConfig(
                    lossRate: 1.0,
                    baseDelayMicroseconds: 4_000,
                    jitterMicroseconds: 2_000))
            }
            if t >= blackoutEnd, !recoveryApplied {
                recoveryApplied = true
                net.setConfig(SimNetConfig(
                    lossRate: 0.05,
                    baseDelayMicroseconds: 4_000,
                    jitterMicroseconds: 2_000))
            }
            if t >= recoveryEnd, !clearedApplied {
                clearedApplied = true
                net.setConfig(SimNetConfig(
                    baseDelayMicroseconds: 4_000,
                    jitterMicroseconds: 2_000))
            }

            // Script beats.
            if t >= 1_000_000, !videoSent {
                videoSent = true
                for (frame, annexB) in [(0, corpus[0]), (1, corpus[1])] {
                    for datagram in try host.videoDatagrams(
                        annexB: annexB, frameNumber: UInt32(frame),
                        hostMicros: t
                    ) {
                        net.send(from: 1, bytes: datagram, now: t)
                    }
                }
                // Frame 2 is packetized (the packetizer's seq advances,
                // as a real lost frame would) but never reaches the net.
                _ = try host.videoDatagrams(
                    annexB: corpus[2], frameNumber: 2, hostMicros: t)
            }
            if t >= 1_500_000, !converged1 {
                converged1 = true
                host.pendingIdleFrame = IdleFrame(
                    frame: FrameNumber(rawValue: 2),
                    captureTimestampMicroseconds: t,
                    annexB: corpus[2]
                ).encode()
                host.runMachine(.ratchetConverged, nowMicros: t)
            }
            if t >= 3_000_000, !damaged {
                damaged = true
                host.runMachine(.damage, nowMicros: t)   // WAKE
                for datagram in try host.videoDatagrams(
                    annexB: corpus[3], frameNumber: 3, hostMicros: t
                ) {
                    net.send(from: 1, bytes: datagram, now: t)
                }
            }
            if t >= 3_500_000, !converged2 {
                converged2 = true
                host.pendingIdleFrame = IdleFrame(
                    frame: FrameNumber(rawValue: 3),
                    captureTimestampMicroseconds: t,
                    annexB: corpus[3]
                ).encode()
                host.runMachine(.ratchetConverged, nowMicros: t)
            }
            if t >= recoveryEnd + 500_000, !toreDown {
                toreDown = true
                host.runMachine(.teardownRequest(.shuttingDown), nowMicros: t)
            }

            // Client feedback cadence (30 ms) — the host detector's
            // food; FeedbackSender is the real one.
            if t - lastFeedbackAt >= 30_000, harness.core.state != .closed {
                lastFeedbackAt = t
                harness.core.feedback.tick(
                    now: ClientTimestamp(microseconds: t))
            }
            // Host feedback-window verdicts (40 ms), the estimator
            // seam's stub — the W4b sim's shape.
            if t - lastWindowAt >= 40_000 {
                lastWindowAt = t
                let clean = feedbackSinceWindow > 0
                feedbackSinceWindow = 0
                host.runMachine(.feedbackWindow(clean: clean), nowMicros: t)
            }

            // Deliveries.
            let hostFeedbackBefore = host.feedbackSeen
            for delivery in net.deliveries(upTo: t) {
                if delivery.destination == 0 {
                    harness.absorb(delivery.bytes, tMicros: t)
                } else {
                    try host.absorb(delivery.bytes, nowMicros: t)
                }
            }
            feedbackSinceWindow += host.feedbackSeen - hostFeedbackBefore

            // Timers + output, both ends.
            harness.core.tick(now: ClientTimestamp(microseconds: t))
            while forwarded < harness.outbound.count {
                net.send(from: 0, bytes: harness.outbound.all[forwarded], now: t)
                forwarded += 1
            }
            for datagram in try host.advance(nowMicros: t) {
                net.send(from: 1, bytes: datagram, now: t)
            }

            // Milestones.
            if frozenSeenAt == nil, harness.core.isFrozen {
                frozenSeenAt = t
            }
            if let froze = frozenSeenAt, pillClearedAt == nil,
               t > froze, !harness.core.isFrozen {
                pillClearedAt = t
            }

            t += 5_000
        }

        // ── Capabilities: first word both ways, intersection agreed. ──
        XCTAssertEqual(
            host.receivedReliableTypes.first,
            CtrlMessageType.capabilityDeclaration,
            "the client's FIRST reliable word must be its declaration"
        )
        XCTAssertEqual(host.agreed, Capabilities.wireDefault,
                       "wireDefault ∩ wireDefault = wireDefault")
        XCTAssertEqual(harness.core.agreedCapabilities, .wireDefault)

        // ── Datagram video rendered byte-exact until frame 2's dependency
        // break. Frame 3 is assembled but fenced from the render seam while
        // recovery awaits an IRAP. ──
        let datagramFrames = harness.samples
            .filter { $0.1.frameNumber.rawValue != 2 }
            .map { $0.1 }
        XCTAssertEqual(datagramFrames.map(\.frameNumber.rawValue), [0, 1])
        XCTAssertEqual(datagramFrames[0].annexB, corpus[0])
        XCTAssertEqual(datagramFrames[1].annexB, corpus[1])

        // ── Idle cycle 1: the lost converged frame arrived reliably,
        // rendered through the shared factory, byte-exact; the ack
        // flipped the host and the mode message flipped the client. ──
        let outcomes = harness.idleFrameOutcomes
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes[0].0, 2)
        XCTAssertEqual(outcomes[0].1, .rendered)
        let reliableFrame = try XCTUnwrap(
            harness.samples.first { $0.1.frameNumber.rawValue == 2 })
        XCTAssertEqual(reliableFrame.1.annexB, corpus[2],
                       "the reliable idle frame must render byte-exact")

        // ── Idle cycle 2: the assembler already completed frame 3, so the
        // idle copy DEDUPES; neither copy crosses the recovery fence. Its
        // ack still flips to IDLE. ──
        XCTAssertEqual(outcomes[1].0, 3)
        XCTAssertEqual(outcomes[1].1, .deduplicated)
        XCTAssertEqual(
            harness.samples.filter { $0.1.frameNumber.rawValue == 3 }.count,
            0, "dependent P frames stay fenced until an IRAP is enqueued")

        // ── Modes: idle → active (WAKE) → idle → active (RECOVERY's
        // re-signal through 5% loss). ──
        XCTAssertEqual(harness.observedModes,
                       [.idle, .active, .idle, .active])
        XCTAssertEqual(host.sentModeMessages,
                       [.idle, .active, .idle, .active])
        XCTAssertEqual(host.armedIdrPacings, [.lastGoodRate],
                       "WAKE arms next-damage-as-IDR at the healthy rate")
        XCTAssertEqual(host.forceIdrPacings, [.halfStaleEstimate],
                       "RECOVERY forces exactly one half-stale IDR")

        // ── The pill: derived inside the blackout (within the 2.5 s
        // beacon-bounded detector + slack), cleared by returning
        // evidence, straight back to the wire mode (never RECOVERY). ──
        let froze = try XCTUnwrap(frozenSeenAt, "the blackout must raise the pill")
        XCTAssertGreaterThan(froze, blackoutStart)
        XCTAssertLessThan(froze, blackoutStart + 3_000_000)
        let cleared = try XCTUnwrap(pillClearedAt, "returning evidence must clear it")
        XCTAssertGreaterThan(cleared, blackoutEnd)
        XCTAssertFalse(harness.observedStates.contains(.recovery),
                       "a mediaReceiver never enters RECOVERY")
        XCTAssertTrue(harness.observedStates.contains(.frozen))

        // ── Host teardown: the typed reason closed the client. ──
        XCTAssertEqual(harness.closedReason,
                       .peerTeardown(.shuttingDown))
        XCTAssertEqual(harness.core.state, .closed)
        XCTAssertEqual(host.machine?.state, .closed)
        XCTAssertEqual(host.machine?.closeReason,
                       .localTeardown(.shuttingDown))

        // ── Hygiene: the exempt paths stayed exempt and alive. ──
        XCTAssertGreaterThan(host.echoesSeen, 3, "beacon echoes flowed")
        XCTAssertGreaterThan(host.feedbackSeen, 50, "feedback flowed")
        XCTAssertEqual(harness.core.snapshotCounters().malformedReliableMessages, 0)
        XCTAssertEqual(harness.core.snapshotCounters().unknownReliableTypes, 0)
    }

    // MARK: - Client-initiated teardown

    func testClientTeardownReachesHostAndQuiesces() throws {
        let host = HostStandIn()
        let harness = try Harness(host: host)
        var net = SimNet(
            config: SimNetConfig(
                lossRate: 0.05,
                baseDelayMicroseconds: 4_000,
                jitterMicroseconds: 2_000
            ),
            seed: 0xC1_8_2
        )

        try harness.core.open(now: ClientTimestamp(microseconds: 1_000))

        var beganTeardown = false
        var forwarded = 0
        var t: UInt64 = 1_000
        while t <= 4_000_000 {
            harness.clock.value = t
            if t >= 1_000_000, !beganTeardown {
                beganTeardown = true
                harness.core.beginTeardown(
                    reason: .shuttingDown,
                    now: ClientTimestamp(microseconds: t))
            }
            for delivery in net.deliveries(upTo: t) {
                if delivery.destination == 0 {
                    harness.absorb(delivery.bytes, tMicros: t)
                } else {
                    try host.absorb(delivery.bytes, nowMicros: t)
                }
            }
            harness.core.tick(now: ClientTimestamp(microseconds: t))
            while forwarded < harness.outbound.count {
                net.send(from: 0, bytes: harness.outbound.all[forwarded], now: t)
                forwarded += 1
            }
            for datagram in try host.advance(nowMicros: t) {
                net.send(from: 1, bytes: datagram, now: t)
            }
            t += 5_000
        }

        // The typed goodbye crossed 5% loss (ARQ retransmit), closed
        // both ends with the reason, and the client's sublayer went
        // quiescent — the shell's linger has something real to wait on.
        XCTAssertEqual(harness.closedReason, .localTeardown(.shuttingDown))
        XCTAssertTrue(harness.events.contains {
            if case .teardownSent(.shuttingDown) = $0 { return true }
            return false
        })
        XCTAssertEqual(host.peerTeardownReason, .shuttingDown)
        XCTAssertEqual(host.machine?.state, .closed)
        XCTAssertEqual(host.machine?.closeReason,
                       .peerTeardown(.shuttingDown))
        XCTAssertTrue(harness.core.isReliableQuiescent)
    }

    // MARK: - Unworkable intersection → typed refusal

    func testNoCommonCodecDrawsTypedTeardown() throws {
        // A host from the future that dropped HEVC: codec id 99 only.
        var alienCaps = Capabilities.wireDefault
        alienCaps.videoCodecs = [99]
        let host = HostStandIn(localCapabilities: alienCaps)
        let harness = try Harness(host: host)
        var net = SimNet(
            config: SimNetConfig(baseDelayMicroseconds: 4_000),
            seed: 0xC1_8_3
        )

        try harness.core.open(now: ClientTimestamp(microseconds: 1_000))

        var forwarded = 0
        var t: UInt64 = 1_000
        while t <= 2_000_000 {
            harness.clock.value = t
            for delivery in net.deliveries(upTo: t) {
                if delivery.destination == 0 {
                    harness.absorb(delivery.bytes, tMicros: t)
                } else {
                    try host.absorb(delivery.bytes, nowMicros: t)
                }
            }
            harness.core.tick(now: ClientTimestamp(microseconds: t))
            while forwarded < harness.outbound.count {
                net.send(from: 0, bytes: harness.outbound.all[forwarded], now: t)
                forwarded += 1
            }
            for datagram in try host.advance(nowMicros: t) {
                net.send(from: 1, bytes: datagram, now: t)
            }
            t += 5_000
        }

        // The client refused loudly: the typed failure surfaced, the
        // typed 0x0A reached the host, nothing agreed.
        XCTAssertTrue(harness.events.contains {
            if case .capabilitiesFailed = $0 { return true }
            return false
        })
        XCTAssertNil(harness.core.agreedCapabilities)
        XCTAssertEqual(harness.core.state, .closed)
        XCTAssertTrue(host.negotiationFailed,
                      "the intersection failed symmetrically host-side")
        XCTAssertEqual(host.peerTeardownReason, .shuttingDown)
    }

    // MARK: - The reliable-frame seam's bootstrap withhold

    func testIdleFrameBeforeAnyIdrIsWithheldNotRendered() throws {
        let corpus = try loadCorpus(2)
        let collected = LockedDatagramPile()   // count via appends
        let pipeline = LyteVideoPipeline(
            nowNanoseconds: { 0 },
            sink: HeadlessVideoSink(receive: {
                _, _ in collected.append([])
            }))
        // A P-frame idle frame with no format description yet: the
        // present-ASAP chain never shows garbage — withheld, exactly
        // like the datagram path's pre-IDR withhold.
        let withheld = pipeline.ingestReliableFrame(
            frame: FrameNumber(rawValue: 7),
            captureTimestampMicroseconds: 1,
            annexB: corpus[1]
        )
        XCTAssertEqual(withheld, .withheld)
        XCTAssertEqual(collected.count, 0)

        // An IDR idle frame bootstraps the description and renders.
        let rendered = pipeline.ingestReliableFrame(
            frame: FrameNumber(rawValue: 8),
            captureTimestampMicroseconds: 2,
            annexB: corpus[0]
        )
        XCTAssertEqual(rendered, .rendered)
        XCTAssertEqual(collected.count, 1)

        // And an older frame number dedupes against it (wrap-aware).
        let deduped = pipeline.ingestReliableFrame(
            frame: FrameNumber(rawValue: 8),
            captureTimestampMicroseconds: 3,
            annexB: corpus[0]
        )
        XCTAssertEqual(deduped, .deduplicated)
        XCTAssertEqual(collected.count, 1)
        let stats = pipeline.snapshotStats()
        XCTAssertEqual(stats.reliableFramesRendered, 1)
        XCTAssertEqual(stats.reliableFramesDeduplicated, 1)
        XCTAssertEqual(stats.samplesWithheld, 1)
    }
}
