import XCTest
@testable import LyteCore

final class RendererHandoffPolicyTests: XCTestCase {
    private func frame(
        randomAccess: Bool,
        submittedMicroseconds: UInt64
    ) -> RendererFrameDescriptor {
        RendererFrameDescriptor(
            isRandomAccess: randomAccess,
            submittedMicroseconds: submittedMicroseconds)
    }

    func testNotReadyQueuesWholeDependencyChainInOrder() {
        var handoff = BoundedRendererHandoff<Int>(
            config: .init(capacity: 4, deadlineMicroseconds: 50_000))
        for number in 0..<4 {
            let outcome = handoff.offer(
                number,
                frame: frame(
                    randomAccess: number == 0,
                    submittedMicroseconds: UInt64(number) * 1_000))
            XCTAssertTrue(outcome.accepted)
            XCTAssertFalse(outcome.recoveryRequested)
            XCTAssertTrue(outcome.discarded.isEmpty)
        }
        XCTAssertEqual(handoff.count, 4)
        XCTAssertEqual(
            (0..<4).compactMap { _ in handoff.popReady()?.element },
            [0, 1, 2, 3])
    }

    /// Submission stamps are taken on different threads: a frame stamped
    /// a microsecond before the queue's head has waited no time, and
    /// neither has the head at a clock reading that trails it.
    func testAStampBehindTheHeadIsNotAnExpiredEpisode() {
        var handoff = BoundedRendererHandoff<Int>(
            config: .init(capacity: 4, deadlineMicroseconds: 50_000))
        XCTAssertTrue(handoff.offer(
            0, frame: frame(randomAccess: true, submittedMicroseconds: 10_000)
        ).accepted)
        let earlier = handoff.offer(
            1, frame: frame(randomAccess: false, submittedMicroseconds: 9_999))
        XCTAssertTrue(earlier.accepted)
        XCTAssertFalse(earlier.recoveryRequested)
        XCTAssertTrue(earlier.discarded.isEmpty)
        XCTAssertTrue(handoff.expire(nowMicroseconds: 9_000).discarded.isEmpty)
        XCTAssertEqual(handoff.count, 2)
        XCTAssertFalse(handoff.awaitingRandomAccess)
    }

    func testPressureDropsEpisodeAndRequestsOneRecoveryUntilIdr() {
        var handoff = BoundedRendererHandoff<Int>(
            config: .init(capacity: 3, deadlineMicroseconds: 50_000))
        for number in 0..<3 {
            _ = handoff.offer(
                number,
                frame: frame(
                    randomAccess: number == 0,
                    submittedMicroseconds: UInt64(number) * 1_000))
        }

        let overflow = handoff.offer(
            3, frame: frame(randomAccess: false, submittedMicroseconds: 3_000))
        XCTAssertFalse(overflow.accepted)
        XCTAssertTrue(overflow.recoveryRequested)
        XCTAssertEqual(overflow.discarded.map(\.element), [0, 1, 2, 3])
        XCTAssertTrue(handoff.awaitingRandomAccess)

        let covered = handoff.offer(
            4, frame: frame(randomAccess: false, submittedMicroseconds: 4_000))
        XCTAssertFalse(covered.accepted)
        XCTAssertFalse(covered.recoveryRequested)
        XCTAssertEqual(covered.discarded.map(\.element), [4])

        let idr = handoff.offer(
            5, frame: frame(randomAccess: true, submittedMicroseconds: 5_000))
        XCTAssertTrue(idr.accepted)
        XCTAssertFalse(idr.recoveryRequested)
        XCTAssertTrue(handoff.awaitingRandomAccess)
        XCTAssertEqual(handoff.popReady()?.element, 5)
        handoff.noteRandomAccessEnqueued()
        XCTAssertFalse(handoff.awaitingRandomAccess)
    }

