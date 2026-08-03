import Foundation
import XCTest

final class WireTosRatchetTests: XCTestCase {
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

    func testSharedWireTosHasNoProductionVocabularyTwin() throws {
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Self.repositoryRoot.appendingPathComponent("CLEANUP.md").path))
        let roots = [
            Self.repositoryRoot.appendingPathComponent("Sources"),
            Self.repositoryRoot.appendingPathComponent("Host/Sources"),
            Self.repositoryRoot.appendingPathComponent("Wire/Sources"),
            Self.repositoryRoot.appendingPathComponent("Common/IO"),
        ]
        let forbidden = [
            "enum WireTos",
            "struct WireTos",
            "var tos: Int32 = 0xC0",
            "return 0xC0 // CS6",
            "return 0xA0 // CS5",
            "return 0x20 // CS1",
            "0x1116 /* SO_NET_SERVICE_TYPE */",
        ]
        var violations: [String] = []

        for root in roots {
            guard let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden where source.contains(token) {
                    violations.append(
                        file.path.replacingOccurrences(
                            of: Self.repositoryRoot.path + "/", with: "")
                            + ": " + token
                    )
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "TOS/DSCP vocabulary twins reintroduced:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }
}
