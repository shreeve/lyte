import XCTest

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
