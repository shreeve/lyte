import LyteTestKit
import XCTest

final class Sha256RatchetTests: XCTestCase {
    func testSharedSha256HasNoProductionTwinOrWrapper() throws {
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
        let violations = try RepositorySourceTree().violations(
            containing: forbidden,
            excludingRelativePaths: ["Common/Sources/LyteCore/Sha256.swift"],
            excludingPathPrefixes: ["Wire/Sources/LyteWire/Crypto/"]
        )

        XCTAssertTrue(
            violations.isEmpty,
            "SHA-256 twins or wrappers reintroduced:\n"
                + violations.sorted().joined(separator: "\n")
        )
    }
}
