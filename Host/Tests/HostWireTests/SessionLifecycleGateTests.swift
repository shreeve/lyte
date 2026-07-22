import XCTest
import HostCore
import HostWire
import LyteWire
import LyteWireTestKit

// THE GATE (build plan HS-11 row + HS-8's deferred capabilities item):
// the W4b SessionStateMachine (mediaSender) drives the session's real
// lifecycle over the HS-8 reliable stream, and the W7 capability
// exchange settles the session's agreed set. Pinned behaviors, each a
// leg below:
//
//   • the host's capability declaration (0x0F) is its FIRST reliable
//     message post-establishment; the intersection with the client's
//     declaration is the agreement — no accept round;
//   • an empty codec intersection is a typed teardown (0x0A), never
//     silence, and the session stops carrying video;
//   • the idle flip waits for the converged frame's one-shot ACK
//     (ModeTransition idle is never emitted before it), and the
//     converged frame crosses byte-exact;
//   • new damage aborts a pending flip — a late ack must not flip a
//     session that never left ACTIVE — and damage in IDLE is the WAKE
//     (mode=active + next-damage-as-IDR);
//   • 350 ms of media-path silence freezes datagram video (the host's
//     own detector); returning evidence is RECOVERY (resume + forced
//     IDR); clean feedback windows graduate back to ACTIVE;
//   • an orderly shutdown delivers SessionTeardown 0x0A on the reliable
//     stream; a liveness timeout closes locally and sends NOTHING.
//
// The far end is the ArqCtrlGateTests discipline: a LyteWire client
// build-up (NoiseSession initiator + ArqEndpoint<ClientClock> +
// CapabilityNegotiator in the client role) — exactly what CL-7/CL-8
// assemble.

final class SessionLifecycleGateTests: XCTestCase {

    private static let rateBPS = 20_000_000

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_008,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    // MARK: The lifecycle-aware loopback client

    private struct LifecycleClient {
        var noise: NoiseSession
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var feedbackSeq: UInt16 = 0
        var arq = ArqEndpoint<ClientClock>(channel: .ctrl)
        let staticKeys: NoiseKeyPair

        var received: [(group: ArqGroupId, bytes: [UInt8])] = []
        var videoDatagrams = 0

        init(hostStaticPublicKey: [UInt8]) throws {
            staticKeys = NoiseKeyPair.generate()
            noise = try NoiseSession(
                role: .initiator,
                staticKeys: staticKeys,
                remoteStaticPublicKey: hostStaticPublicKey
            )
        }

        mutating func message1Datagram(clientMicros: UInt64) throws -> [UInt8] {
            let message1 = try noise.writeMessage1()
            return try datagram(
                channel: .ctrl,
                body: [CtrlMessageType.noiseHandshake1] + message1,
                sealed: false,
                clientMicros: clientMicros
            )
        }

        mutating func datagram(
            channel: ChannelId, body: [UInt8], sealed: Bool,
            clientMicros: UInt64
        ) throws -> [UInt8] {
            let seq: UInt16
            if channel == .feedback {
                seq = feedbackSeq
                feedbackSeq &+= 1
            } else {
                seq = ctrlSeq
                ctrlSeq &+= 1
            }
            let envelope = Envelope(
                channel: channel,
                seq: ChannelSeq(rawValue: seq),
                frame: FrameNumber(rawValue: 0),
                timestamp: clientMicros,
                fec: 0
            )
            guard sealed else { return try envelope.encode(payload: body) }
            let header = try envelope.encode(payload: [])
            let payload = try transport!.seal(
                plaintext: body[...], aad: header[...], envelope: envelope
            )
            return try envelope.encode(payload: payload)
        }

        /// The 25–50 ms chan-3 report the client emits continuously —
        /// media-path evidence for the blackout detector AND, since
        /// HS-16, the estimator's diet: a real (empty) FeedbackReport,
        /// the shape FeedbackSender builds when a window saw nothing
        /// worth sampling. No ledgers, no loss — reads clean.
        mutating func feedbackDatagram(clientMicros: UInt64) throws -> [UInt8] {
            try datagram(
                channel: .feedback,
                body: try FeedbackReport(
                    clientTimestamp: ClientTimestamp(
                        microseconds: clientMicros
                    )
                ).encode(),
                sealed: true,
                clientMicros: clientMicros
            )
        }

