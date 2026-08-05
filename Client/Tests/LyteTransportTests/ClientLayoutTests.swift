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

    func testTransportUsesOneComposedClientControlSession() throws {
        let root = URL(fileURLWithPath: ClientTestPaths.repositoryRoot)
        let transport = try String(
            contentsOf: root.appendingPathComponent(
                "Client/Sources/LyteTransport/LyteUdpSession.swift"),
            encoding: .utf8)
        let lifecycle = try String(
            contentsOf: root.appendingPathComponent(
                "Client/Sources/LyteClientSession/"
                    + "ClientSessionLifecycle.swift"),
            encoding: .utf8)
        let control = try String(
            contentsOf: root.appendingPathComponent(
                "Client/Sources/LyteClientSession/ClientControlSession.swift"),
            encoding: .utf8)

        XCTAssertTrue(transport.contains(
            "private var controlSession: ClientControlSession"))
        XCTAssertTrue(transport.contains(
            "let decision = controlSession.advance(input, now: now)"))
        XCTAssertTrue(transport.contains(
            "decision = try controlSession.receiveReliable(bytes, now: now)"))
        XCTAssertFalse(transport.contains(
            "private var lifecycle: ClientSessionLifecycle"))
        XCTAssertFalse(transport.contains(
            "private var capabilitySession: ClientCapabilitySession"))
        XCTAssertFalse(transport.contains("ModeTransition.decode"))
        XCTAssertFalse(transport.contains("SessionTeardown.decode"))
        XCTAssertFalse(transport.contains("SessionStateMachine<"))
        XCTAssertFalse(transport.contains("private var lastState"))
        XCTAssertFalse(transport.contains("private var lastWireMode"))
        XCTAssertTrue(lifecycle.contains(
            "private var machine: SessionStateMachine<ClientClock>"))
        XCTAssertTrue(lifecycle.contains("ModeTransition.decode"))
        XCTAssertTrue(lifecycle.contains("SessionTeardown.decode"))
        XCTAssertTrue(control.contains(
            "private var lifecycle: ClientSessionLifecycle"))
        XCTAssertTrue(control.contains(
            "private var capabilities: ClientCapabilitySession"))
    }

    func testClientCapabilitySessionAloneOwnsTheAgreedSet() throws {
        let root = URL(fileURLWithPath: ClientTestPaths.repositoryRoot)
        let transport = try String(
            contentsOf: root.appendingPathComponent(
                "Client/Sources/LyteTransport/LyteUdpSession.swift"),
            encoding: .utf8)
        let capabilities = try String(
            contentsOf: root.appendingPathComponent(
                "Client/Sources/LyteClientSession/"
                    + "ClientCapabilitySession.swift"),
            encoding: .utf8)

        XCTAssertFalse(transport.contains("CapabilityNegotiator"))
        XCTAssertFalse(transport.contains("private var agreed:"))
        XCTAssertTrue(transport.contains(
            "return controlSession.agreedCapabilities"))
        XCTAssertTrue(capabilities.contains(
            "private var negotiator: CapabilityNegotiator"))
        XCTAssertTrue(capabilities.contains(
            "public var agreed: Capabilities? { negotiator.agreed }"))
    }

    func testConfirmedAudioPostureAloneOwnsTheFirstStatusSeam() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: ClientTestPaths.repositoryRoot +
                "/Client/Sources/LyteTransport/LyteUdpSession.swift"),
            encoding: .utf8)

        XCTAssertFalse(source.contains("sessionStartAudioAskDone"))
        XCTAssertTrue(source.contains(
            "let firstStatus = hostAudioPosture == nil"))
    }

    func testObservedChromaAloneOwnsTheAuditReportEdge() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: ClientTestPaths.repositoryRoot +
                "/Client/Sources/LyteTransport/ChromaTier.swift"),
            encoding: .utf8)

        XCTAssertFalse(source.contains("private var reported"))
        XCTAssertTrue(source.contains(
            "guard observedIdc != idc else { return nil }"))
    }

    func testPakeResultAloneOwnsThePairedHostKey() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: ClientTestPaths.repositoryRoot +
                "/Client/Sources/LyteTransport/PairingInitiatorService.swift"),
            encoding: .utf8)

        XCTAssertFalse(source.contains("private var pairedKey"))
        XCTAssertTrue(source.contains(
            "return pake.result?.peerStaticPublicKeyToPin"))
        XCTAssertFalse(source.contains("pairedKey ="))
    }

    func testPairingPhaseAloneOwnsTheCompletionAnswer() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: ClientTestPaths.repositoryRoot +
                "/Client/Sources/Lyte/LytePairingSheet.swift"),
            encoding: .utf8)

        XCTAssertFalse(source.contains("@State private var paired"))
        XCTAssertFalse(source.contains("paired = true"))
        XCTAssertEqual(
            source.components(separatedBy: "onDone(false)").count - 1,
            2)
        XCTAssertEqual(
            source.components(separatedBy: "onDone(true)").count - 1,
            1)
    }

    func testStatsOverlaySamplesOutsideSwiftUILayout() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: ClientTestPaths.repositoryRoot +
                "/Client/Sources/Lyte/ControlStrip.swift"),
            encoding: .utf8)
        let marker = "struct StatsOverlay: View {"
        let overlay = try XCTUnwrap(source.range(of: marker)).lowerBound
        let overlaySource = source[overlay...]

        XCTAssertTrue(overlaySource.contains(
            "@State private var rows: [ConnectionModel.StatsRow] = []"))
        XCTAssertTrue(overlaySource.contains("ForEach(rows)"))
        XCTAssertTrue(overlaySource.contains("rows = model.statsRows()"))
        XCTAssertTrue(overlaySource.contains(
            "try await Task.sleep(for: .seconds(1))"))
        XCTAssertFalse(overlaySource.contains("TimelineView"))
        XCTAssertFalse(overlaySource.contains("ForEach(model.statsRows())"))
    }

    func testGlassTelemetryUsesTwoStableSemanticRows() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: ClientTestPaths.repositoryRoot +
                "/Client/Sources/Lyte/ConnectionModel.swift"),
            encoding: .utf8)
        let glass = try XCTUnwrap(source.range(of: "row(\"glass\", glass)"))
        let playout = try XCTUnwrap(source.range(
            of: "row(\"playout\", playout.joined(separator: \" · \"))"))

        XCTAssertLessThan(glass.lowerBound, playout.lowerBound)
        XCTAssertTrue(source.contains(
            "playout.append(\"render \\(renderer.totalFrames)\")"))
        XCTAssertTrue(source.contains("playout.append(flight.bottleneck)"))
        XCTAssertFalse(source.contains("glass +="))
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
