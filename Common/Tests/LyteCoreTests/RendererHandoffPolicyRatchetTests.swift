import Foundation
import XCTest

final class RendererHandoffPolicyRatchetTests: XCTestCase {
    private static var repositoryRoot: URL {
        if let override = ProcessInfo.processInfo.environment["LYTE_REPOSITORY_ROOT"] {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testSharedRendererHandoffHasNoProductionTwin() throws {
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Self.repositoryRoot.appendingPathComponent("CLEANUP.md").path))
        let roots = [
            Self.repositoryRoot.appendingPathComponent("Sources"),
            Self.repositoryRoot.appendingPathComponent("Host/Sources"),
            Self.repositoryRoot.appendingPathComponent("Wire/Sources"),
            Self.repositoryRoot.appendingPathComponent("Common/IO"),
        ]
        let forbidden = [
            "struct RendererFrameDescriptor",
            "struct BoundedRendererHandoff",
            "struct RendererRecoveryFlushBarrier",
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
                            + ": " + declaration)
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "renderer handoff policy twins reintroduced:\n"
                + violations.sorted().joined(separator: "\n"))
    }
}