        mutating func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            let (envelope, payload) = try Envelope.decode(bytes)
            if envelope.channel == .videoActive {
                videoDatagrams += 1
                return
            }
            XCTAssertEqual(envelope.channel, .ctrl)
            if transport == nil {
                XCTAssertEqual(payload.first, CtrlMessageType.noiseHandshake2)
                _ = try noise.readMessage2(payload.dropFirst())
                transport = try noise.makeTransport()
                return
            }
            let aad = bytes[bytes.startIndex..<payload.startIndex]
            let plaintext: [UInt8]
            do {
                plaintext = try transport!.unseal(
                    wirePayload: payload, aad: aad, envelope: envelope
                )
            } catch NoiseError.replayedSequence, NoiseError.staleSequence {
                return // network duplicate; routine
            }
            switch plaintext.first {
            case CtrlMessageType.arqSegment, CtrlMessageType.arqAck:
                for event in arq.ingest(
                    payload: plaintext,
                    now: ClientTimestamp(microseconds: nowMicros)
                ) {
                    if case .message(let group, let bytes) = event {
                        received.append((group, bytes))
                    }
                }
            case CtrlMessageType.clockBeacon:
                break // 1 Hz weather
            default:
                XCTFail("unexpected host CTRL type \(plaintext.first ?? 0)")
            }
        }

        mutating func pollOut(nowMicros: UInt64) throws -> [[UInt8]] {
            let (payloads, _) = arq.poll(
                now: ClientTimestamp(microseconds: nowMicros)
            )
            return try payloads.map {
                try datagram(
                    channel: .ctrl, body: $0, sealed: true,
                    clientMicros: nowMicros
                )
            }
        }

