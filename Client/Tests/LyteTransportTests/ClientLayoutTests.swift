import Foundation
import LyteClientTestKit
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
                "Lyte", "LyteClientTestKit", "LyteCorpus", "LyteHelperProtocol",
                "LyteTransport", "LyteUI", "lyte-cli", "lyte-helperd",
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

    func testSessionEndpointPublishesCoreThroughWeakSynchronizedSeam() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: ClientTestPaths.repositoryRoot +
                "/Client/Sources/LyteTransport/LyteUdpSession.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains(
            "private let coreStorage = Mutex<LyteUdpSessionCore?>(nil)"))
        XCTAssertTrue(source.contains("coreStorage.withLock { $0 = core }"))
        XCTAssertTrue(source.contains("onDatagram: { [weak self]"))
        XCTAssertTrue(source.contains("self?.core?.handleDatagram("))
        XCTAssertFalse(source.contains("SessionCoreBox"))
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
