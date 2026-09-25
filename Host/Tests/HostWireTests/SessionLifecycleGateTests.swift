import XCTest
import HostCore
import HostSession
import HostWire
import HostWireTestKit
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

    private struct LifecycleClient: PeerBackedClient {
        var peer: SealedCtrlPeer<ClientClock>
        var videoDatagrams = 0

        init(hostStaticPublicKey: [UInt8]) throws {
            peer = try SealedCtrlPeer(initiatorTo: hostStaticPublicKey)
        }

        /// The 25–50 ms chan-3 report the client emits continuously —
        /// media-path evidence for the blackout detector AND the
        /// estimator's diet: a real (empty) FeedbackReport, the shape
        /// FeedbackSender builds when a window saw nothing worth
        /// sampling. No ledgers, no loss — reads clean.
        mutating func feedbackDatagram(clientMicros: UInt64) throws -> [UInt8] {
            try peer.datagram(
                channel: .feedback,
                body: try FeedbackReport(
                    clientTimestamp: ClientTimestamp(
                        microseconds: clientMicros
                    )
                ).encode(),
                timestamp: clientMicros
            )
        }

        mutating func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            if try Envelope.decode(bytes).0.channel == .videoActive {
                videoDatagrams += 1
                return
            }
            XCTAssertEqual(try Envelope.decode(bytes).0.channel, .ctrl)
            if case .plain(_, let plaintext) =
                try peer.absorb(bytes, nowMicros: nowMicros),
               plaintext.first != CtrlMessageType.clockBeacon { // 1 Hz weather
                XCTFail("unexpected host CTRL type \(plaintext.first ?? 0)")
            }
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
        hostCapabilities: Capabilities = .wireDefault,
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
                capabilities: hostCapabilities,
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
                message: try XCTUnwrap(negotiator.start()).encode(),
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
        let loop = loopValue

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
    }

    // MARK: Chroma negotiation → encoder posture (H4 V-4)

    /// A 4:4:4-capable host (the startup Rext self-probe passed, so it
    /// declared [420, 444]) meets a Best-tier client declaring the
    /// [444] singleton (declaration-as-choice, owner decision 1): the
    /// agreed set is the singleton, and the singleton opens the
    /// Best-tier encoder posture.
    func testGateBestChromaSingletonAgreesAndPicksTheBestPosture() throws {
        var hostSet = Capabilities.wireDefault
        hostSet.chromaModes = [CapabilityChroma.yuv420,
                               CapabilityChroma.yuv444]
        var clientSet = Capabilities.wireDefault
        clientSet.chromaModes = [CapabilityChroma.yuv444]
        let (loopValue, _) = try establish(
            clientCapabilities: clientSet, hostCapabilities: hostSet
        )
        let loop = loopValue

        let agreements = loop.events { event -> Capabilities? in
            if case .capabilitiesAgreed(let agreed) = event { return agreed }
            return nil
        }
        XCTAssertEqual(agreements.count, 1)
        XCTAssertEqual(agreements[0].chromaModes, [CapabilityChroma.yuv444],
                       """
                           declaration-as-choice: the client's singleton IS \
                           the agreement
                           """)
        XCTAssertEqual(
            ChromaPosture.from(
                agreedChromaModes: loop.session.agreedCapabilities?
                    .chromaModes),
            .yuv444,
            "the [444] singleton opens the Best-tier encoder"
        )
        XCTAssertEqual(loop.session.lifecycleState, .active)
    }

    /// The same 4:4:4-capable host against a Good-tier client ([420]
    /// singleton): agreed [420], today's encoder path — declaring 444
    /// costs a 420 session nothing.
    func testGateGoodChromaSingletonKeepsThe420Posture() throws {
        var hostSet = Capabilities.wireDefault
        hostSet.chromaModes = [CapabilityChroma.yuv420,
                               CapabilityChroma.yuv444]
        let (loopValue, _) = try establish(
            clientCapabilities: .wireDefault, hostCapabilities: hostSet
        )
        let loop = loopValue

        let agreements = loop.events { event -> Capabilities? in
            if case .capabilitiesAgreed(let agreed) = event { return agreed }
            return nil
        }
        XCTAssertEqual(agreements.count, 1)
        XCTAssertEqual(agreements[0].chromaModes, [CapabilityChroma.yuv420])
        XCTAssertEqual(
            ChromaPosture.from(
                agreedChromaModes: loop.session.agreedCapabilities?
                    .chromaModes),
            .yuv420
        )
    }

    /// A [420]-only host (the self-probe failed — the truthful
    /// declaration) against a Best-declaring client: empty chroma
    /// intersection is the TYPED failure the client's auto-re-dial
    /// banner keys on (the pillar's named degradation), never silence.
    func testGateBestAgainst420OnlyHostIsATypedChromaFailure() throws {
        var clientSet = Capabilities.wireDefault
        clientSet.chromaModes = [CapabilityChroma.yuv444]
        let (loopValue, _) = try establish(clientCapabilities: clientSet)
        let loop = loopValue

        XCTAssertTrue(loop.hostEvents.contains(
            .capabilitiesFailed("noCommonChromaMode")
        ), "the typed no the V-5 fallback re-dial keys on")
        XCTAssertTrue(loop.hostEvents.contains(
            .sessionClosed(.localTeardown(.shuttingDown))
        ))
        XCTAssertEqual(loop.session.lifecycleState, .closed)
    }

    /// The posture mapping's whole input space, pinned: ONLY the [444]
    /// singleton opens Best — a both-declaring nonconforming peer, a
    /// never-declaring grandfathered peer (nil), and the unreachable
    /// empty list all ride 4:2:0.
    func testGateChromaPostureMappingPinned() {
        XCTAssertEqual(
            ChromaPosture.from(agreedChromaModes: [CapabilityChroma.yuv444]),
            .yuv444
        )
        XCTAssertEqual(
            ChromaPosture.from(agreedChromaModes: [CapabilityChroma.yuv420]),
            .yuv420
        )
        XCTAssertEqual(
            ChromaPosture.from(agreedChromaModes: [
                CapabilityChroma.yuv420, CapabilityChroma.yuv444,
            ]),
            .yuv420,
            """
                a multi-mode agreement is not a choice — the conservative \
                path rides
                """
        )
        XCTAssertEqual(ChromaPosture.from(agreedChromaModes: nil), .yuv420,
                       "the grandfathered pre-W7 posture")
        XCTAssertEqual(ChromaPosture.from(agreedChromaModes: []), .yuv420)
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
        let admittedBeforeSuppression =
            loop.session.lastAdmittedVideoFrameNumber
        let suppressed = try loop.session.ingestVideoFrame(
            syntheticFrame(byteCount: 500),
            captureTimestampMicroseconds: 1, isKeyframe: false,
            now: t * 1_000
        )
        XCTAssertEqual(suppressed, 0, "FROZEN: the wire goes quiet")
        XCTAssertEqual(loop.session.counters.videoFramesSuppressed, 1)
        XCTAssertEqual(
            loop.session.lastAdmittedVideoFrameNumber,
            admittedBeforeSuppression)

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
    }

    // MARK: Input silence — held keys outlive a hitch, not a long silence

    /// FROZEN is not input silence: a 400 ms hitch freezes video but asks
    /// for no release. Only `inputSilenceReleaseNS` without any
    /// authenticated arrival does, once, at that instant (the wake names
    /// it); the next arrival re-arms it.
    func testGateInputSilenceElapsesOnlyAfterTheLongSilence() throws {
        let (loopValue, _) = try establish()
        var loop = loopValue
        func silenceEvents() -> Int {
            loop.hostEvents.filter { $0 == .inputSilenceElapsed }.count
        }
        func advance(to micros: UInt64) {
            loop.hostEvents += loop.session.advance(
                now: micros * 1_000, hostMicroseconds: micros)
        }

        var t: UInt64 = 300_000
        for _ in 0..<10 {
            t += 40_000
            try loop.feedback(t: t)
        }
        t += 400_000
        advance(to: t)
        XCTAssertEqual(loop.session.lifecycleState, .frozen)
        try loop.feedback(t: t)
        XCTAssertEqual(silenceEvents(), 0, "a hitch is not input silence")

        let lastArrival = t
        let due = lastArrival * 1_000 + Session.inputSilenceReleaseNS
        XCTAssertLessThanOrEqual(try XCTUnwrap(loop.session.nextWake(
            now: lastArrival * 1_000 + 1)), due)
        while t * 1_000 + 10_000_000 < due {
            t += 10_000
            advance(to: t)
        }
        XCTAssertEqual(silenceEvents(), 0, "not before the silence is long")
        advance(to: due / 1_000)
        XCTAssertEqual(silenceEvents(), 1)
        advance(to: due / 1_000 + 500_000)
        XCTAssertEqual(silenceEvents(), 1, "once per silence")

        t = due / 1_000 + 600_000
        try loop.feedback(t: t)
        advance(to: t + Session.inputSilenceReleaseNS / 1_000)
        XCTAssertEqual(silenceEvents(), 2, "the next silence counts again")
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
        XCTAssertEqual(
            loop.session.phase, .established,
            "CLOSED is terminal lifecycle state, not handshake dormancy"
        )
        XCTAssertTrue(loop.hostEvents.contains(
            .sessionClosed(.livenessTimeout)
        ))
        loop.session.pump(now: t * 1_000)
        XCTAssertEqual(
            box.datagrams.count, quietBaseline,
            """
                a liveness close sends NOTHING — the peer that would read \
                it is the one that died
                """
        )
    }
}
