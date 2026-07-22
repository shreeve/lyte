import XCTest
import HostCore

final class HistogramTests: XCTestCase {

    func testEmptyReportsNothing() {
        let h = Histogram()
        XCTAssertEqual(h.count, 0)
        XCTAssertNil(h.minValue)
        XCTAssertNil(h.maxValue)
        XCTAssertNil(h.p50)
        XCTAssertNil(h.p99)
    }

    func testNearestRankPercentiles() {
        var h = Histogram()
        // 1...100 shuffled: percentiles are exact and order-free.
        for value in Array(1...100).shuffled() {
            h.record(UInt64(value))
        }
        XCTAssertEqual(h.count, 100)
        XCTAssertEqual(h.minValue, 1)
        XCTAssertEqual(h.maxValue, 100)
        XCTAssertEqual(h.p50, 50)
        XCTAssertEqual(h.p95, 95)
        XCTAssertEqual(h.p99, 99)
        XCTAssertEqual(h.percentile(1.0), 100)
        XCTAssertEqual(h.percentile(0.0), 1)
        XCTAssertFalse(h.saturated)
    }

    func testSingleSampleIsEveryPercentile() {
        var h = Histogram()
        h.record(42)
        XCTAssertEqual(h.p50, 42)
        XCTAssertEqual(h.p99, 42)
    }

    func testSaturationKeepsCountMinMaxExact() {
        var h = Histogram(capacity: 4)
        for value in [5, 1, 9, 3, 100, 2] {
            h.record(UInt64(value))
        }
        XCTAssertEqual(h.count, 6)
        XCTAssertTrue(h.saturated)
        XCTAssertEqual(h.minValue, 1, "min stays exact past the cap")
        XCTAssertEqual(h.maxValue, 100, "max stays exact past the cap")
        // Percentiles report over the retained prefix [5, 1, 9, 3].
        XCTAssertEqual(h.percentile(1.0), 9)
    }
}
