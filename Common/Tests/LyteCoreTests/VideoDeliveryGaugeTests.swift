import XCTest
@testable import LyteCore

// The 2026-07-30 overlay-gauge law, pinned: every gauge describes the last
// ~3 seconds through one window implementation. These values print on the
// owner's glass every second; the arithmetic must not drift silently.

final class RateMeterTests: XCTestCase {
    func testNilUntilHalfASecondOfHistory() {
        var meter = RateMeter()
        XCTAssertNil(meter.rate(count: 0, nowMicroseconds: 1_000_000))
        XCTAssertNil(meter.rate(count: 30, nowMicroseconds: 1_499_999))
        XCTAssertNotNil(meter.rate(count: 31, nowMicroseconds: 1_500_000))
    }

    func testTrailingWindowRate() {
        var meter = RateMeter()
        _ = meter.rate(count: 0, nowMicroseconds: 0)
        _ = meter.rate(count: 60, nowMicroseconds: 1_000_000)
        let rate = meter.rate(count: 120, nowMicroseconds: 2_000_000)
        XCTAssertEqual(rate ?? 0, 60.0, accuracy: 0.001)
    }

    func testAnchorEvictionForgetsRatesOlderThanTheWindow() {
        var meter = RateMeter()
        _ = meter.rate(count: 0, nowMicroseconds: 0)
        _ = meter.rate(count: 120, nowMicroseconds: 1_000_000)
        for second in 2...10 {
            let now = UInt64(second) * 1_000_000
            let count = UInt64(120 + (second - 1) * 60)
            let rate = meter.rate(count: count, nowMicroseconds: now)
            if second >= 5 {
                XCTAssertEqual(
                    rate ?? 0, 60.0, accuracy: 0.001,
                    "burst still anchoring at t=\(second)s")
            }
        }
    }

    func testSharedClockLawTwoMetersAgree() {
        var inbound = RateMeter()
        var outbound = RateMeter()
        for second in 0...5 {
            let now = UInt64(second) * 1_000_000
            let count = UInt64(second * 60)
            let first = inbound.rate(count: count, nowMicroseconds: now)
            let second = outbound.rate(count: count, nowMicroseconds: now)
            XCTAssertEqual(first, second)
        }
    }
}

final class VideoDeliveryGaugeTests: XCTestCase {
    func testEmptyGaugeAnswersNil() {
        var gauge = VideoDeliveryGauge()
        let snapshot = gauge.snapshot(nowMicroseconds: 1_000_000)
        XCTAssertNil(snapshot.outFps)
        XCTAssertNil(snapshot.hopP50)
        XCTAssertNil(snapshot.hopP99)
    }

    func testHopPercentilesFromRecordedDurations() {
        var gauge = VideoDeliveryGauge()
        // 99 quick hops and one renderer stall: p50 stays calm, p99 carries
        // the resize-storm signature this gauge was built to expose.
        for _ in 0..<99 { gauge.record(hopMilliseconds: 0.1) }
        gauge.record(hopMilliseconds: 50.0)
        let snapshot = gauge.snapshot(nowMicroseconds: 10_000_000)
        XCTAssertEqual(snapshot.hopP50 ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(snapshot.hopP99 ?? 0, 50.0, accuracy: 0.001)
    }

    func testRingWrapKeepsOnlyTheGaugeWindow() {
        var gauge = VideoDeliveryGauge()
        for _ in 0..<180 { gauge.record(hopMilliseconds: 40.0) }
        for _ in 0..<180 { gauge.record(hopMilliseconds: 0.1) }
        let snapshot = gauge.snapshot(nowMicroseconds: 10_000_000)
        XCTAssertEqual(
            snapshot.hopP99 ?? 0, 0.1, accuracy: 0.001,
            "pre-wrap samples leaked into the gauge")
    }

    func testResetRetiresBothRateAndHopHistory() {
        var gauge = VideoDeliveryGauge()
        _ = gauge.snapshot(nowMicroseconds: 1_000_000)
        gauge.record(hopMilliseconds: 40.0)
        gauge.reset()
        let snapshot = gauge.snapshot(nowMicroseconds: 2_000_000)
        XCTAssertNil(snapshot.outFps)
        XCTAssertNil(snapshot.hopP50)
        XCTAssertNil(snapshot.hopP99)
    }
}
