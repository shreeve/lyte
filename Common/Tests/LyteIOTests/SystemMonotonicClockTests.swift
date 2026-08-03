import XCTest

@testable import LyteIO

#if os(Linux)
import Glibc
#endif

final class SystemMonotonicClockTests: XCTestCase {
    func testNanosecondsNeverMoveBackward() {
        var previous = SystemMonotonicClock.nowNanoseconds
        for _ in 0..<10_000 {
            let next = SystemMonotonicClock.nowNanoseconds
            XCTAssertGreaterThanOrEqual(next, previous)
            previous = next
        }
    }

    func testUnitViewsShareTheSameUptimeDomain() {
        let before = SystemMonotonicClock.nowNanoseconds
        let microseconds = SystemMonotonicClock.nowMicroseconds
        let seconds = SystemMonotonicClock.nowSeconds
        let after = SystemMonotonicClock.nowNanoseconds

        XCTAssertGreaterThanOrEqual(microseconds, before / 1_000)
        XCTAssertLessThanOrEqual(microseconds, after / 1_000)
        XCTAssertGreaterThanOrEqual(seconds, Double(before) / 1_000_000_000)
        XCTAssertLessThanOrEqual(seconds, Double(after) / 1_000_000_000)
    }

    #if os(Linux)
    func testLinuxProviderPreservesClockMonotonicDomain() {
        var before = timespec()
        var after = timespec()
        _ = clock_gettime(CLOCK_MONOTONIC, &before)
        let shared = SystemMonotonicClock.nowNanoseconds
        _ = clock_gettime(CLOCK_MONOTONIC, &after)

        let beforeNanoseconds = UInt64(before.tv_sec) * 1_000_000_000
            + UInt64(before.tv_nsec)
        let afterNanoseconds = UInt64(after.tv_sec) * 1_000_000_000
            + UInt64(after.tv_nsec)
        XCTAssertGreaterThanOrEqual(shared, beforeNanoseconds)
        XCTAssertLessThanOrEqual(shared, afterNanoseconds)
    }
    #endif
}