    func testDependencyDamageRejectsEveryPFrameUntilIdrIsEnqueued() {
        var handoff = BoundedRendererHandoff<Int>()
        _ = handoff.offer(
            10, frame: frame(randomAccess: false, submittedMicroseconds: 0))

        let damage = handoff.failEpisode()
        XCTAssertTrue(damage.recoveryRequested)
        XCTAssertEqual(damage.discarded.map(\.element), [10])

        for number in 11...20 {
            let blocked = handoff.offer(
                number,
                frame: frame(
                    randomAccess: false,
                    submittedMicroseconds: UInt64(number) * 1_000))
            XCTAssertFalse(blocked.accepted)
            XCTAssertFalse(blocked.recoveryRequested)
            XCTAssertEqual(blocked.discarded.map(\.element), [number])
        }

        let idr = handoff.offer(
            21, frame: frame(randomAccess: true, submittedMicroseconds: 21_000))
        XCTAssertTrue(idr.accepted)
        XCTAssertTrue(handoff.awaitingRandomAccess)

        // Damage that voids the pending IRAP voids the episode's answer:
        // it must ask again, or nothing ever will.
        let overlap = handoff.failEpisode()
        XCTAssertTrue(overlap.recoveryRequested)
        XCTAssertEqual(overlap.discarded.map(\.element), [21])
        XCTAssertTrue(handoff.awaitingRandomAccess)
        XCTAssertFalse(handoff.randomAccessPending)

        let beforeEnqueue = handoff.offer(
            22, frame: frame(randomAccess: false, submittedMicroseconds: 22_000))
        XCTAssertFalse(beforeEnqueue.accepted)
        XCTAssertEqual(beforeEnqueue.discarded.map(\.element), [22])

        let replacement = handoff.offer(
            23, frame: frame(randomAccess: true, submittedMicroseconds: 23_000))
        XCTAssertTrue(replacement.accepted)
        XCTAssertFalse(replacement.recoveryRequested)
        XCTAssertEqual(handoff.popReady()?.element, 23)
        handoff.noteRandomAccessEnqueued()
        let afterEnqueue = handoff.offer(
            24, frame: frame(randomAccess: false, submittedMicroseconds: 24_000))
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
        _ = handoff.offer(
            0, frame: frame(randomAccess: true, submittedMicroseconds: 0))
        _ = handoff.offer(
            1, frame: frame(randomAccess: false, submittedMicroseconds: 1_000))
        let expired = handoff.expire(nowMicroseconds: 10_000)
        XCTAssertTrue(expired.recoveryRequested)
        XCTAssertEqual(expired.discarded.map(\.element), [0, 1])
        XCTAssertTrue(handoff.awaitingRandomAccess)
        XCTAssertFalse(
            handoff.failEpisode().recoveryRequested,
            "one pressure episode must not mint repeated recoveries")
    }

    /// Inter frames that follow an accepted IRAP belong to ITS chain. The
    /// shell drains asynchronously, so they can arrive before the IRAP is
    /// enqueued; they must queue behind it, or the next accepted P frame
    /// would reference a frame the decoder never saw.
    func testInterFramesQueueBehindAPendingIrap() {
        var handoff = BoundedRendererHandoff<Int>(
            config: .init(capacity: 4, deadlineMicroseconds: 50_000))
        _ = handoff.failEpisode()
        let idr = handoff.offer(
            0, frame: frame(randomAccess: true, submittedMicroseconds: 0))
        XCTAssertTrue(idr.accepted)
        XCTAssertTrue(handoff.randomAccessPending)
        for number in 1...2 {
            let follower = handoff.offer(
                number,
                frame: frame(
                    randomAccess: false,
                    submittedMicroseconds: UInt64(number) * 16_000))
            XCTAssertTrue(follower.accepted)
            XCTAssertFalse(follower.recoveryRequested)
            XCTAssertTrue(follower.discarded.isEmpty)
        }
        XCTAssertEqual(handoff.popReady()?.element, 0)
        handoff.noteRandomAccessEnqueued()
        XCTAssertFalse(handoff.awaitingRandomAccess)
        XCTAssertEqual(
            [handoff.popReady()?.element, handoff.popReady()?.element],
            [1, 2])
    }

