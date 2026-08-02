import XCTest
@testable import LyteTransport

final class AdaptiveVideoPlayoutTests: XCTestCase {
    func testDelayIsClampedGrowsFastAndShrinksSlowly() {
        var policy = AdaptiveVideoPlayout(config: .init(
            shrinkHoldFrames: 2,
            shrinkCadenceFrames: 2))
        let first = policy.schedule(
            mappedCaptureMicroseconds: 1_000_000,
            arrivalMicroseconds: 1_010_000)
        XCTAssertEqual(first.targetDelayMicroseconds, 20_000)

        let late = policy.schedule(
            mappedCaptureMicroseconds: 1_016_667,
            arrivalMicroseconds: 1_056_667)
        XCTAssertGreaterThan(late.targetDelayMicroseconds, 20_000)
        XCTAssertLessThanOrEqual(late.targetDelayMicroseconds, 50_000)

        let beforeShrink = late.targetDelayMicroseconds
        let early = policy.schedule(
            mappedCaptureMicroseconds: 2_000_000,
            arrivalMicroseconds: 2_001_000)
        XCTAssertEqual(early.targetDelayMicroseconds, beforeShrink)

        for i in 0..<1_000 {
            _ = policy.schedule(
                mappedCaptureMicroseconds: 3_000_000 + UInt64(i) * 16_667,
                arrivalMicroseconds: 3_001_000 + UInt64(i) * 16_667)
        }
        XCTAssertEqual(policy.targetDelayMicroseconds, 15_000)
    }

    func testCushionCeilingDecidesWhichStallsAreAbsorbed() {
        // The owner's Settings knob is the delay CEILING. A 115 ms
        // radio deaf-window (the measured 2026-08-01 class) breaks
        // through the default 50 ms cap forever; with the cap raised
        // to 120 ms the SECOND such stall arrives inside the grown
        // cushion and presents on time.
        func run(capMicroseconds: UInt64) -> UInt64 {
            var policy = AdaptiveVideoPlayout(config: .init(
                maximumDelayMicroseconds: capMicroseconds))
            // A settled cadence, then one 115 ms stall to teach it.
            for i in 0..<10 {
                _ = policy.schedule(
                    mappedCaptureMicroseconds: 1_000_000
                        + UInt64(i) * 16_667,
                    arrivalMicroseconds: 1_002_000 + UInt64(i) * 16_667)
            }
            _ = policy.schedule(
                mappedCaptureMicroseconds: 1_166_670,
                arrivalMicroseconds: 1_166_670 + 117_000)
            // The next stall of the same size: absorbed or not?
            let second = policy.schedule(
                mappedCaptureMicroseconds: 1_500_000,
                arrivalMicroseconds: 1_500_000 + 117_000)
            return second.latenessMicroseconds
        }
        XCTAssertGreaterThan(
            run(capMicroseconds: 50_000), 0,
            "a 117 ms stall must break through the default 50 ms cap")
        XCTAssertEqual(
            run(capMicroseconds: 120_000), 0,
            "a 120 ms cushion must absorb the second 117 ms stall")
    }

    func testZeroCeilingTurnsTheCushionOffEntirely() {
        // Slider at 0: floor/initial/ceiling all collapse to zero and
        // every frame — punctual or late — presents the instant it
        // arrives. No delay is ever learned.
        var policy = AdaptiveVideoPlayout(config: .init(
            minimumDelayMicroseconds: 0,
            maximumDelayMicroseconds: 0,
            initialDelayMicroseconds: 0))
        for i in 0..<10 {
            let d = policy.schedule(
                mappedCaptureMicroseconds: 1_000_000 + UInt64(i) * 16_667,
                arrivalMicroseconds: 1_002_000 + UInt64(i) * 16_667)
            XCTAssertEqual(
                d.presentationMicroseconds, 1_002_000 + UInt64(i) * 16_667)
            XCTAssertEqual(d.targetDelayMicroseconds, 0)
        }
        let stalled = policy.schedule(
            mappedCaptureMicroseconds: 1_500_000,
            arrivalMicroseconds: 1_617_000)
        XCTAssertEqual(stalled.presentationMicroseconds, 1_617_000)
        XCTAssertEqual(stalled.targetDelayMicroseconds, 0,
                       "a 0 ceiling must never learn any delay")
    }

