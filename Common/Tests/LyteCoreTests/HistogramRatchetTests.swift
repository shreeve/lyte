import LyteTestKit
import XCTest

final class HistogramRatchetTests: XCTestCase {
    func testCumulativeCountAloneOwnsSaturation() throws {
        let tree = RepositorySourceTree()
        let source = try String(
            contentsOf: tree.repositoryRoot.appendingPathComponent(
                "Common/Sources/LyteCore/Histogram.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "public var saturated: Bool { count > capacity }"))
        XCTAssertFalse(source.contains("saturated ="))
    }

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
