import XCTest
import LyteWire
import LyteWireTestKit

// The W4b end-to-end rehearsal: one sender machine and one receiver
// machine, each on its own clock domain, joined by real ArqEndpoints
// over SimNet through a scripted impairment schedule — healthy, then a
// full 800 ms blackout, then a 5% lossy recovery, then an orderly
// teardown. The G6-blackout shape (resiliency §7) as a deterministic
// virtual-time simulation:
//
//   - the ratchet convergence handoff flips both ends to IDLE, final
//     frame first, mode message second (order proven by the ARQ);
//   - both ends independently derive FROZEN inside the blackout;
//   - returning evidence drives RECOVERY exactly once: one forced IDR
//     at the half-stale policy, mode=active re-signaled through 5%
//     loss (the ARQ retransmits it), two clean windows → ACTIVE;
//   - the typed teardown arrives with its reason.

final class SessionLifecycleSimulationTests: XCTestCase {

    struct HostEnd {
        var machine = SessionStateMachine<HostClock>(
            role: .mediaSender, now: HostTimestamp(microseconds: 0)
        )
        var arq = ArqEndpoint<HostClock>(channel: .ctrl)
        var nextOneShot: UInt16 = 1
        var forceIdrPacings: [IdrPacing] = []
        var freezeCount = 0
        var resumeCount = 0
        var sentModeMessages: [SessionWireMode] = []
    }

    struct ClientEnd {
        var machine = SessionStateMachine<ClientClock>(
            role: .mediaReceiver, now: ClientTimestamp(microseconds: 0)
        )
        var arq = ArqEndpoint<ClientClock>(channel: .ctrl)
        var observedModes: [SessionWireMode] = []
        var frozenObserved = false
    }

    // Marker datagrams for the unreliable flows; anything starting
    // with 0x07/0x08 is a real ARQ payload (the shell's one-byte peek).
    static let feedbackMarker: [UInt8] = [0xF0]
    static let audioMarker: [UInt8] = [0xF1]

