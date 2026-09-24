import Foundation
import LyteClientTestKit
import XCTest

final class ClientLayoutTests: XCTestCase {
    /// The source-layout grammar: every manifest target owns exactly
    /// `Sources/<Target>/`, every test target `Tests/<Target>Tests/`, and
    /// no directory exists that the manifest does not declare.
    func testClientPackageKeepsTheDeclaredTargetGrammar() throws {
        let root = URL(fileURLWithPath: ClientTestPaths.repositoryRoot)
            .appendingPathComponent("Client")
        let manifest = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8)
        let declaration = try NSRegularExpression(
            pattern: #"\.(target|executableTarget|testTarget)\(\s*name:\s*"([^"]+)""#)
        var sourceTargets: [String] = []
        var testTargets: [String] = []
        for match in declaration.matches(
            in: manifest, range: NSRange(manifest.startIndex..., in: manifest)
        ) {
            let kind = String(manifest[Range(match.range(at: 1), in: manifest)!])
            let name = String(manifest[Range(match.range(at: 2), in: manifest)!])
            if kind == "testTarget" {
                testTargets.append(name)
            } else {
                sourceTargets.append(name)
            }
        }
        XCTAssertFalse(sourceTargets.isEmpty)
        XCTAssertEqual(
            try directoryNames(at: root.appendingPathComponent("Sources")),
            sourceTargets.sorted())
        XCTAssertEqual(
            try directoryNames(at: root.appendingPathComponent("Tests")),
            testTargets.sorted())
        for name in testTargets {
            XCTAssertTrue(name.hasSuffix("Tests"), name)
        }
        for name in sourceTargets where name.hasSuffix("Tests") {
            XCTFail("\(name): reusable test equipment is a <Domain>TestKit")
        }
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
        // Components below Sources/, compared on symlink-resolved paths:
        // a checkout under /tmp enumerates as /private/tmp.
        let root = sources.resolvingSymlinksInPath().pathComponents
        func relative(_ file: URL) -> String {
            let parts = file.resolvingSymlinksInPath().pathComponents
            guard parts.starts(with: root) else { return file.path }
            return parts.dropFirst(root.count).joined(separator: "/")
        }
        for (token, owner) in owners.sorted(by: { $0.key < $1.key }) {
            let holders = files
                .filter { $0.1.contains(token) }
                .map { relative($0.0) }
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