    func testExcessiveLatenessRebasesWithCushionWithoutBreakingContinuity() {
        var policy = AdaptiveVideoPlayout()
        let decision = policy.schedule(
            mappedCaptureMicroseconds: 1_000_000,
            arrivalMicroseconds: 1_100_001)
        XCTAssertFalse(decision.shouldFlush)
        XCTAssertEqual(decision.targetDelayMicroseconds, 50_000)
        XCTAssertEqual(decision.presentationMicroseconds, 1_100_001)
        let sameEpisode = policy.schedule(
            mappedCaptureMicroseconds: 1_016_667,
            arrivalMicroseconds: 1_116_668)
        XCTAssertFalse(sameEpisode.shouldFlush)
        XCTAssertEqual(sameEpisode.presentationMicroseconds, 1_116_668)

        let clockModelCatchesUp = policy.schedule(
            mappedCaptureMicroseconds: 1_033_334,
            arrivalMicroseconds: 1_133_335)
        XCTAssertFalse(clockModelCatchesUp.shouldFlush)
        XCTAssertEqual(clockModelCatchesUp.presentationMicroseconds, 1_133_335)
    }

    func testResetRestoresFreshSessionState() {
        var policy = AdaptiveVideoPlayout()
        _ = policy.schedule(
            mappedCaptureMicroseconds: 0, arrivalMicroseconds: 100_000)
        policy.reset()
        XCTAssertEqual(policy.targetDelayMicroseconds, 20_000)
    }

    func testRetainedFrameRatchetDoesNotMintLatenessOrRecovery() {
        var policy = AdaptiveVideoPlayout()
        let capture: UInt64 = 1_000_000
        _ = policy.schedule(
            mappedCaptureMicroseconds: capture,
            arrivalMicroseconds: capture + 5_000)

        for arrival in stride(
            from: capture + 100_000,
            through: capture + 900_000,
            by: 100_000
        ) {
            let repeatFrame = policy.schedule(
                mappedCaptureMicroseconds: capture,
                arrivalMicroseconds: arrival)
            XCTAssertEqual(repeatFrame.latenessMicroseconds, 0)
            XCTAssertFalse(repeatFrame.shouldFlush)
            XCTAssertEqual(
                repeatFrame.presentationMicroseconds,
                arrival + repeatFrame.targetDelayMicroseconds)
        }

        let fresh = policy.schedule(
            mappedCaptureMicroseconds: capture + 1_000_000,
            arrivalMicroseconds: capture + 1_005_000)
        XCTAssertEqual(fresh.latenessMicroseconds, 0)
        XCTAssertFalse(fresh.shouldFlush)
    }

    func testFreshBlackoutBurstStartsOneBoundedDebtRecovery() {
        var policy = AdaptiveVideoPlayout()
        _ = policy.schedule(
            mappedCaptureMicroseconds: 1_000_000,
            arrivalMicroseconds: 1_005_000,
            sourceCaptureMicroseconds: 1_000_000,
            isRandomAccess: true)

        let burstArrival: UInt64 = 1_500_000
        var recoveries = 0
        for index in 1...20 {
            let decision = policy.schedule(
                mappedCaptureMicroseconds:
                    1_000_000 + UInt64(index) * 16_667,
                arrivalMicroseconds: burstArrival,
                sourceCaptureMicroseconds:
                    1_000_000 + UInt64(index) * 16_667)
            if decision.shouldFlush { recoveries += 1 }
            XCTAssertLessThanOrEqual(
                decision.presentationMicroseconds,
                burstArrival + policy.config.maximumDelayMicroseconds)
        }
        XCTAssertEqual(recoveries, 1)

        let idr = policy.schedule(
            mappedCaptureMicroseconds: 1_600_000,
            arrivalMicroseconds: 1_605_000,
            sourceCaptureMicroseconds: 1_600_000,
            isRandomAccess: true)
        XCTAssertFalse(idr.shouldFlush)
        XCTAssertLessThanOrEqual(
            idr.presentationMicroseconds,
            1_605_000 + policy.config.maximumDelayMicroseconds)
        policy.noteRandomAccessEnqueued()

        // The same compressed collapse continuing after that IDR must not
        // mint a second episode.
        for index in 1...20 {
            let covered = policy.schedule(
                mappedCaptureMicroseconds:
                    1_600_000 + UInt64(index) * 16_667,
                arrivalMicroseconds: 1_605_000,
                sourceCaptureMicroseconds:
                    1_600_000 + UInt64(index) * 16_667)
            XCTAssertFalse(covered.shouldFlush)
            if index == 1 {
                XCTAssertGreaterThan(
                    covered.presentationMicroseconds,
                    idr.presentationMicroseconds)
            }
        }

        // Cadence stability, not the IDR header, re-arms debt recovery.
        for index in 0...30 {
            let capture = 2_000_000 + UInt64(index) * 16_667
            _ = policy.schedule(
                mappedCaptureMicroseconds: capture,
                arrivalMicroseconds: capture + 5_000,
                sourceCaptureMicroseconds: capture)
        }
        var secondCollapseRecoveries = 0
        for index in 1...20 {
            let decision = policy.schedule(
                mappedCaptureMicroseconds:
                    3_000_000 + UInt64(index) * 16_667,
                arrivalMicroseconds: 3_500_000,
                sourceCaptureMicroseconds:
                    3_000_000 + UInt64(index) * 16_667)
            if decision.shouldFlush { secondCollapseRecoveries += 1 }
        }
        XCTAssertEqual(secondCollapseRecoveries, 1)
    }

