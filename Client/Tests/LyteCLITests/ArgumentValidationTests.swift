import ArgumentParser
import LyteCore
import XCTest
@testable import lyte_cli

/// Arguments that used to trap mid-run or leak are refused at parse time.
final class ArgumentValidationTests: XCTestCase {
    /// `--pin -` keeps the PIN out of `ps`: it arrives on standard input.
    func testPinCanArriveOnStandardInput() throws {
        XCTAssertNoThrow(try WirePair.parse(["pup", "--pin", "-"]))
        XCTAssertEqual(
            try WirePair.resolvedPin("-", readLine: { "123456 " }), "123456")
        XCTAssertEqual(
            try WirePair.resolvedPin("654321", readLine: {
                XCTFail("an argued PIN never reads standard input")
                return nil
            }),
            "654321")
        XCTAssertThrowsError(try WirePair.resolvedPin("-", readLine: { nil }))
        XCTAssertThrowsError(try WirePair.resolvedPin("-", readLine: { "12ab56" }))
        XCTAssertThrowsError(try WirePair.parse(["pup", "--pin", "12"]))
    }

    /// wire-view prints a book's non-zero scalars, nested books by path,
    /// optionals unwrapped, and a histogram as p50/p99 milliseconds.
    func testStatsBooksPrintOnlyWhatMoved() {
        struct Inner { var late: UInt64 = 3; var target: Int = 0 }
        struct Book {
            var sent: UInt64 = 7
            var failed: UInt64 = 0
            var sigma = 12.5
            var quiescent = true
            var stamp: UInt32? = 9
            var missing: UInt32?
            var jitter = Inner()
            var latency = Histogram<UInt64>()
        }
        var book = Book()
        book.latency.record(2_000)
        XCTAssertEqual(WireViewStatsPrinter.fields(book), [
            "sent=7", "sigma=12.5", "quiescent", "stamp=9", "jitter.late=3",
            "latency=2.0/2.0ms",
        ])
    }
}
