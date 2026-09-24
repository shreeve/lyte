@testable import lyte_host
import XCTest

/// A peer that causes one log line per datagram gets a few lines and
/// then a periodic count, however fast it sends.
final class LogLineLimiterTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    func testAFloodPrintsItsBurstThenOneSummaryPerInterval() {
        var limiter = LogLineLimiter(burst: 3, intervalNS: 10 * second)
        var printed: [String] = []
        for i in 0..<10_000 {
            // 10,000 drops in one second.
            printed += limiter.admit(
                "drop: unsealFailed", now: UInt64(i) * 100_000
            ) { "drop: unsealFailed(\(i))" }
        }
        XCTAssertEqual(printed, [
            "drop: unsealFailed(0)", "drop: unsealFailed(1)",
            "drop: unsealFailed(2)",
        ])

        XCTAssertEqual(limiter.due(now: 5 * second), [],
            "no summary before the interval passes")
        XCTAssertEqual(limiter.due(now: 10 * second), [
            "drop: unsealFailed — 9997 more in the last 10 s (rate-limited)",
        ])
        XCTAssertEqual(limiter.due(now: 30 * second), [],
            "a quiet interval owes nothing")

        let late = limiter.admit("drop: unsealFailed", now: 31 * second) {
            "never formatted"
        }
        XCTAssertEqual(late, [
            "drop: unsealFailed — 1 more in the last 21 s (rate-limited)",
        ], "past the burst a key stays counted, one summary per interval")
    }

    func testKeysAreLimitedIndependentlyAndTheFinalPassOwesEverything() {
        var limiter = LogLineLimiter(burst: 1, intervalNS: 10 * second)
        XCTAssertEqual(limiter.admit("a", now: 0) { "a0" }, ["a0"])
        XCTAssertEqual(limiter.admit("a", now: 1) { "a1" }, [])
        XCTAssertEqual(limiter.admit("b", now: 2) { "b0" }, ["b0"])
        XCTAssertEqual(limiter.due(now: 3, final: true), [
            "a — 1 more in the last 0 s (rate-limited)",
        ])
    }
}
