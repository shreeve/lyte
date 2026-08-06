import XCTest
import LyteWire

// W-G5b's named properties (core plan §4), asserted as behavior:
//   - the pre-arm flag survives FROZEN and is consumed exactly once,
//     by RECOVERY's IDR;
//   - RECOVERY's IDR is paced at the half-stale-estimate policy;
//   - two consecutive clean windows graduate RECOVERY → ACTIVE (a
//     dirty window resets the count);
// plus the lifecycle sequences the pillars pin: the convergence
// handoff (final frame acked before the idle flip; damage aborts),
// WAKE pacing, the beacon-cannot-freeze rule, re-freeze from RECOVERY,
// liveness accounting, and teardown ordering.

final class SessionStateMachineTests: XCTestCase {

    typealias Machine = SessionStateMachine<HostClock>
    typealias Instant = WireTimestamp<HostClock>

    let t0 = Instant(microseconds: 10_000_000)

    func freshSender() -> Machine {
        Machine(role: .mediaSender, now: t0)
    }

    // MARK: The convergence handoff (overview conflict 5)

    func testIdleFlipWaitsForFinalFrameAck() {
        var m = freshSender()
        XCTAssertEqual(
            m.apply(.ratchetConverged, now: t0),
            [.sendFinalFrameReliably]
        )
        // Converged but unacknowledged: still ACTIVE, no mode message
        // yet — the receiver must hold the frame before it learns the
        // session went idle.
        XCTAssertEqual(m.state, .active)
        XCTAssertTrue(m.awaitingFinalFrameAcknowledgement)

        let t1 = t0.advanced(byMicroseconds: 20_000)
        XCTAssertEqual(
            m.apply(.finalFrameAcknowledged, now: t1),
            [.sendModeMessage(.idle)]
        )
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.wireMode, .idle)
        XCTAssertFalse(m.awaitingFinalFrameAcknowledgement)
    }

    func testDamageAbortsPendingIdleFlip() {
        var m = freshSender()
        _ = m.apply(.ratchetConverged, now: t0)
        // New damage during the handoff: the session never left
        // ACTIVE, and the now-stale one-shot's ack must not flip.
        XCTAssertEqual(
            m.apply(.damage, now: t0.advanced(byMicroseconds: 5_000)), []
        )
        XCTAssertFalse(m.awaitingFinalFrameAcknowledgement)
        XCTAssertEqual(
            m.apply(
                .finalFrameAcknowledged,
                now: t0.advanced(byMicroseconds: 10_000)
            ),
            []
        )
        XCTAssertEqual(m.state, .active)
    }

    func testFreezeDropsPendingIdleFlip() {
        var m = freshSender()
        _ = m.apply(.ratchetConverged, now: t0)
        let frozenAt = t0.advanced(byMicroseconds: 350_000)
        _ = m.poll(now: frozenAt)
        XCTAssertEqual(m.state, .frozen)
        XCTAssertFalse(m.awaitingFinalFrameAcknowledgement)
        // The late ack arrives during FROZEN: ignored — RECOVERY
        // re-ratchets, and the wire mode never flipped, so the two
        // ends stay consistent without a message.
        XCTAssertEqual(
            m.apply(
                .finalFrameAcknowledged,
                now: frozenAt.advanced(byMicroseconds: 1_000)
            ),
            []
        )
        XCTAssertEqual(m.state, .frozen)
    }

    // MARK: WAKE (overview conflict 14, timing §7)

    func testWakePacesAtLastGoodRate() {
        var m = freshSender()
        _ = m.apply(.ratchetConverged, now: t0)
        _ = m.apply(.finalFrameAcknowledged, now: t0)
        XCTAssertEqual(m.state, .idle)

        let actions = m.apply(
            .preArmInput, now: t0.advanced(byMicroseconds: 100_000)
        )
        XCTAssertEqual(actions, [
            .sendModeMessage(.active),
            .armNextDamageAsIdr(.lastGoodRate),
        ])
        XCTAssertEqual(m.state, .active)
    }

    // MARK: Pre-arm through FROZEN (the conflict-14 property)

    func testPreArmSurvivesFrozenAndIsConsumedExactlyOnce() {
        var m = freshSender()
        var now = t0.advanced(byMicroseconds: 350_000)
        _ = m.poll(now: now)
        XCTAssertEqual(m.state, .frozen)

        // The keypress lands mid-blackout.
        now = now.advanced(byMicroseconds: 50_000)
        _ = m.apply(.preArmInput, now: now)
        XCTAssertTrue(m.isPreArmed)

        // It survives an arbitrarily long freeze.
        now = now.advanced(byMicroseconds: 10_000_000)
        _ = m.poll(now: now)
        XCTAssertEqual(m.state, .frozen)
        XCTAssertTrue(m.isPreArmed)

        // RECOVERY's IDR consumes it — exactly once.
        let actions = m.apply(.mediaPathEvidence, now: now)
        XCTAssertEqual(
            actions.filter {
                if case .forceIdr = $0 { return true } else { return false }
            },
            [.forceIdr(.halfStaleEstimate)]
        )
        XCTAssertFalse(m.isPreArmed)

        // A second freeze/recover cycle without new input emits its
        // own IDR but carries no stale pre-arm. RECOVERY's silence bar
        // is the longer grace (not ACTIVE's 350 ms).
        now = now.advanced(byMicroseconds: 2_000_000)
        _ = m.poll(now: now)
        XCTAssertEqual(m.state, .frozen)
        XCTAssertFalse(m.isPreArmed)
    }

    // MARK: RECOVERY (resiliency §4)

    func testRecoveryIdrUsesHalfStalePolicy() {
        var m = freshSender()
        var now = t0.advanced(byMicroseconds: 350_000)
        _ = m.poll(now: now)
        now = now.advanced(byMicroseconds: 400_000)
        let actions = m.apply(.mediaPathEvidence, now: now)
        XCTAssertEqual(actions, [
            .resumeDatagramSends,
            .forceIdr(.halfStaleEstimate),
        ])
        XCTAssertEqual(m.state, .recovery)
    }

    func testTwoCleanWindowsGraduateRecovery() {
        var m = freshSender()
        var now = t0.advanced(byMicroseconds: 350_000)
        _ = m.poll(now: now)
        _ = m.apply(.mediaPathEvidence, now: now)
        XCTAssertEqual(m.state, .recovery)

        now = now.advanced(byMicroseconds: 40_000)
        _ = m.apply(.feedbackWindow(clean: true), now: now)
        XCTAssertEqual(m.state, .recovery)
        XCTAssertEqual(m.consecutiveCleanWindows, 1)

        now = now.advanced(byMicroseconds: 40_000)
        _ = m.apply(.feedbackWindow(clean: true), now: now)
        XCTAssertEqual(m.state, .active)
        XCTAssertEqual(m.consecutiveCleanWindows, 0)
    }

    func testDirtyWindowResetsTheCount() {
        var m = freshSender()
        var now = t0.advanced(byMicroseconds: 350_000)
        _ = m.poll(now: now)
        _ = m.apply(.mediaPathEvidence, now: now)

        now = now.advanced(byMicroseconds: 40_000)
        _ = m.apply(.feedbackWindow(clean: true), now: now)
        now = now.advanced(byMicroseconds: 40_000)
        _ = m.apply(.feedbackWindow(clean: false), now: now)
        XCTAssertEqual(m.consecutiveCleanWindows, 0)
        XCTAssertEqual(m.state, .recovery)

        // "Consecutive" means consecutive: it takes two more.
        now = now.advanced(byMicroseconds: 40_000)
        _ = m.apply(.feedbackWindow(clean: true), now: now)
        XCTAssertEqual(m.state, .recovery)
        now = now.advanced(byMicroseconds: 40_000)
        _ = m.apply(.feedbackWindow(clean: true), now: now)
        XCTAssertEqual(m.state, .active)
    }

    func testRenewedSilenceRefreezesRecovery() {
        var m = freshSender()
        var now = t0.advanced(byMicroseconds: 350_000)
        _ = m.poll(now: now)
        _ = m.apply(.mediaPathEvidence, now: now)
        XCTAssertEqual(m.state, .recovery)

        // ACTIVE's 350 ms bar must NOT re-freeze RECOVERY — that is the
        // live thrash: CTRL wakes recovery, forceIdr starts, silence
        // kills mid-flight, next beacon forceIdrs again.
        now = now.advanced(byMicroseconds: 350_000)
        var (actions, _) = m.poll(now: now)
        XCTAssertEqual(m.state, .recovery)
        XCTAssertEqual(actions, [])

        // Renewed silence past the recovery grace still re-freezes.
        now = now.advanced(byMicroseconds: 2_000_000 - 350_000)
        (actions, _) = m.poll(now: now)
        XCTAssertEqual(m.state, .frozen)
        XCTAssertEqual(actions, [.freezeDatagramSends])
    }

    func testCtrlWakeDoesNotThrashRecoveryAtActiveSilenceBar() {
        // Live harsh-path shape: media-path silence freezes; a beacon
        // (CTRL) exits FROZEN with forceIdr; without the recovery grace
        // the next 350 ms would re-freeze and the next CTRL would mint
        // another IDR — dozens per session at beacon cadence.
        var m = freshSender()
        var now = t0.advanced(byMicroseconds: 350_000)
        _ = m.poll(now: now)
        XCTAssertEqual(m.state, .frozen)

        now = now.advanced(byMicroseconds: 1_000_000)
        let wake = m.apply(.ctrlEvidence, now: now)
        XCTAssertEqual(wake, [
            .resumeDatagramSends,
            .forceIdr(.halfStaleEstimate),
        ])
        XCTAssertEqual(m.state, .recovery)

        // ACTIVE bar: still RECOVERY, no second freeze/forceIdr.
        now = now.advanced(byMicroseconds: 350_000)
        let (mid, _) = m.poll(now: now)
        XCTAssertEqual(m.state, .recovery)
        XCTAssertEqual(mid, [])
        XCTAssertEqual(
            m.apply(.ctrlEvidence, now: now), [],
            "CTRL while already recovering must not mint another forceIdr"
        )

        // Past recovery grace with no media: re-freeze once, then one
        // more CTRL earns exactly one more forceIdr — not a 350 ms loop.
        now = now.advanced(byMicroseconds: 2_000_000 - 350_000)
        let (refreeze, _) = m.poll(now: now)
        XCTAssertEqual(m.state, .frozen)
        XCTAssertEqual(refreeze, [.freezeDatagramSends])
        now = now.advanced(byMicroseconds: 1_000_000)
        let second = m.apply(.ctrlEvidence, now: now)
        XCTAssertEqual(second, [
            .resumeDatagramSends,
            .forceIdr(.halfStaleEstimate),
        ])
    }

    // MARK: The silence detector's evidence discipline

    func testBeaconEvidenceCannotSuppressTheBlackoutDetector() {
        // 1 Hz beacon-class evidence with a dead media path: the
        // 350 ms detector must still fire (overview conflict 10 — a
        // 1 Hz beacon could never drive a 350 ms detector, so it must
        // not feed it either).
        var m = freshSender()
        let t1 = t0.advanced(byMicroseconds: 300_000)
        _ = m.apply(.ctrlEvidence, now: t1)
        let t2 = t0.advanced(byMicroseconds: 350_000)
        _ = m.poll(now: t2)
        XCTAssertEqual(m.state, .frozen)
    }

    func testMediaEvidenceReArmsTheDetector() {
        var m = freshSender()
        let t1 = t0.advanced(byMicroseconds: 300_000)
        _ = m.apply(.mediaPathEvidence, now: t1)
        let t2 = t0.advanced(byMicroseconds: 350_000)
        _ = m.poll(now: t2)
        XCTAssertEqual(m.state, .active)
        // ...but only for another window.
        let t3 = t1.advanced(byMicroseconds: 350_000)
        _ = m.poll(now: t3)
        XCTAssertEqual(m.state, .frozen)
    }

    func testRecoveryEntryReArmsTheSilenceClock() {
        // FROZEN exit via beacon-class evidence must grant the fresh
        // path a full 350 ms window — otherwise a stale media clock
        // would re-freeze on the very next poll and the machine would
        // thrash FROZEN⇄RECOVERY at beacon cadence.
        var m = freshSender()
        var now = t0.advanced(byMicroseconds: 350_000)
        _ = m.poll(now: now)
        now = now.advanced(byMicroseconds: 5_000_000)
        _ = m.apply(.ctrlEvidence, now: now)
        XCTAssertEqual(m.state, .recovery)
        let (actions, _) = m.poll(now: now.advanced(byMicroseconds: 1))
        XCTAssertEqual(actions, [])
        XCTAssertEqual(m.state, .recovery)
    }

    // MARK: Deadlines

    func testPollReportsTheEarlierOfSilenceAndLiveness() {
        var m = freshSender()
        let (_, deadline) = m.poll(now: t0)
        XCTAssertEqual(
            deadline, t0.advanced(byMicroseconds: 350_000)
        )

        // In FROZEN only the liveness clock is armed.
        var frozen = freshSender()
        let frozenAt = t0.advanced(byMicroseconds: 350_000)
        let (_, frozenDeadline) = frozen.poll(now: frozenAt)
        XCTAssertEqual(
            frozenDeadline, t0.advanced(byMicroseconds: 30_000_000)
        )
    }

    // MARK: Liveness and teardown

    func testLivenessRunsOnAnyPeerEvidence() {
        var m = freshSender()
        // 29 s of nothing but beacon echoes: the session lives.
        var now = t0
        for _ in 0..<29 {
            now = now.advanced(byMicroseconds: 1_000_000)
            _ = m.apply(.ctrlEvidence, now: now)
        }
        _ = m.poll(now: now)
        XCTAssertNotEqual(m.state, .closed)

        // 30 s past the last echo: closed, no wire message — the peer
        // that would read it is gone.
        now = now.advanced(byMicroseconds: 30_000_000)
        let (actions, _) = m.poll(now: now)
        XCTAssertEqual(m.state, .closed)
        XCTAssertEqual(actions, [.sessionClosed(.livenessTimeout)])
        XCTAssertFalse(actions.contains {
            if case .sendTeardownMessage = $0 { return true }
            return false
        })
    }

    func testOrderlyTeardownEmitsTypedMessageThenCloses() {
        var m = freshSender()
        let actions = m.apply(.teardownRequest(.takenOver), now: t0)
        XCTAssertEqual(actions, [
            .sendTeardownMessage(.takenOver),
            .sessionClosed(.localTeardown(.takenOver)),
        ])
        XCTAssertEqual(m.state, .closed)
        XCTAssertEqual(m.closeReason, .localTeardown(.takenOver))

        // Absorbing: nothing ever comes out again.
        XCTAssertEqual(
            m.apply(.mediaPathEvidence, now: t0.advanced(byMicroseconds: 1)),
            []
        )
    }

    func testPeerTeardownCarriesItsReason() {
        var m = Machine(role: .mediaReceiver, now: t0)
        let actions = m.apply(.teardownMessage(.takenOver), now: t0)
        XCTAssertEqual(
            actions, [.sessionClosed(.peerTeardown(.takenOver))]
        )
        XCTAssertEqual(m.closeReason, .peerTeardown(.takenOver))
    }

    // MARK: The receiver mirror

    func testReceiverMirrorsModeAndDerivesFrozen() {
        var m = Machine(role: .mediaReceiver, now: t0)
        _ = m.apply(.modeMessage(.idle), now: t0)
        XCTAssertEqual(m.state, .idle)

        // Host goes dark: the pill state.
        var now = t0.advanced(byMicroseconds: 350_000)
        _ = m.poll(now: now)
        XCTAssertEqual(m.state, .frozen)

        // Host traffic returns; the receiver lands back on IDLE (the
        // last agreed wire mode) with no actions — surfacing is the
        // shell's job, driven by observing `state`.
        now = now.advanced(byMicroseconds: 2_000_000)
        XCTAssertEqual(m.apply(.mediaPathEvidence, now: now), [])
        XCTAssertEqual(m.state, .idle)

        // The wake arrives as a mode message.
        now = now.advanced(byMicroseconds: 10_000)
        _ = m.apply(.modeMessage(.active), now: now)
        XCTAssertEqual(m.state, .active)
    }

    func testModeMessageExitsReceiverFrozenDirectly() {
        // A delivered mode message during FROZEN is itself evidence
        // AND the new mode — both must apply.
        var m = Machine(role: .mediaReceiver, now: t0)
        var now = t0.advanced(byMicroseconds: 350_000)
        _ = m.poll(now: now)
        XCTAssertEqual(m.state, .frozen)
        now = now.advanced(byMicroseconds: 1_000)
        _ = m.apply(.modeMessage(.idle), now: now)
        XCTAssertEqual(m.state, .idle)
        // And the silence clock was re-armed by the delivery.
        let (actions, _) = m.poll(now: now.advanced(byMicroseconds: 1))
        XCTAssertEqual(actions, [])
        XCTAssertEqual(m.state, .idle)
    }

    // MARK: Config knobs

    func testConfigWindowsToRecoverIsFloored() {
        let config = SessionMachineConfig(cleanWindowsToRecover: 0)
        XCTAssertEqual(config.cleanWindowsToRecover, 1)
        var m = Machine(role: .mediaSender, config: config, now: t0)
        var now = t0.advanced(byMicroseconds: 350_000)
        _ = m.poll(now: now)
        _ = m.apply(.mediaPathEvidence, now: now)
        now = now.advanced(byMicroseconds: 40_000)
        _ = m.apply(.feedbackWindow(clean: true), now: now)
        XCTAssertEqual(m.state, .active)
    }
}