    /// The pending chain is still bounded: overflow discards the IRAP
    /// with its followers. That IRAP was the episode's answer, so the
    /// overflow asks for a fresh one; the frames after it stay refused
    /// without asking again.
    func testPendingIrapChainOverflowRequestsAFreshRecovery() {
        var handoff = BoundedRendererHandoff<Int>(
            config: .init(capacity: 3, deadlineMicroseconds: 50_000))
        _ = handoff.failEpisode()
        for number in 0..<3 {
            _ = handoff.offer(
                number,
                frame: frame(
                    randomAccess: number == 0,
                    submittedMicroseconds: UInt64(number) * 1_000))
        }
        let overflow = handoff.offer(
            3, frame: frame(randomAccess: false, submittedMicroseconds: 3_000))
        XCTAssertFalse(overflow.accepted)
        XCTAssertTrue(overflow.recoveryRequested)
        XCTAssertEqual(overflow.discarded.map(\.element), [0, 1, 2, 3])
        XCTAssertTrue(handoff.awaitingRandomAccess)
        XCTAssertFalse(handoff.randomAccessPending)
        XCTAssertEqual(handoff.count, 0)

        let covered = handoff.offer(
            4, frame: frame(randomAccess: false, submittedMicroseconds: 4_000))
        XCTAssertFalse(covered.accepted)
        XCTAssertFalse(covered.recoveryRequested)
    }

    /// A stalled consumer (a backgrounded browser tab) overflows once,
    /// the recovery IRAP arrives and is accepted, and the consumer is
    /// still stalled: the IRAP's own chain overflows and discards it.
    /// The stream must ask again; otherwise every later inter frame is
    /// refused and presentation freezes until unrelated loss.
    func testStalledConsumerRecoversAfterItsRecoveryIrapOverflows() {
        var handoff = BoundedRendererHandoff<Int>(
            config: .init(capacity: 12, deadlineMicroseconds: UInt64.max / 4))
        var now: UInt64 = 0
        var recoveries = 0
        func offer(_ number: Int, randomAccess: Bool = false)
            -> BoundedRendererHandoff<Int>.Outcome
        {
            now += 16_667
            let outcome = handoff.offer(
                number,
                frame: frame(randomAccess: randomAccess, submittedMicroseconds: now))
            if outcome.recoveryRequested { recoveries += 1 }
            return outcome
        }
        for number in 0..<13 { _ = offer(number) }
        XCTAssertEqual(recoveries, 1)

        XCTAssertTrue(offer(100, randomAccess: true).accepted)
        XCTAssertTrue(handoff.randomAccessPending)
        for number in 200..<211 { XCTAssertTrue(offer(number).accepted) }
        let overflow = offer(211)
        XCTAssertTrue(overflow.discarded.contains { $0.element == 100 })
        XCTAssertEqual(recoveries, 2, "the discarded IRAP is asked for again")

        for number in 300..<400 {
            let refused = offer(number)
            XCTAssertFalse(refused.accepted)
            XCTAssertFalse(refused.recoveryRequested)
        }
        XCTAssertEqual(recoveries, 2)

        // The consumer returns and the fresh IRAP reopens the chain.
        XCTAssertTrue(offer(500, randomAccess: true).accepted)
        XCTAssertTrue(offer(501).accepted)
        XCTAssertEqual(handoff.popReady()?.element, 500)
        handoff.noteRandomAccessEnqueued()
        XCTAssertFalse(handoff.awaitingRandomAccess)
        XCTAssertEqual(handoff.popReady()?.element, 501)
        XCTAssertTrue(offer(502).accepted)
    }

