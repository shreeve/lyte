import LyteTestKit
import XCTest

final class AnnexBRatchetTests: XCTestCase {
    func testSharedAnnexBWalkerHasNoProductionTwin() throws {
        let forbidden = [
            "enum AnnexB {",
            "enum AnnexBCheck {",
            "enum AnnexBAccessUnits {",
            "enum HevcNal {",
            "struct NalUnit {",
            "struct NalUnit:",
        ]
        let violations = try RepositorySourceTree().violations(
            containing: forbidden,
            excludingRelativePaths: ["Common/Sources/LyteCore/AnnexB.swift"]
        )

        XCTAssertTrue(
            violations.isEmpty,
            "Annex-B twins reintroduced:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }
}