    func testBlackoutRecoveryAndTeardownOverImpairedArq() throws {
        var net = SimNet(
            config: SimNetConfig(
                baseDelayMicroseconds: 5_000,
                jitterMicroseconds: 2_000
            ),
            seed: 0x574_3462
        )
        var host = HostEnd()
        var client = ClientEnd()

        var hostFeedbackSinceWindow = 0
        var lastWindowAt: UInt64 = 0
        var lastFeedbackSentAt: UInt64 = 0
        var lastAudioSentAt: UInt64 = 0
        var convergedFired = false
        var teardownFired = false

        var bothIdleAt: UInt64?
        var hostFrozeDuringBlackoutAt: UInt64?
        var clientFrozeDuringBlackoutAt: UInt64?
        var hostRecoveredAt: UInt64?

        let blackoutStart: UInt64 = 2_000_000
        let blackoutEnd: UInt64 = 2_800_000
        let lossyEnd: UInt64 = 5_000_000
        let simEnd: UInt64 = 5_500_000

        func handleHostActions(
            _ actions: [SessionAction], now: UInt64
        ) throws {
            let instant = HostTimestamp(microseconds: now)
            for action in actions {
                switch action {
                case .sendModeMessage(let mode):
                    host.sentModeMessages.append(mode)
                    try host.arq.send(
                        message: ModeTransition(mode: mode).encode(),
                        now: instant
                    )
                case .sendTeardownMessage(let reason):
                    try host.arq.send(
                        message: SessionTeardown(reason: reason).encode(),
                        now: instant
                    )
                case .sendFinalFrameReliably:
                    try host.arq.sendOneShot(
                        message: [0xFF, 0xEE, 0xDD],
                        group: ArqGroupId(rawValue: host.nextOneShot),
                        now: instant
                    )
                    host.nextOneShot += 1
                case .armNextDamageAsIdr:
                    break
                case .forceIdr(let pacing):
                    host.forceIdrPacings.append(pacing)
                case .freezeDatagramSends:
                    host.freezeCount += 1
                case .resumeDatagramSends:
                    host.resumeCount += 1
                case .sessionClosed:
                    break
                }
            }
        }

        var now: UInt64 = 0
        while now <= simEnd {
            let hostNow = HostTimestamp(microseconds: now)
            let clientNow = ClientTimestamp(microseconds: now)

            // Impairment schedule.
            if now == blackoutStart {
                net.setConfig(SimNetConfig(
                    lossRate: 1.0,
                    baseDelayMicroseconds: 5_000,
                    jitterMicroseconds: 2_000
                ))
            }
            if now == blackoutEnd {
                net.setConfig(SimNetConfig(
                    lossRate: 0.05,
                    baseDelayMicroseconds: 5_000,
                    jitterMicroseconds: 2_000
                ))
            }
            if now == lossyEnd {
                net.setConfig(SimNetConfig(
                    baseDelayMicroseconds: 5_000,
                    jitterMicroseconds: 2_000
                ))
            }

            // Script: converge the ratchet at 1 s; tear down at 5 s.
            if now >= 1_000_000, !convergedFired {
                convergedFired = true
                try handleHostActions(
                    host.machine.apply(.ratchetConverged, now: hostNow),
                    now: now
                )
            }
            if now >= 5_000_000, !teardownFired {
                teardownFired = true
                try handleHostActions(
                    host.machine.apply(
                        .teardownRequest(.shuttingDown), now: hostNow
                    ),
                    now: now
                )
            }

            // Client → host feedback, 30 ms cadence, while open.
            if client.machine.state != .closed,
               now - lastFeedbackSentAt >= 30_000 {
                lastFeedbackSentAt = now
                net.send(from: 1, bytes: Self.feedbackMarker, now: now)
            }
            // Host → client audio, 5 ms cadence — audio continues at
            // CBR even while FROZEN (it is the path probe).
            if host.machine.state != .closed,
               now - lastAudioSentAt >= 5_000 {
                lastAudioSentAt = now
                net.send(from: 0, bytes: Self.audioMarker, now: now)
            }

            // Deliveries.
            for delivery in net.deliveries(upTo: now) {
                if delivery.destination == 0 {
                    // Host side.
                    if delivery.bytes == Self.feedbackMarker {
                        hostFeedbackSinceWindow += 1
                        try handleHostActions(
                            host.machine.apply(
                                .mediaPathEvidence, now: hostNow
                            ),
                            now: now
                        )
                    } else {
                        try handleHostActions(
                            host.machine.apply(.ctrlEvidence, now: hostNow),
                            now: now
                        )
                        for event in host.arq.ingest(
                            payload: delivery.bytes, now: hostNow
                        ) {
                            if case .oneShotAcknowledged = event {
                                try handleHostActions(
                                    host.machine.apply(
                                        .finalFrameAcknowledged,
                                        now: hostNow
                                    ),
                                    now: now
                                )
                            }
                        }
                    }
                } else {
                    // Client side.
                    if delivery.bytes == Self.audioMarker {
                        _ = client.machine.apply(
                            .mediaPathEvidence, now: clientNow
                        )
                    } else {
                        _ = client.machine.apply(
                            .ctrlEvidence, now: clientNow
                        )
                        for event in client.arq.ingest(
                            payload: delivery.bytes, now: clientNow
                        ) {
                            guard case .message(let group, let bytes) = event
                            else { continue }
                            // One-shot groups carry reliable frames,
                            // not typed CTRL messages.
                            guard group == .orderedStream else {
                                XCTAssertEqual(bytes, [0xFF, 0xEE, 0xDD])
                                continue
                            }
                            switch CtrlMessageType.peek(bytes) {
                            case CtrlMessageType.modeTransition:
                                let mode = try ModeTransition
                                    .decode(bytes).mode
                                client.observedModes.append(mode)
                                _ = client.machine.apply(
                                    .modeMessage(mode), now: clientNow
                                )
                            case CtrlMessageType.sessionTeardown:
                                let reason = try SessionTeardown
                                    .decode(bytes).reason
                                _ = client.machine.apply(
                                    .teardownMessage(reason),
                                    now: clientNow
                                )
                            default:
                                XCTFail("unexpected CTRL type")
                            }
                        }
                    }
                }
            }

            // Feedback-window verdicts for the estimator seam, 40 ms.
            if now - lastWindowAt >= 40_000 {
                lastWindowAt = now
                let clean = hostFeedbackSinceWindow > 0
                hostFeedbackSinceWindow = 0
                try handleHostActions(
                    host.machine.apply(
                        .feedbackWindow(clean: clean), now: hostNow
                    ),
                    now: now
                )
            }

            // Timers + ARQ output, both ends.
            let (hostTimerActions, _) = host.machine.poll(now: hostNow)
            try handleHostActions(hostTimerActions, now: now)
            let (clientTimerActions, _) = client.machine.poll(
                now: clientNow
            )
            XCTAssertFalse(
                clientTimerActions.contains(.freezeDatagramSends),
                "a receiver never freezes sends"
            )
            let (hostDatagrams, _) = host.arq.poll(now: hostNow)
            for datagram in hostDatagrams {
                net.send(from: 0, bytes: datagram, now: now)
            }
            let (clientDatagrams, _) = client.arq.poll(now: clientNow)
            for datagram in clientDatagrams {
                net.send(from: 1, bytes: datagram, now: now)
            }

            // Milestone observations.
            if bothIdleAt == nil,
               host.machine.state == .idle,
               client.machine.state == .idle {
                bothIdleAt = now
            }
            if now > blackoutStart, now < blackoutEnd + 400_000 {
                if host.machine.state == .frozen,
                   hostFrozeDuringBlackoutAt == nil {
                    hostFrozeDuringBlackoutAt = now
                }
                if client.machine.state == .frozen,
                   clientFrozeDuringBlackoutAt == nil {
                    clientFrozeDuringBlackoutAt = now
                }
            }
            if client.machine.state == .frozen {
                client.frozenObserved = true
            }
            if hostRecoveredAt == nil, now > blackoutEnd,
               host.machine.state == .active {
                hostRecoveredAt = now
            }

            now += 5_000
        }

        // Phase A: the convergence handoff flipped both ends to IDLE —
        // final frame acked first, mode message second.
        let idleAt = try XCTUnwrap(bothIdleAt)
        XCTAssertLessThan(idleAt, blackoutStart, "idle before blackout")
        XCTAssertEqual(client.observedModes.first, .idle)

        // Phase B: both ends derived FROZEN inside the blackout window.
        let hostFroze = try XCTUnwrap(hostFrozeDuringBlackoutAt)
        let clientFroze = try XCTUnwrap(clientFrozeDuringBlackoutAt)
        XCTAssertGreaterThan(hostFroze, blackoutStart)
        XCTAssertGreaterThan(clientFroze, blackoutStart)
        XCTAssertTrue(client.frozenObserved)

        // Phase C: RECOVERY ran exactly once — one forced IDR at the
        // half-stale policy — and graduated to ACTIVE; the re-signaled
        // mode=active survived 5% loss via the ARQ.
        XCTAssertEqual(host.forceIdrPacings, [.halfStaleEstimate])
        XCTAssertEqual(host.freezeCount, 1)
        XCTAssertEqual(host.resumeCount, 1)
        XCTAssertEqual(host.sentModeMessages, [.idle, .active])
        let recoveredAt = try XCTUnwrap(hostRecoveredAt)
        XCTAssertLessThan(recoveredAt, lossyEnd)
        XCTAssertEqual(client.observedModes, [.idle, .active])

        // Teardown: the typed reason arrived; both ends closed.
        XCTAssertEqual(host.machine.state, .closed)
        XCTAssertEqual(
            host.machine.closeReason, .localTeardown(.shuttingDown)
        )
        XCTAssertEqual(client.machine.state, .closed)
        XCTAssertEqual(
            client.machine.closeReason, .peerTeardown(.shuttingDown)
        )
    }
}
