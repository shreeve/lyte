import LyteTestKit
import XCTest

final class HistogramRatchetTests: XCTestCase {
    func testSharedHistogramHasNoProductionTypeTwin() throws {
        let forbiddenDeclarations = [
            "struct Histogram", "struct LatencyHistogram",
            "struct BeatTailRing",
        ]
        let violations = try RepositorySourceTree().violations(
            containing: forbiddenDeclarations,
            excludingRelativePaths: [
                "Common/Sources/LyteCore/Histogram.swift"
            ]
        )

        XCTAssertTrue(
            violations.isEmpty,
            "histogram twins reintroduced:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }
}
