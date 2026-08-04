import LyteCore
import XCTest

final class HistogramTests: XCTestCase {
    func testEmptyReportsNothing() {
        let histogram = Histogram<UInt64>()
        XCTAssertEqual(histogram.count, 0)
        XCTAssertNil(histogram.minValue)
        XCTAssertNil(histogram.maxValue)
        XCTAssertNil(histogram.p50)
        XCTAssertNil(histogram.p99)
        XCTAssertEqual(histogram.percentiles([0.5, 0.99]), [nil, nil])
    }

    func testNearestRankPercentiles() {
        var histogram = Histogram<UInt64>()
        for value in Array(1...100).reversed() {
            histogram.record(UInt64(value))
        }
        XCTAssertEqual(histogram.count, 100)
        XCTAssertEqual(histogram.minValue, 1)
        XCTAssertEqual(histogram.maxValue, 100)
        XCTAssertEqual(histogram.p50, 50)
        XCTAssertEqual(histogram.p95, 95)
        XCTAssertEqual(histogram.p99, 99)
        XCTAssertEqual(histogram.percentile(1), 100)
        XCTAssertEqual(histogram.percentile(0), 1)
        XCTAssertFalse(histogram.saturated)
    }

    func testSingleSampleIsEveryPercentile() {
        var histogram = Histogram<UInt64>()
        histogram.record(42)
        XCTAssertEqual(histogram.p50, 42)
        XCTAssertEqual(histogram.p95, 42)
        XCTAssertEqual(histogram.p99, 42)
    }

    func testSaturationBeginsAtTheFirstSamplePastCapacity() {
        var histogram = Histogram<UInt64>(capacity: 2)
        histogram.record(1)
        histogram.record(2)
        XCTAssertFalse(histogram.saturated)
        histogram.record(3)
        XCTAssertTrue(histogram.saturated)
    }

    func testNearestRankMatchesTheRetiredTailRingAtEveryEdgeCount() {
        // The retired conductor formula was
        // sorted[min(count - 1, (count * 99 + 99) / 100 - 1)].
        for count in [1, 5, 99, 100, 101, 599, 600] {
            var histogram = Histogram<UInt64>(
                capacity: 600, retention: .rolling)
            for value in 1...count {
                histogram.record(UInt64(value))
            }
            let expectedIndex = min(
                count - 1, (count * 99 + 99) / 100 - 1)
            XCTAssertEqual(
                histogram.p99,
                UInt64(expectedIndex + 1),
                "count \(count) must preserve the retired tail rank")
        }
    }

    func testPrefixRetentionDropsPastCapacityButKeepsCumulativeBooks() {
        var histogram = Histogram<UInt64>(capacity: 4, retention: .prefix)
        for value in [5, 1, 9, 3, 100, 2] as [UInt64] {
            histogram.record(value)
        }
        XCTAssertEqual(histogram.count, 6)
        XCTAssertTrue(histogram.saturated)
        XCTAssertEqual(histogram.minValue, 1)
        XCTAssertEqual(histogram.maxValue, 100)
        XCTAssertEqual(histogram.percentile(1), 9)
    }

    func testRollingRetentionKeepsNewestWindowAndCumulativeBooks() {
        var histogram = Histogram<UInt64>(capacity: 4, retention: .rolling)
        for value in [100, 200, 300, 400, 1, 2] as [UInt64] {
            histogram.record(value)
        }
        XCTAssertEqual(histogram.count, 6)
        XCTAssertTrue(histogram.saturated)
        XCTAssertEqual(histogram.minValue, 1)
        XCTAssertEqual(histogram.maxValue, 400)
        XCTAssertEqual(histogram.p99, 400)
        histogram.record(3)
        histogram.record(4)
        XCTAssertEqual(histogram.p99, 4)
    }

    func testMultiQuantileMatchesSingleCallsExactly() {
        var histogram = Histogram<UInt64>(capacity: 128, retention: .rolling)
        for value in [7, 3, 99, 1, 42, 42, 500, 12] as [UInt64] {
            histogram.record(value)
        }
        XCTAssertEqual(
            histogram.percentiles([0, 0.5, 0.95, 0.99, 1]),
            [
                histogram.percentile(0), histogram.p50, histogram.p95,
                histogram.p99, histogram.percentile(1),
            ]
        )
    }

    func testUpperBoundaryPreservesDeliveryGaugeConvention() {
        let values = Array(repeating: 0.1, count: 99) + [50.0]
        XCTAssertEqual(
            Histogram<Double>.percentile(
                of: values, 0.99, rank: .upperBoundary),
            50.0
        )
        XCTAssertEqual(
            Histogram<Double>.percentile(of: values, 0.99),
            0.1
        )
        XCTAssertEqual(
            Histogram<Int>.percentile(
                of: [1, 2, 3, 4], 0.50, rank: .upperBoundary),
            3
        )
        XCTAssertEqual(
            Histogram<Int>.percentile(of: [1, 2, 3, 4], 0.50),
            2
        )
    }

    func testRemoveAllRestoresAnEmptyUnsaturatedHistogram() {
        var histogram = Histogram<UInt64>(capacity: 1, retention: .rolling)
        histogram.record(9)
        histogram.record(7)
        histogram.removeAll()
        XCTAssertTrue(histogram.isEmpty)
        XCTAssertEqual(histogram.count, 0)
        XCTAssertNil(histogram.minValue)
        XCTAssertNil(histogram.maxValue)
        XCTAssertFalse(histogram.saturated)
    }
}
