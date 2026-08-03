import Foundation
import XCTest

final class AnnexBRatchetTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testSharedAnnexBWalkerHasNoProductionTwin() throws {
        let roots = [
            Self.repositoryRoot.appendingPathComponent("Sources"),
            Self.repositoryRoot.appendingPathComponent("Host/Sources"),
            Self.repositoryRoot.appendingPathComponent("Wire/Sources"),
            Self.repositoryRoot.appendingPathComponent("Common/IO"),
        ]
        let forbidden = [
            "enum AnnexB {",
            "enum AnnexBCheck {",
            "enum AnnexBAccessUnits {",
            "enum HevcNal {",
            "struct NalUnit {",
            "struct NalUnit:",
        ]
        var violations: [String] = []

        for root in roots {
            guard let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for declaration in forbidden where source.contains(declaration) {
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
            "Annex-B twins reintroduced:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }
}
