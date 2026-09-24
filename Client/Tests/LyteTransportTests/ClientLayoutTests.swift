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
                "Lyte", "LyteClientCore", "LyteClientSession",
                "LyteClientTestKit", "LyteCorpus", "LyteHelperProtocol",
                "LyteHelperSecurity", "LyteTransport", "LyteUI", "lyte-cli",
                "lyte-helperd",
            ]
        )
        XCTAssertEqual(
            try directoryNames(at: root.appendingPathComponent("Tests")),
            [
                "LyteClientCoreTests", "LyteClientSessionTests",
                "LyteHelperSecurityTests", "LyteTransportTests",
                "LyteUITests",
            ]
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

    func testShippingClientHasNoPlaintextTransportMode() throws {
        let root = URL(fileURLWithPath: ClientTestPaths.repositoryRoot)
            .appendingPathComponent("Client/Sources")
        for target in ["Lyte", "LyteTransport", "lyte-cli"] {
            let targetRoot = root.appendingPathComponent(target)
            for file in try swiftFiles(beneath: targetRoot) {
                let source = try String(contentsOf: file, encoding: .utf8)
                XCTAssertFalse(
                    source.contains("--insecure"),
                    "shipping plaintext option returned in \(file.path)"
                )
                XCTAssertFalse(
                    source.contains("PassthroughTransportCrypto"),
                    "test transport entered shipping target \(file.path)"
                )
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root
            .appendingPathComponent("lyte-cli/WireSendCommand.swift").path))
    }

    /// Single-owner ratchet: each wire decoder or policy engine is
    /// reached from exactly one IO-free session file. The transport shell
    /// executes decisions; it never decodes control words or runs the
    /// negotiation, lifecycle or clipboard machines itself.
    func testEachControlConceptHasOneSessionOwner() throws {
        let owners: [String: String] = [
            "ModeTransition.decode": "ClientSessionLifecycle.swift",
            "SessionTeardown.decode": "ClientSessionLifecycle.swift",
            "SessionStateMachine<": "ClientSessionLifecycle.swift",
            "CapabilityNegotiator": "ClientCapabilitySession.swift",
            "AudioRoutingStatus.decode": "ClientAudioRoutingSession.swift",
            "ClipboardAnnounce.decode": "ClientClipboardSession.swift",
            "ClipboardSyncBook": "ClientClipboardSession.swift",
            "ClipboardImageChannel(": "ClientClipboardSession.swift",
            "CursorShape.decode": "ClientCursorSession.swift",
            "AudioTrackState.decode": "ClientMediaPostureSession.swift",
            "VideoPostureState.decode": "ClientMediaPostureSession.swift",
        ]
        let sources = URL(fileURLWithPath: ClientTestPaths.repositoryRoot)
            .appendingPathComponent("Client/Sources")
        let files = try swiftFiles(beneath: sources).map {
            ($0, try String(contentsOf: $0, encoding: .utf8))
        }
        for (token, owner) in owners.sorted(by: { $0.key < $1.key }) {
            let holders = files
                .filter { $0.1.contains(token) }
                .map { $0.0.path.replacingOccurrences(
                    of: sources.path + "/", with: "") }
            XCTAssertEqual(holders, ["LyteClientSession/\(owner)"],
                           "\(token) must live only in \(owner)")
        }
    }

    /// The stats overlay samples once per second outside SwiftUI layout;
    /// re-deriving rows inside `body` (or a TimelineView) runs the whole
    /// stats walk on every layout pass.
    func testStatsOverlayNeverSamplesInsideLayout() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: ClientTestPaths.repositoryRoot +
                "/Client/Sources/Lyte/ControlStrip.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("TimelineView"))
        XCTAssertFalse(source.contains("ForEach(model.statsRows())"))
    }

    func testConductorOwnsCushionWithoutAUserSetting() throws {
        let root = URL(fileURLWithPath: ClientTestPaths.repositoryRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root
            .appendingPathComponent("Client/Sources/Lyte/LyteSettings.swift")
            .path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root
            .appendingPathComponent(
                "Client/Sources/LyteTransport/PlayoutCushionPreference.swift")
            .path))

        let app = try String(
            contentsOf: root.appendingPathComponent(
                "Client/Sources/Lyte/LyteApp.swift"),
            encoding: .utf8)
        let model = try String(
            contentsOf: root.appendingPathComponent(
                "Client/Sources/Lyte/ConnectionModel.swift"),
            encoding: .utf8)
        XCTAssertFalse(app.contains("Settings {"))
        XCTAssertFalse(model.contains("playoutCushion"))
        XCTAssertFalse(model.contains("PlayoutCushionPreference"))
    }

    func testHelperListenerAuthenticatesBeforeAcceptingClients() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: ClientTestPaths.repositoryRoot +
                "/Client/Sources/lyte-helperd/main.swift"),
            encoding: .utf8)
        let requirement = try XCTUnwrap(source.range(
            of: "listener.setConnectionCodeSigningRequirement(requirement)"))
        let delegate = try XCTUnwrap(source.range(
            of: "listener.delegate = delegate"))

        XCTAssertLessThan(
            source.distance(from: source.startIndex, to: requirement.lowerBound),
            source.distance(from: source.startIndex, to: delegate.lowerBound))
        XCTAssertTrue(source.contains(
            "let requirement = try HelperClientRequirement.forCurrentProcess()"))
        XCTAssertTrue(source.contains("exit(EX_CONFIG)"))
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

    private func swiftFiles(beneath root: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return try enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension == "swift",
                  try url.resourceValues(forKeys: Set(keys)).isRegularFile == true
            else { return nil }
            return url
        }
    }
}