        /// Reliable messages of one CTRL type, drained.
        mutating func take(type: UInt8) -> [[UInt8]] {
            let hits = received.filter { $0.bytes.first == type }.map(\.bytes)
            received.removeAll { $0.bytes.first == type }
            return hits
        }
    }

    // MARK: Harness

    private struct Loopback {
        let session: Session
        var client: LifecycleClient
        var sent: () -> [VideoChannelDatagram]
        var forwarded: Int
        var hostEvents: [SessionEvent] = []

        /// One direct (lossless, in-order) exchange pass at virtual µs
        /// `t`: host timers → host outbox to the client → client ARQ
        /// output back to the host.
        mutating func exchange(t: UInt64) throws {
            hostEvents += session.advance(now: t * 1_000, hostMicroseconds: t)
            session.pump(now: t * 1_000)
            while forwarded < sent().count {
                try client.absorb(sent()[forwarded].bytes, nowMicros: t)
                forwarded += 1
            }
            for datagram in try client.pollOut(nowMicros: t) {
                hostEvents += session.receive(
                    datagram, from: SessionLifecycleGateTests.tupleA,
                    now: t * 1_000, hostMicroseconds: t
                )
                session.pump(now: t * 1_000)
                while forwarded < sent().count {
                    try client.absorb(sent()[forwarded].bytes, nowMicros: t)
                    forwarded += 1
                }
            }
        }

        /// Runs exchange passes 2 ms apart until both ends quiesce.
        mutating func settle(t: inout UInt64) throws {
            var idle = 0
            while idle < 3 {
                t += 2_000
                let before = (forwarded, hostEvents.count)
                try exchange(t: t)
                idle = (forwarded, hostEvents.count) == before ? idle + 1 : 0
            }
        }

        mutating func feedback(t: UInt64) throws {
            hostEvents += session.receive(
                try client.feedbackDatagram(clientMicros: t),
                from: SessionLifecycleGateTests.tupleA,
                now: t * 1_000, hostMicroseconds: t
            )
        }

        func events<T>(_ extract: (SessionEvent) -> T?) -> [T] {
            hostEvents.compactMap(extract)
        }

        func modeTransitions() -> [SessionWireMode] {
            events {
                if case .modeTransitionSent(let mode) = $0 { return mode }
                return nil
            }
        }
    }

    /// Handshake + capability-declaration baseline: by the time this
    /// returns, the host has declared (its first reliable word — the
    /// assertion lives in SessionGateTests) and the client has
    /// acknowledged it; `sendClientDeclaration` optionally completes
    /// the exchange with the given client set.
    private func establish(
        clientCapabilities: Capabilities? = .wireDefault,
        lifecycle: SessionMachineConfig = SessionMachineConfig(),
        beaconIntervalNS: UInt64 = 1 << 62
    ) throws -> (loop: Loopback, box: DatagramBox) {
        let hostStatic = NoiseKeyPair.generate()
        let box = DatagramBox()
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: beaconIntervalNS,
                lifecycle: lifecycle
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x1108),
            send: { box.datagrams.append($0) }
        )
        var client = try LifecycleClient(
            hostStaticPublicKey: hostStatic.publicKey
        )
        let handshakeEvents = session.receive(
            try client.message1Datagram(clientMicros: 500),
            from: Self.tupleA, now: 0, hostMicroseconds: 0
        )
        XCTAssertEqual(session.phase, .established)
        XCTAssertEqual(session.lifecycleState, .active,
                       "the machine begins at establishment, in ACTIVE")
        session.pump(now: 0)

        var loop = Loopback(
            session: session, client: client,
            sent: { box.datagrams }, forwarded: 0
        )
        loop.hostEvents += handshakeEvents
        var t: UInt64 = 1_000
        if let clientCapabilities {
            var negotiator = CapabilityNegotiator(
                role: .client, local: clientCapabilities
            )
            try loop.client.arq.send(
                message: try negotiator.start().encode(),
                now: ClientTimestamp(microseconds: t)
            )
        }
        try loop.settle(t: &t)
        XCTAssertEqual(
            loop.client.take(type: CtrlMessageType.capabilityDeclaration).count,
            1, "the host's declaration must reach the client exactly once"
        )
        return (loop, box)
    }

    private final class DatagramBox {
        var datagrams: [VideoChannelDatagram] = []
    }

    /// A synthetic frame-shaped Annex-B blob (the SessionGateTests
    /// pattern): start code + TRAIL_R VCL NAL + non-start-code padding.
    private func syntheticFrame(byteCount: Int) -> [UInt8] {
        precondition(byteCount >= 6)
        return [0, 0, 0, 1, 0x02, 0x01]
            + [UInt8](repeating: 0xAA, count: byteCount - 6)
    }

    // MARK: Capabilities — the agreement and the typed refusal

    func testGateCapabilityIntersectionIsTheAgreement() throws {
        // A future-ish client: an extra unknown codec id, 4:4:4 on top
        // of 4:2:0, a clipboard feature channel, a raised ceiling.
        let clientSet = Capabilities(
            wireMinor: 3,
            videoCodecs: [CapabilityCodec.hevc, 9],
            chromaModes: [CapabilityChroma.yuv420, CapabilityChroma.yuv444],
            idleSilence: true,
            featureChannels: [CapabilityFeature.clipboard],
            audioExpress: false,
            resume: true,
            maxDatagramBytes: 1_400
        )
        let (loopValue, _) = try establish(clientCapabilities: clientSet)
        var loop = loopValue

        let agreements = loop.events { event -> Capabilities? in
            if case .capabilitiesAgreed(let agreed) = event { return agreed }
            return nil
        }
        XCTAssertEqual(agreements.count, 1, "exactly one settlement")
        let agreed = agreements[0]
        XCTAssertEqual(agreed.wireMinor, 0, "min of the two minors")
        XCTAssertEqual(agreed.videoCodecs, [CapabilityCodec.hevc],
                       "the unknown codec id vanishes in the intersection")
        XCTAssertEqual(agreed.chromaModes, [CapabilityChroma.yuv420])
        XCTAssertTrue(agreed.idleSilence)
        XCTAssertEqual(agreed.featureChannels, [],
                       "features the host does not declare are off")
        XCTAssertFalse(agreed.resume)
        XCTAssertEqual(agreed.maxDatagramBytes, 1_152, "min of the ceilings")
        XCTAssertEqual(loop.session.agreedCapabilities, agreed)
        XCTAssertEqual(loop.session.lifecycleState, .active,
                       "a workable agreement never disturbs the session")

        print("HS-11/HS-8 gate (capabilities): declaration first-word, "
            + "intersection agreed — codecs \(agreed.videoCodecs), "
            + "ceiling \(agreed.maxDatagramBytes) B")
    }

    func testGateEmptyCodecIntersectionIsATypedTeardown() throws {
        // A client that only speaks a codec this host has never heard
        // of: no session — but a TYPED no, never silence.
        let alienSet = Capabilities(
            wireMinor: 0,
            videoCodecs: [77],
            chromaModes: [CapabilityChroma.yuv420],
            idleSilence: true,
            featureChannels: [],
            audioExpress: false,
            resume: false,
            maxDatagramBytes: 1_152
        )
        let (loopValue, _) = try establish(clientCapabilities: alienSet)
        var loop = loopValue

        XCTAssertTrue(loop.hostEvents.contains(
            .capabilitiesFailed("noCommonVideoCodec")
        ))
        XCTAssertTrue(loop.hostEvents.contains(
            .sessionClosed(.localTeardown(.shuttingDown))
        ))
        XCTAssertEqual(loop.session.lifecycleState, .closed)
        let teardowns = loop.client.take(
            type: CtrlMessageType.sessionTeardown
        )
        XCTAssertEqual(teardowns.count, 1, "the typed 0x0A must be delivered")
        XCTAssertEqual(
            try SessionTeardown.decode(teardowns[0]).reason, .shuttingDown
        )

        // A closed session carries no more video — suppressed, not thrown.
        let suppressed = try loop.session.ingestVideoFrame(
            syntheticFrame(byteCount: 500),
            captureTimestampMicroseconds: 1, isKeyframe: false,
            now: 60_000_000
        )
        XCTAssertEqual(suppressed, 0)
        XCTAssertEqual(loop.session.counters.videoFramesSuppressed, 1)

        print("HS-11/HS-8 gate (refusal): empty codec intersection → "
            + "typed teardown delivered, session closed, video suppressed")
    }

    // MARK: The idle flip — ack-gated, damage-abortable

    func testGateIdleFlipWaitsForTheConvergedFramesAck() throws {
        let (loopValue, _) = try establish()
        var loop = loopValue
        var t: UInt64 = 200_000

        // One real frame first (the converged frame needs a number).
        let frame = syntheticFrame(byteCount: 900)
        _ = try loop.session.ingestVideoFrame(
            frame, captureTimestampMicroseconds: 42_000,
            isKeyframe: false, now: t * 1_000
        )
        try loop.settle(t: &t)

        // Convergence: the one-shot leaves; the mode does NOT flip yet.
        let converged = syntheticFrame(byteCount: 700)
        loop.hostEvents += loop.session.noteRatchetConverged(
            finalFrame: converged,
            captureTimestampMicroseconds: 42_000,
            now: t * 1_000, hostMicroseconds: t
        )
        loop.session.pump(now: t * 1_000)
        XCTAssertEqual(loop.session.wireMode, .active,
                       "no flip before the one-shot is acknowledged")
        XCTAssertTrue(loop.modeTransitions().isEmpty)
        let sentGroups = loop.events { event -> ArqGroupId? in
            if case .finalFrameSent(let group) = event { return group }
            return nil
        }
        XCTAssertEqual(sentGroups.count, 1)

        // Deliver + ack: the client holds the converged frame BEFORE
        // it learns the session went idle (the W4b ordering rule).
        try loop.settle(t: &t)
        let idleFrames = loop.client.received.filter {
            $0.group == sentGroups[0]
        }
        XCTAssertEqual(idleFrames.count, 1, "one-shot delivered exactly once")
        let decoded = try IdleFrame.decode(idleFrames[0].bytes)
        XCTAssertEqual(decoded.annexB, converged,
                       "the converged frame must cross byte-exact")
        XCTAssertEqual(decoded.frame, FrameNumber(rawValue: 0))
        XCTAssertEqual(decoded.captureTimestampMicroseconds, 42_000)

        XCTAssertEqual(loop.session.wireMode, .idle, "the ack IS the flip")
        XCTAssertEqual(loop.session.lifecycleState, .idle)
        XCTAssertEqual(loop.modeTransitions(), [.idle])
        let modeMessages = loop.client.take(
            type: CtrlMessageType.modeTransition
        )
        XCTAssertEqual(modeMessages.count, 1)
        XCTAssertEqual(
            try ModeTransition.decode(modeMessages[0]).mode, .idle,
            "mode=idle rides the ordered stream, after the frame landed"
        )

        // WAKE: damage in IDLE → mode=active + the damage frame owed
        // as an IDR.
        XCTAssertFalse(loop.session.takeFreshKeyframeRequest())
        loop.hostEvents += loop.session.noteDamage(
            now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(loop.session.wireMode, .active)
        XCTAssertTrue(loop.session.takeFreshKeyframeRequest(),
                      "WAKE arms next-damage-as-IDR")
        XCTAssertFalse(loop.session.takeFreshKeyframeRequest())
        try loop.settle(t: &t)
        XCTAssertEqual(loop.modeTransitions(), [.idle, .active])
        let wakeMessages = loop.client.take(
            type: CtrlMessageType.modeTransition
        )
        XCTAssertEqual(
            try wakeMessages.map { try ModeTransition.decode($0).mode },
            [.active]
        )

        print("HS-11 gate (idle flip): converged frame one-shot → ack → "
            + "mode=idle; damage → WAKE (mode=active + armed IDR)")
    }

    func testGateDamageAbortsThePendingFlip() throws {
        let (loopValue, box) = try establish()
        var loop = loopValue
        var t: UInt64 = 200_000

        _ = try loop.session.ingestVideoFrame(
            syntheticFrame(byteCount: 900),
            captureTimestampMicroseconds: 42_000,
            isKeyframe: false, now: t * 1_000
        )
        try loop.settle(t: &t)

        // Converge, but hold the wire: the one-shot is emitted and NOT
        // delivered yet.
        loop.hostEvents += loop.session.noteRatchetConverged(
            finalFrame: syntheticFrame(byteCount: 700),
            captureTimestampMicroseconds: 42_000,
            now: t * 1_000, hostMicroseconds: t
        )
        loop.session.pump(now: t * 1_000)
        let held = box.datagrams[loop.forwarded...]
        XCTAssertFalse(held.isEmpty, "the one-shot must be in flight")

        // New damage during the handoff: the session never left ACTIVE.
        loop.hostEvents += loop.session.noteDamage(
            now: t * 1_000, hostMicroseconds: t
        )
        _ = loop.session.takeFreshKeyframeRequest() // active: nothing armed

        // NOW deliver everything (the held one-shot) and let the ack
        // come back: no flip may happen.
        try loop.settle(t: &t)
        XCTAssertEqual(loop.session.wireMode, .active,
                       "a late ack must not flip an aborted handoff")
        XCTAssertTrue(loop.modeTransitions().isEmpty)

        print("HS-11 gate (abort): damage during the handoff → the late "
            + "one-shot ack flips nothing")
    }

    // MARK: FROZEN / RECOVERY off the host's own silence detector

    func testGateFrozenRecoveryFromTheSilenceDetector() throws {
        let (loopValue, _) = try establish()
        var loop = loopValue

        // A healthy feedback stream, then silence.
        var t: UInt64 = 300_000
        for _ in 0..<4 {
            t += 30_000
            try loop.feedback(t: t)
        }
        XCTAssertEqual(loop.session.lifecycleState, .active)

        // 350 ms past the last feedback: FROZEN — datagram video stops.
        t += 400_000
        loop.hostEvents += loop.session.advance(
            now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(loop.session.lifecycleState, .frozen)
        XCTAssertTrue(loop.hostEvents.contains(.lifecycleChanged(.frozen)))
        let suppressed = try loop.session.ingestVideoFrame(
            syntheticFrame(byteCount: 500),
            captureTimestampMicroseconds: 1, isKeyframe: false,
            now: t * 1_000
        )
        XCTAssertEqual(suppressed, 0, "FROZEN: the wire goes quiet")
        XCTAssertEqual(loop.session.counters.videoFramesSuppressed, 1)

        // Evidence returns: RECOVERY — sends resume, a fresh IDR is
        // owed at the half-stale rate.
        t += 50_000
        try loop.feedback(t: t)
        XCTAssertEqual(loop.session.lifecycleState, .recovery)
        XCTAssertTrue(loop.session.takeFreshKeyframeRequest(),
                      "RECOVERY forces an IDR")
        let flowing = try loop.session.ingestVideoFrame(
            syntheticFrame(byteCount: 500),
            captureTimestampMicroseconds: 2, isKeyframe: false,
            now: t * 1_000
        )
        XCTAssertGreaterThan(flowing, 0, "RECOVERY: sends may flow again")

        // Two clean 25 ms feedback windows graduate back to ACTIVE —
        // the verdicts are the HS-16 estimator's now (clean reports,
        // no loss deltas, no delay inflation). The dirty-window leg
        // (loss holds RECOVERY) lives in RateEstimatorGateTests.
        t += 30_000
        try loop.feedback(t: t)
        t += 30_000
        try loop.feedback(t: t)
        XCTAssertEqual(loop.session.lifecycleState, .active)

        print("HS-11 gate (overlay): 350 ms silence → FROZEN (video "
            + "suppressed) → evidence → RECOVERY (forced IDR) → two clean "
            + "windows → ACTIVE")
    }

    // MARK: Teardown — orderly, peer-initiated, and liveness

    func testGateShutdownDeliversTypedTeardown() throws {
        let (loopValue, _) = try establish()
        var loop = loopValue
        var t: UInt64 = 500_000

        loop.hostEvents += loop.session.beginTeardown(
            reason: .shuttingDown, now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertTrue(loop.hostEvents.contains(.teardownSent(.shuttingDown)))
        XCTAssertTrue(loop.hostEvents.contains(
            .sessionClosed(.localTeardown(.shuttingDown))
        ))
        XCTAssertEqual(loop.session.lifecycleState, .closed)

        // The closed machine no longer times anything, but the ARQ
        // keeps retransmitting the teardown until the client acks —
        // the linger loop's contract.
        try loop.settle(t: &t)
        XCTAssertTrue(loop.session.arqIsQuiescent,
                      "teardown delivered and acknowledged")
        let teardowns = loop.client.take(type: CtrlMessageType.sessionTeardown)
        XCTAssertEqual(
            try teardowns.map { try SessionTeardown.decode($0).reason },
            [.shuttingDown]
        )

        print("HS-11 gate (shutdown): 0x0A delivered exactly once, "
            + "acknowledged, session closed")
    }

    func testGatePeerTeardownClosesTheSession() throws {
        let (loopValue, _) = try establish()
        var loop = loopValue
        var t: UInt64 = 500_000

        // The client's own orderly exit: 0x0A on ITS ordered stream.
        try loop.client.arq.send(
            message: SessionTeardown(reason: .shuttingDown).encode(),
            now: ClientTimestamp(microseconds: t)
        )
        try loop.settle(t: &t)
        XCTAssertEqual(loop.session.lifecycleState, .closed)
        XCTAssertTrue(loop.hostEvents.contains(
            .sessionClosed(.peerTeardown(.shuttingDown))
        ))

        print("HS-11 gate (peer teardown): client 0x0A → host closed "
            + "cleanly — the graceful half of the ECONNREFUSED fix")
    }

    func testGateLivenessTimeoutClosesLocallyAndSendsNothing() throws {
        let (loopValue, box) = try establish()
        var loop = loopValue

        let quietBaseline = box.datagrams.count
        // 30 s of absolutely nothing (beacons pushed past the horizon
        // by the harness): the machine closes locally.
        let t: UInt64 = 31_000_000
        loop.hostEvents += loop.session.advance(
            now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(loop.session.lifecycleState, .closed)
        XCTAssertTrue(loop.hostEvents.contains(
            .sessionClosed(.livenessTimeout)
        ))
        loop.session.pump(now: t * 1_000)
        XCTAssertEqual(
            box.datagrams.count, quietBaseline,
            "a liveness close sends NOTHING — the peer that would read "
                + "it is the one that died"
        )

        print("HS-11 gate (liveness): 30 s of silence → local close, "
            + "zero datagrams emitted")
    }
}
