import LyteTestKit
import XCTest

final class ChromaPairingRatchetTests: XCTestCase {
    func testBestSingletonHasNoProductionTwin() throws {
        let violations = try RepositorySourceTree().violations(
            containing: ["[CapabilityChroma.yuv444]"],
            excludingRelativePaths: [
                "Common/Sources/LyteCore/ChromaPairing.swift"
            ]
        )

        XCTAssertTrue(
            violations.isEmpty,
            "Best chroma singleton twins reintroduced:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }
}
