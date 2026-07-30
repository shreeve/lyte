import XCTest
import LyteTransport

// The 2026-07-30 overlay-gauge law, pinned: every gauge describes the
// last ~3 s through ONE window implementation, and the watchdog's
// 3-strike debounce behaves exactly as the AWDL choppiness verdict
// demands. These types render on the owner's glass every second; the
// arithmetic must not drift silently.

final class RateMeterTests: XCTestCase {

    func testNilUntilHalfASecondOfHistory() {
        let meter = RateMeter()
        XCTAssertNil(meter.rate(count: 0, nowMicroseconds: 1_000_000))
        XCTAssertNil(meter.rate(count: 30, nowMicroseconds: 1_499_999))
        XCTAssertNotNil(meter.rate(count: 31, nowMicroseconds: 1_500_000))
    }

    func testTrailingWindowRate() {
        let meter = RateMeter()
        // 60 counts/second, sampled once per second.
        _ = meter.rate(count: 0, nowMicroseconds: 0)
        _ = meter.rate(count: 60, nowMicroseconds: 1_000_000)
        let r = meter.rate(count: 120, nowMicroseconds: 2_000_000)
        XCTAssertEqual(r ?? 0, 60.0, accuracy: 0.001)
    }

    func testAnchorEvictionForgetsRatesOlderThanTheWindow() {
        let meter = RateMeter()
        // A fast opening burst (120/s), then a 60/s steady state: once
        // the burst ages past the 3 s window, the answer must be the
        // steady rate, not a blend anchored at t=0.
        _ = meter.rate(count: 0, nowMicroseconds: 0)
        _ = meter.rate(count: 120, nowMicroseconds: 1_000_000)
        for second in 2...10 {
            let now = UInt64(second) * 1_000_000
            let count = UInt64(120 + (second - 1) * 60)
            let r = meter.rate(count: count, nowMicroseconds: now)
            if second >= 5 {
                XCTAssertEqual(r ?? 0, 60.0, accuracy: 0.001,
                               "burst still anchoring at t=\(second)s")
            }
        }
    }

    func testSharedClockLawTwoMetersAgree() {
        // The in/out slash-pair contract: identical feeds through two
        // meters answer identically — no per-meter window drift.
        let inMeter = RateMeter()
        let outMeter = RateMeter()
        for second in 0...5 {
            let now = UInt64(second) * 1_000_000
            let count = UInt64(second * 60)
            let a = inMeter.rate(count: count, nowMicroseconds: now)
            let b = outMeter.rate(count: count, nowMicroseconds: now)
            XCTAssertEqual(a, b)
        }
    }
}

final class VideoDeliveryBooksTests: XCTestCase {

    func testEmptyBooksAnswerNil() {
        let books = VideoDeliveryBooks()
        let snap = books.snapshot(nowMicroseconds: 1_000_000)
        XCTAssertNil(snap.outFps)
        XCTAssertNil(snap.hopP50)
        XCTAssertNil(snap.hopP99)
    }

    func testHopPercentilesFromRecordedDurations() {
        let books = VideoDeliveryBooks()
        // 99 quick hops and one renderer stall: p50 stays calm, p99
        // carries the stall (the resize-storm signature this book was
        // built to expose).
        for _ in 0..<99 { books.record(hopMilliseconds: 0.1) }
        books.record(hopMilliseconds: 50.0)
        let snap = books.snapshot(nowMicroseconds: 10_000_000)
        XCTAssertEqual(snap.hopP50 ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(snap.hopP99 ?? 0, 50.0, accuracy: 0.001)
    }

    func testRingWrapKeepsOnlyTheGaugeWindow() {
        let books = VideoDeliveryBooks()
        // 180 slow hops (an old bad era), then 180 quick ones: the ring
        // holds ~3 s at 60 fps, so the old era must be fully evicted.
        for _ in 0..<180 { books.record(hopMilliseconds: 40.0) }
        for _ in 0..<180 { books.record(hopMilliseconds: 0.1) }
        let snap = books.snapshot(nowMicroseconds: 10_000_000)
        XCTAssertEqual(snap.hopP99 ?? 0, 0.1, accuracy: 0.001,
                       "pre-wrap samples leaked into the gauge")
    }
}

final class LatencyHistogramPercentilesTests: XCTestCase {

    func testMultiQuantileMatchesSingleCallsExactly() {
        var histogram = LatencyHistogram(capacity: 128)
        XCTAssertEqual(histogram.percentiles([0.5, 0.99]), [nil, nil])
        for value in [7, 3, 99, 1, 42, 42, 500, 12] {
            histogram.record(UInt64(value))
        }
        let multi = histogram.percentiles([0.0, 0.5, 0.95, 0.99, 1.0])
        XCTAssertEqual(multi, [
            histogram.percentile(0.0),
            histogram.p50,
            histogram.p95,
            histogram.p99,
            histogram.percentile(1.0),
        ], "one sort must answer exactly what five sorts did")
    }
}

final class RadioHoldPolicyTests: XCTestCase {

    func testHeldRadioIsHealthy() {
        var policy = RadioHoldPolicy()
        XCTAssertEqual(policy.check(radioUp: false), .none)
        XCTAssertFalse(policy.alarm)
        XCTAssertEqual(policy.looseChecks, 0)
    }

    func testFirstLooseSightingAsksForReengage() {
        var policy = RadioHoldPolicy()
        XCTAssertEqual(policy.check(radioUp: true), .reengage)
        XCTAssertFalse(policy.alarm, "one sighting must not alarm")
    }

    func testThreeConsecutiveLooseChecksLatchTheAlarm() {
        var policy = RadioHoldPolicy()
        XCTAssertEqual(policy.check(radioUp: true), .reengage)
        XCTAssertEqual(policy.check(radioUp: true), .none)
        XCTAssertFalse(policy.alarm)
        XCTAssertEqual(policy.check(radioUp: true), .none)
        XCTAssertTrue(policy.alarm)
    }

    func testRecoveryClearsStrikesAndAlarm() {
        var policy = RadioHoldPolicy()
        for _ in 0..<3 { _ = policy.check(radioUp: true) }
        XCTAssertTrue(policy.alarm)
        XCTAssertEqual(policy.check(radioUp: false), .none)
        XCTAssertFalse(policy.alarm)
        // The next loose era is a fresh episode: re-engage fires again.
        XCTAssertEqual(policy.check(radioUp: true), .reengage)
    }

    func testResetForStreamEnd() {
        var policy = RadioHoldPolicy()
        _ = policy.check(radioUp: true)
        _ = policy.check(radioUp: true)
        policy.reset()
        XCTAssertEqual(policy, RadioHoldPolicy())
    }
}
