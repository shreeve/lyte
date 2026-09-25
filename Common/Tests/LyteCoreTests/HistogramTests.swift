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

    /// Ranks are exact integer arithmetic, not floating-point accidents:
    /// 0.07 × 100 is 7.000000000000001 in binary and 0.29 × 100 is
    /// 28.999999999999996, yet their ranks are exactly 7 and 29.
    func testRanksAreExactAtEveryRepresentableBoundary() {
        var histogram = Histogram<Int>(capacity: 1_000)
        for value in 1...100 { histogram.record(value) }
        XCTAssertEqual(histogram.percentile(0.07), 7)
        XCTAssertEqual(histogram.percentile(0.29, rank: .upperBoundary), 30)
        for count in 1...200 {
            let values = Array(1...count)
            for hundredths in 0...100 {
                let q = Double(hundredths) / 100
                let rank = (hundredths * count + 99) / 100
                XCTAssertEqual(
                    Histogram<Int>.percentile(of: values, q),
                    values[max(rank, 1) - 1], "nearest q=\(q) n=\(count)")
                XCTAssertEqual(
                    Histogram<Int>.percentile(of: values, q, rank: .upperBoundary),
                    values[min(hundredths * count / 100, count - 1)],
                    "upper q=\(q) n=\(count)")
            }
        }
    }
}
