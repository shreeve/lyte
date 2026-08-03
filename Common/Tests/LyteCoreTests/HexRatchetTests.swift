import LyteTestKit
import XCTest

final class HexRatchetTests: XCTestCase {
    func testSharedHexHasNoProductionEncoderTwin() throws {
        let forbidden = [
            "enum Hex",
            "struct Hex",
            "static func hex(_ bytes",
            "private static func hex16",
            "static func hexByte",
            "String(format: \"%02x\"",
            "String(format: \"%02X\"",
        ]
        let violations = try RepositorySourceTree().violations(
            containing: forbidden,
            excludingRelativePaths: ["Common/Sources/LyteCore/Hex.swift"]
        )

        XCTAssertTrue(
            violations.isEmpty,
            "hex encoder twins reintroduced:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }
}
