import XCTest
@testable import LyteTransport

// The surviving renderer-side queue policies: the bounded episode
// handoff and the recovery flush barrier. The adaptive playout's
// tests retired with it — the metronome's laws are pinned in
// VideoBeatConductorTests.

final class RendererHandoffPolicyTests: XCTestCase {
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
