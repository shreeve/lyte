import LyteTestKit
import XCTest

final class HevcBitsRatchetTests: XCTestCase {
    func testSharedHevcBitVocabularyHasNoProductionTwin() throws {
        let forbidden = [
            "struct HevcBitWriter",
            "struct BitReader",
            "struct HevcBitReader",
            "func stripEmulationPrevention",
        ]
        let violations = try RepositorySourceTree().violations(
            containing: forbidden,
            excludingRelativePaths: [
                "Common/Sources/LyteCore/HevcBits.swift"
            ]
        )

        XCTAssertTrue(
            violations.isEmpty,
            "HEVC bit-codec twins reintroduced:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }
}
