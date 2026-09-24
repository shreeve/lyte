import Foundation
import LyteTestKit
import XCTest

/// What a fresh install runs: the seeded host.conf's LYTE_HOST_ARGS.
/// Clipboard sync and file drops are consent, off until the owner adds
/// them, so the seed turns on neither.
final class SeededHostConfTests: XCTestCase {
    func testAFreshInstallTurnsOnNoConsentGatedFeature() throws {
        let tree = RepositorySourceTree()
        let seed = tree.repositoryRoot
            .appendingPathComponent("Host/Systemd/host.conf")
        let lines = try String(contentsOf: seed, encoding: .utf8)
            .split(separator: "\n")
        let assignment = try XCTUnwrap(
            lines.first { $0.hasPrefix("LYTE_HOST_ARGS=") },
            "the seed sets LYTE_HOST_ARGS")
        let args = assignment.dropFirst("LYTE_HOST_ARGS=".count)
            .split(separator: " ").map(String.init)
        XCTAssertTrue(args.contains("--wire-listen"))
        for consent in ["--clipboard", "--accept-files"] {
            XCTAssertFalse(
                args.contains { $0 == consent || $0.hasPrefix(consent + "=") },
                "a fresh install must not turn on \(consent)")
        }
    }
}
