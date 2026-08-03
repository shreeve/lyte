import Foundation
import XCTest

final class Sha256RatchetTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testSharedSha256HasNoProductionTwinOrWrapper() throws {
        let roots = [
            Self.repositoryRoot.appendingPathComponent("Sources"),
            Self.repositoryRoot.appendingPathComponent("Host/Sources"),
            Self.repositoryRoot.appendingPathComponent("Wire/Sources"),
            Self.repositoryRoot.appendingPathComponent("Common/IO"),
        ]
        let forbidden = [
            "0x428A_2F98",
            "struct Sha256",
            "enum Sha256",
            "class Sha256",
            "struct Sha256Stream",
            "struct StreamingSha256",
            "enum IdentityHash",
            "private static func sha256",
            "SHA256.hash",
        ]
        var violations: [String] = []

        for root in roots {
            guard let files = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                if file.path.contains("Wire/Sources/LyteWire/Crypto/") {
                    continue
                }
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
            "SHA-256 twins or wrappers reintroduced:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }
}