    /// A shell may pop the IRAP and hold it outside the queue until it is
    /// due (the browser's early-frame slot). Overflowing its chain in that
    /// window leaves the held IRAP unable to close the episode, so the
    /// overflow asks for a fresh one, whose handoff closes it.
    func testOverflowWhileTheIrapIsHeldOutsideTheQueueRequestsRecovery() {
        var handoff = BoundedRendererHandoff<Int>(
            config: .init(capacity: 12, deadlineMicroseconds: UInt64.max / 4))
        _ = handoff.failEpisode()
        var now: UInt64 = 0
        XCTAssertTrue(handoff.offer(
            1, frame: frame(randomAccess: true, submittedMicroseconds: now)
        ).accepted)
        XCTAssertEqual(handoff.popReady()?.element, 1) // held
        var recoveries = 0
        for number in 2..<15 {
            now += 16_667
            let outcome = handoff.offer(
                number, frame: frame(randomAccess: false, submittedMicroseconds: now))
            if outcome.recoveryRequested { recoveries += 1 }
        }
        XCTAssertEqual(recoveries, 1)
        handoff.noteRandomAccessEnqueued() // the held IRAP is handed off
        XCTAssertTrue(handoff.awaitingRandomAccess)

        now += 16_667
        XCTAssertTrue(handoff.offer(
            20, frame: frame(randomAccess: true, submittedMicroseconds: now)
        ).accepted)
        XCTAssertEqual(handoff.popReady()?.element, 20)
        handoff.noteRandomAccessEnqueued()
        XCTAssertFalse(handoff.awaitingRandomAccess)
    }

    /// Expiry of a pending IRAP discards the episode's answer too.
    func testExpiredPendingIrapRequestsAFreshRecovery() {
        var handoff = BoundedRendererHandoff<Int>(
            config: .init(capacity: 4, deadlineMicroseconds: 10_000))
        _ = handoff.failEpisode()
        _ = handoff.offer(
            0, frame: frame(randomAccess: true, submittedMicroseconds: 0))
        let expired = handoff.expire(nowMicroseconds: 10_000)
        XCTAssertTrue(expired.recoveryRequested)
        XCTAssertEqual(expired.discarded.map(\.element), [0])
        XCTAssertFalse(
            handoff.failEpisode().recoveryRequested,
            "the fresh request covers the episode until its IRAP arrives")
    }

    /// An IRAP that overflows a pending IRAP's chain replaces it as the
    /// episode's answer: no recovery is needed.
    func testIrapOverflowingAPendingChainReplacesItWithoutRecovery() {
        var handoff = BoundedRendererHandoff<Int>(
            config: .init(capacity: 3, deadlineMicroseconds: 50_000))
        _ = handoff.failEpisode()
        for number in 0..<3 {
            _ = handoff.offer(
                number,
                frame: frame(
                    randomAccess: number == 0,
                    submittedMicroseconds: UInt64(number) * 1_000))
        }
        let idr = handoff.offer(
            3, frame: frame(randomAccess: true, submittedMicroseconds: 3_000))
        XCTAssertTrue(idr.accepted)
        XCTAssertFalse(idr.recoveryRequested)
        XCTAssertEqual(idr.discarded.map(\.element), [0, 1, 2])
        XCTAssertTrue(handoff.randomAccessPending)
        XCTAssertEqual(handoff.popReady()?.element, 3)
        handoff.noteRandomAccessEnqueued()
        XCTAssertFalse(handoff.awaitingRandomAccess)
    }

    /// An IRAP that overflows the queue restarts the chain by itself:
    /// the stale episode is discarded, but no recovery IRAP is asked for.
    func testOverflowingIrapRestartsTheChainWithoutRecovery() {
        var handoff = BoundedRendererHandoff<Int>(
            config: .init(capacity: 3, deadlineMicroseconds: 50_000))
        for number in 0..<3 {
            _ = handoff.offer(
                number,
                frame: frame(
                    randomAccess: number == 0,
                    submittedMicroseconds: UInt64(number) * 1_000))
        }
        let idr = handoff.offer(
            3, frame: frame(randomAccess: true, submittedMicroseconds: 3_000))
        XCTAssertTrue(idr.accepted)
        XCTAssertFalse(idr.recoveryRequested)
        XCTAssertEqual(idr.discarded.map(\.element), [0, 1, 2])
        XCTAssertFalse(handoff.awaitingRandomAccess)
        XCTAssertEqual(handoff.popReady()?.element, 3)
    }
}