    func testOrdinaryFreshJitterRebasesWithoutDebtRecovery() {
        var policy = AdaptiveVideoPlayout()
        var previousPresentation: UInt64 = 0
        for index in 0..<30 {
            let capture = 2_000_000 + UInt64(index) * 16_667
            let jitter: UInt64
            switch index {
            case 10: jitter = 35_000
            case 11: jitter = 20_000
            case 12: jitter = 8_000
            default: jitter = 5_000
            }
            let arrival = capture + jitter
            let decision = policy.schedule(
                mappedCaptureMicroseconds: capture,
                arrivalMicroseconds: arrival,
                sourceCaptureMicroseconds: capture,
                isRandomAccess: index == 0)
            XCTAssertFalse(decision.shouldFlush)
            XCTAssertGreaterThan(decision.presentationMicroseconds, previousPresentation)
            XCTAssertLessThanOrEqual(
                decision.presentationMicroseconds,
                arrival + policy.config.maximumDelayMicroseconds)
            previousPresentation = decision.presentationMicroseconds
        }
    }

    func testLateFreshFrameDoesNotDoubleCountAdaptiveDelay() {
        var policy = AdaptiveVideoPlayout()
        let first = policy.schedule(
            mappedCaptureMicroseconds: 2_000_000,
            arrivalMicroseconds: 2_005_000,
            sourceCaptureMicroseconds: 2_000_000)
        let late = policy.schedule(
            mappedCaptureMicroseconds: 2_016_667,
            arrivalMicroseconds: 2_051_667,
            sourceCaptureMicroseconds: 2_016_667)

        XCTAssertGreaterThan(late.targetDelayMicroseconds, 19_900)
        XCTAssertEqual(late.presentationMicroseconds, 2_051_667)
        XCTAssertLessThan(
            late.presentationMicroseconds,
            2_051_667 + late.targetDelayMicroseconds,
            "the measured path excursion must not be paid twice")
        XCTAssertGreaterThan(late.presentationMicroseconds,
                             first.presentationMicroseconds)
    }

    func testNotReadyQueuesWholeDependencyChainInOrder() {
        var handoff = BoundedRendererHandoff<Int>(
            config: .init(capacity: 4, deadlineMicroseconds: 50_000))
        for frame in 0..<4 {
            let outcome = handoff.offer(
                frame,
                isRandomAccess: frame == 0,
                nowMicroseconds: UInt64(frame) * 1_000)
            XCTAssertTrue(outcome.accepted)
            XCTAssertFalse(outcome.recoveryRequested)
            XCTAssertTrue(outcome.discarded.isEmpty)
        }
        XCTAssertEqual(handoff.count, 4)
        XCTAssertEqual(
            (0..<4).compactMap { _ in handoff.popReady()?.element },
            [0, 1, 2, 3])
    }

