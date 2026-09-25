import XCTest
import LyteWireTestKit

/// Asserts that `body` throws exactly `expected`.
func assertThrows<E: Error & Equatable, T>(
    _ expected: E, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line,
    _ body: () throws -> T
) {
    XCTAssertThrowsError(try body(), message(), file: file, line: line) {
        XCTAssertEqual($0 as? E, expected, message(), file: file, line: line)
    }
}

/// Asserts that `body` throws an `E` whose case name is `expected`: the
/// check every frozen vector file's reject rows pin.
func assertVectorReject<E: Error, T>(
    _ type: E.Type, _ expected: String?, _ name: String,
    file: StaticString = #filePath, line: UInt = #line,
    _ body: () throws -> T
) {
    XCTAssertThrowsError(try body(), name, file: file, line: line) {
        guard let error = $0 as? E else {
            return XCTFail("\(name): foreign error \($0)", file: file, line: line)
        }
        XCTAssertEqual(
            vectorErrorName(error), expected, name, file: file, line: line
        )
    }
}
