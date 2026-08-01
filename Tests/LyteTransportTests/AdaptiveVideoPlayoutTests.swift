import XCTest
@testable import LyteTransport

final class AdaptiveVideoPlayoutTests: XCTestCase {
    func testDelayIsClampedGrowsFastAndShrinksSlowly() {
        var policy = AdaptiveVideoPlayout()
        let first = policy.schedule(
            mappedCaptureMicroseconds: 1_000_000,
            arrivalMicroseconds: 1_010_000)
        XCTAssertEqual(first.targetDelayMicroseconds, 19_900)

        let late = policy.schedule(
            mappedCaptureMicroseconds: 1_016_667,
            arrivalMicroseconds: 1_056_667)
        XCTAssertGreaterThan(late.targetDelayMicroseconds, 19_900)
        XCTAssertLessThanOrEqual(late.targetDelayMicroseconds, 50_000)

        let beforeShrink = late.targetDelayMicroseconds
        let early = policy.schedule(
            mappedCaptureMicroseconds: 2_000_000,
            arrivalMicroseconds: 2_001_000)
        XCTAssertEqual(early.targetDelayMicroseconds, beforeShrink - 100)

        for i in 0..<1_000 {
            _ = policy.schedule(
                mappedCaptureMicroseconds: 3_000_000 + UInt64(i) * 16_667,
                arrivalMicroseconds: 3_001_000 + UInt64(i) * 16_667)
        }
        XCTAssertEqual(policy.targetDelayMicroseconds, 15_000)
    }

    func testExcessiveLatenessRebasesWithCushionWithoutBreakingContinuity() {
        var policy = AdaptiveVideoPlayout()
        let decision = policy.schedule(
            mappedCaptureMicroseconds: 1_000_000,
            arrivalMicroseconds: 1_100_001)
        XCTAssertFalse(decision.shouldFlush)
        XCTAssertEqual(decision.targetDelayMicroseconds, 50_000)
        XCTAssertEqual(decision.presentationMicroseconds, 1_150_001)
        let sameEpisode = policy.schedule(
            mappedCaptureMicroseconds: 1_016_667,
            arrivalMicroseconds: 1_116_668)
        XCTAssertFalse(sameEpisode.shouldFlush)
        XCTAssertEqual(sameEpisode.presentationMicroseconds, 1_166_668)

        let clockModelCatchesUp = policy.schedule(
            mappedCaptureMicroseconds: 1_033_334,
            arrivalMicroseconds: 1_133_335)
        XCTAssertFalse(clockModelCatchesUp.shouldFlush)
        XCTAssertEqual(clockModelCatchesUp.presentationMicroseconds, 1_183_335)
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
        XCTAssertFalse(handoff.awaitingRandomAccess)
        XCTAssertEqual(handoff.popReady()?.element, 5)
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
