import LyteTestKit
import XCTest

final class WireTosRatchetTests: XCTestCase {
    func testSharedWireTosHasNoProductionVocabularyTwin() throws {
        let forbidden = [
            "enum WireTos",
            "struct WireTos",
            "var tos: Int32 = 0xC0",
            "return 0xC0 // CS6",
            "return 0xA0 // CS5",
            "return 0x20 // CS1",
            "0x1116 /* SO_NET_SERVICE_TYPE */",
        ]
        let violations = try RepositorySourceTree().violations(
            containing: forbidden,
            excludingRelativePaths: ["Common/Sources/LyteCore/WireTos.swift"]
        )

        XCTAssertTrue(
            violations.isEmpty,
            "TOS/DSCP vocabulary twins reintroduced:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }
}
