import Foundation
import XCTest

final class HistogramRatchetTests: XCTestCase {
    private static var repositoryRoot: URL {
        if let override = ProcessInfo.processInfo.environment["LYTE_REPOSITORY_ROOT"] {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LyteCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Common
            .deletingLastPathComponent()  // repository
    }

    func testSharedHistogramHasNoProductionTypeTwin() throws {
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Self.repositoryRoot.appendingPathComponent("CLEANUP.md").path))
        let roots = [
            Self.repositoryRoot.appendingPathComponent("Sources"),
            Self.repositoryRoot.appendingPathComponent("Host/Sources"),
            Self.repositoryRoot.appendingPathComponent("Common/IO"),
        ]
        let forbiddenDeclarations = [
            "struct Histogram", "struct LatencyHistogram",
            "struct BeatTailRing",
        ]
        var violations: [String] = []

        for root in roots {
            guard let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for declaration in forbiddenDeclarations
                where source.contains(declaration) {
                    violations.append(
                        file.path.replacingOccurrences(
                            of: Self.repositoryRoot.path + "/", with: "")
                            + ": " + declaration
                    )
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "histogram twins reintroduced:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }
}
