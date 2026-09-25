import ArgumentParser
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
}
