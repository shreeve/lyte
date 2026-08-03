import Foundation
import XCTest

final class ClientLayoutTests: XCTestCase {
    func testRepositoryRootNoLongerMasqueradesAsTheClientPackage() {
        let root = URL(fileURLWithPath: ClientTestPaths.repositoryRoot)
        for retiredPath in ["Package.swift", "Package.resolved", "Sources", "Tests"] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(retiredPath).path),
                "retired root client path returned: \(retiredPath)"
            )
        }
    }

    func testClientPackageKeepsTheDeclaredTargetGrammar() throws {
        let root = URL(fileURLWithPath: ClientTestPaths.repositoryRoot)
            .appendingPathComponent("Client")
        XCTAssertEqual(
            try directoryNames(at: root.appendingPathComponent("Sources")),
            [
                "Lyte", "LyteCorpus", "LyteHelperProtocol", "LyteTransport",
                "LyteUI", "lyte-cli", "lyte-helperd",
            ]
        )
        XCTAssertEqual(
            try directoryNames(at: root.appendingPathComponent("Tests")),
            ["LyteTransportTests", "LyteUITests"]
        )
        XCTAssertEqual(
            try directoryNames(
                at: root.appendingPathComponent(
                    "Tests/LyteTransportTests/Fixtures"
                )
            ),
            ["Goldens"]
        )
    }

    private func directoryNames(at root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.map(\.lastPathComponent).sorted()
    }
}