    func testPressureDropsEpisodeAndRequestsOneRecoveryUntilIdr() {
        var handoff = BoundedRendererHandoff<Int>(
            config: .init(capacity: 3, deadlineMicroseconds: 50_000))
        _ = handoff.offer(0, isRandomAccess: true, nowMicroseconds: 0)
        _ = handoff.offer(1, isRandomAccess: false, nowMicroseconds: 1_000)
        _ = handoff.offer(2, isRandomAccess: false, nowMicroseconds: 2_000)

        let overflow = handoff.offer(
            3, isRandomAccess: false, nowMicroseconds: 3_000)
        XCTAssertFalse(overflow.accepted)
        XCTAssertTrue(overflow.recoveryRequested)
        XCTAssertEqual(overflow.discarded.map(\.element), [0, 1, 2, 3])
        XCTAssertTrue(handoff.awaitingRandomAccess)

        let covered = handoff.offer(
            4, isRandomAccess: false, nowMicroseconds: 4_000)
        XCTAssertFalse(covered.accepted)
        XCTAssertFalse(covered.recoveryRequested)
        XCTAssertEqual(covered.discarded.map(\.element), [4])

        let idr = handoff.offer(
            5, isRandomAccess: true, nowMicroseconds: 5_000)
        XCTAssertTrue(idr.accepted)
        XCTAssertFalse(idr.recoveryRequested)
        XCTAssertTrue(handoff.awaitingRandomAccess)
        XCTAssertEqual(handoff.popReady()?.element, 5)
        handoff.noteRandomAccessEnqueued()
        XCTAssertFalse(handoff.awaitingRandomAccess)
    }

    func testDependencyDamageRejectsEveryPFrameUntilIdrIsEnqueued() {
        var handoff = BoundedRendererHandoff<Int>()
        _ = handoff.offer(10, isRandomAccess: false, nowMicroseconds: 0)

        let damage = handoff.failEpisode()
        XCTAssertTrue(damage.recoveryRequested)
        XCTAssertEqual(damage.discarded.map(\.element), [10])

        for frame in 11...20 {
            let blocked = handoff.offer(
                frame, isRandomAccess: false,
                nowMicroseconds: UInt64(frame) * 1_000)
            XCTAssertFalse(blocked.accepted)
            XCTAssertFalse(blocked.recoveryRequested)
            XCTAssertEqual(blocked.discarded.map(\.element), [frame])
        }

        let idr = handoff.offer(
            21, isRandomAccess: true, nowMicroseconds: 21_000)
        XCTAssertTrue(idr.accepted)
        XCTAssertTrue(handoff.awaitingRandomAccess)

        // Damage discovered after IRAP acceptance but before enqueue
        // invalidates that IRAP without opening or flushing a second episode.
        let overlap = handoff.failEpisode()
        XCTAssertFalse(overlap.recoveryRequested)
        XCTAssertEqual(overlap.discarded.map(\.element), [21])
        XCTAssertTrue(handoff.awaitingRandomAccess)
        XCTAssertFalse(handoff.randomAccessPending)

        let beforeEnqueue = handoff.offer(
            22, isRandomAccess: false, nowMicroseconds: 22_000)
        XCTAssertFalse(beforeEnqueue.accepted)
        XCTAssertEqual(beforeEnqueue.discarded.map(\.element), [22])

        let replacement = handoff.offer(
            23, isRandomAccess: true, nowMicroseconds: 23_000)
        XCTAssertTrue(replacement.accepted)
        XCTAssertFalse(replacement.recoveryRequested)
        XCTAssertEqual(handoff.popReady()?.element, 23)
        handoff.noteRandomAccessEnqueued()
        let afterEnqueue = handoff.offer(
            24, isRandomAccess: false, nowMicroseconds: 24_000)
        XCTAssertTrue(afterEnqueue.accepted)
    }

    func testRendererFlushBarrierBlocksEnqueueUntilCompletion() {
        var barrier = RendererRecoveryFlushBarrier()
        XCTAssertTrue(barrier.mayEnqueue)
        XCTAssertTrue(barrier.begin())
        XCTAssertFalse(barrier.mayEnqueue)
        XCTAssertFalse(barrier.begin(), "overlap must not start a second flush")
        barrier.complete()
        XCTAssertTrue(barrier.mayEnqueue)
    }

    func testDeadlineStartsSameSingleRecoveryEpisode() {
        var handoff = BoundedRendererHandoff<Int>(
            config: .init(capacity: 4, deadlineMicroseconds: 10_000))
        _ = handoff.offer(0, isRandomAccess: true, nowMicroseconds: 0)
        _ = handoff.offer(1, isRandomAccess: false, nowMicroseconds: 1_000)
        let expired = handoff.expire(nowMicroseconds: 10_000)
        XCTAssertTrue(expired.recoveryRequested)
        XCTAssertEqual(expired.discarded.map(\.element), [0, 1])
        XCTAssertTrue(handoff.awaitingRandomAccess)
        XCTAssertFalse(
            handoff.failEpisode().recoveryRequested,
            "one pressure episode must not mint repeated recoveries")
    }
}
