import Foundation
import XCTest

final class HexRatchetTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testSharedHexHasNoProductionEncoderTwin() throws {
        let roots = [
            Self.repositoryRoot.appendingPathComponent("Sources"),
            Self.repositoryRoot.appendingPathComponent("Host/Sources"),
            Self.repositoryRoot.appendingPathComponent("Wire/Sources"),
            Self.repositoryRoot.appendingPathComponent("Common/IO"),
        ]
        let forbidden = [
            "enum Hex",
            "struct Hex",
            "static func hex(_ bytes",
            "private static func hex16",
            "static func hexByte",
            "String(format: \"%02x\"",
            "String(format: \"%02X\"",
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
            "hex encoder twins reintroduced:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }
}
