import Foundation
import LyteTestKit
import XCTest

final class SystemTestsLayoutTests: XCTestCase {
    private let sourceTree = RepositorySourceTree()

    private enum ProductRole {
        case client
        case host
    }

    func testCrossEndImportsLiveAtTheSystemBoundary() throws {
        XCTAssertEqual(
            try importers(
                of: .host,
                below: "SystemTests/Tests"
            ),
            [
                "SystemTests/Tests/LyteClientHostTests/NackRepairClientGateTests.swift",
                "SystemTests/Tests/LyteClientHostTests/PairingGateTests.swift",
                "SystemTests/Tests/LyteClientHostTests/SystemHostSession.swift",
            ]
        )
        XCTAssertEqual(
            try importers(
                of: .client,
                below: "SystemTests/Tests"
            ),
            [
                "SystemTests/Tests/LyteClientHostTests/NackRepairClientGateTests.swift",
                "SystemTests/Tests/LyteClientHostTests/PairingGateTests.swift",
                "SystemTests/Tests/LyteClientHostTests/SystemHostSession.swift",
            ]
        )
        XCTAssertEqual(
            try importers(
                of: .host,
                below: "Client/Tests"
            ),
            []
        )
        XCTAssertEqual(
            try importers(
                of: .client,
                below: "Host/Tests"
            ),
            []
        )

        let pairing = try source(
            at: "SystemTests/Tests/LyteClientHostTests/PairingGateTests.swift"
        )
        let pairingImports = SwiftSourceScanner.importedModules(in: pairing)
        XCTAssertTrue(pairingImports.contains("HostWire"))
        XCTAssertTrue(pairingImports.contains("LyteTransport"))

        let nack = try source(
            at: "SystemTests/Tests/LyteClientHostTests/NackRepairClientGateTests.swift"
        )
        let nackImports = SwiftSourceScanner.importedModules(in: nack)
        XCTAssertTrue(nackImports.contains("HostWire"))
        XCTAssertTrue(nackImports.contains("LyteTransport"))
        XCTAssertEqual(
            try sessionBoundaryViolations(
                in: swiftSources(below: "SystemTests/Tests")
            ),
            []
        )
    }

    func testAttributedAndQualifiedImportsCannotEvadeTheBoundary() {
        let source = [
            "@testable " + "import HostWire",
            "package " + "import HostWire",
            "@preconcurrency public " + "import LyteClientShell",
            "import " + "struct HostCore.Pacer",
            "import " + "let LyteClientShell.defaultValue",
        ].joined(separator: "\n")
        XCTAssertEqual(
            SwiftSourceScanner.importedModules(in: source),
            ["HostWire", "HostWire", "LyteClientShell", "HostCore", "LyteClientShell"]
        )
    }

    func testSessionBoundaryScannerRejectsDeadTokensAndRelocatedFakes() {
        let nackPath =
            "SystemTests/Tests/LyteClientHostTests/NackRepairClientGateTests.swift"
        let pairingPath =
            "SystemTests/Tests/LyteClientHostTests/PairingGateTests.swift"
        let hostPath =
            "SystemTests/Tests/LyteClientHostTests/SystemHostSession.swift"
        let deadTokens = [
            hostPath: "// session = Session( session.receive(",
            nackPath: """
            // SystemHostSession( NoiseTransportCrypto(
            let decoy = "NoiseTransportCrypto("
            """,
            pairingPath: "// SystemHostSession( PairingResponderService(",
        ]
        let deadViolations = sessionBoundaryViolations(in: deadTokens)
        XCTAssertTrue(deadViolations.contains {
            $0.contains("missing real Session construction")
        })
        XCTAssertTrue(deadViolations.contains {
            $0.contains("missing Session.receive ingress")
        })
        XCTAssertTrue(deadViolations.contains {
            $0.contains("missing real client Noise transport")
        })
        XCTAssertTrue(deadViolations.contains {
            $0.contains("pairing missing shared real Session host")
        })
        for label in [
            "pairing missing handshake binding",
            "pairing missing reliable CTRL dispatch",
            "pairing missing responder-service dispatch",
            "pairing missing Session reply carriage",
        ] {
            XCTAssertTrue(deadViolations.contains { $0.contains(label) })
        }

        let relocatedFake = [
            hostPath: """
            final class SystemHostSession {
                lazy var session = Session(config: config)
                func absorb() { session.receive(bytes) }
            }
            """,
            nackPath: """
            let host = SystemHostSession()
            let crypto = NoiseTransportCrypto(hostAddress: "")
            """,
            pairingPath: """
            let host = SystemHostSession()
            let crypto = NoiseTransportCrypto(hostAddress: "")
            let service = PairingResponderService(pin: [])
            let channel = HostWire.VideoChannel /* whitespace evasion */ (
                config: config
            )
            channel.enqueueRepair (frame: frame, shardIndices: [])
            let report = FeedbackReport . decode (bytes)
            let refusal = RepairRefusal /* moved fake */ (frame: frame)
            var noise = NoiseSession(role: .responder)
            var arq = ArqEndpoint (channel: .ctrl)
            let id = ConnectionId . random (using: &rng)
            var transport: NoiseTransport?
            let sealed = try transport . seal (plaintext)
            let envelope = Envelope (channel: .ctrl)
            let beacon = ClockBeacon (beaconSeq: 0)
            var ctrlSeq = 0
            final class HostStandIn {}
            """,
        ]
        let relocatedViolations = sessionBoundaryViolations(in: relocatedFake)
        for label in [
            "direct VideoChannel construction",
            "direct enqueueRepair",
            "manual FeedbackReport decode",
            "manual RepairRefusal construction",
            "rebuilt Noise responder",
            "direct Noise transport",
            "direct ArqEndpoint construction",
            "manual connection-id mint",
            "manual transport seal",
            "manual Envelope construction",
            "manual beacon construction",
            "manual CTRL sequence",
            "legacy host stand-in",
        ] {
            XCTAssertTrue(relocatedViolations.contains { $0.contains(label) })
        }

        let multilineSource = [
            "let prose = " + String(repeating: "\"", count: 3),
            "an unmatched ordinary quote: \"",
            String(repeating: "\"", count: 3),
            "let decoy = #\"enqueueRepair(\"#",
            "let channel = VideoChannel(config: config)",
        ].joined(separator: "\n")
        var multilineSources = relocatedFake
        multilineSources[pairingPath] = multilineSource
        let multilineViolations = sessionBoundaryViolations(
            in: multilineSources
        )
        XCTAssertTrue(multilineViolations.contains {
            $0.contains("direct VideoChannel construction")
        })
    }

    func testSystemPackageHasExactlyOneCanonicalTestBoundary() throws {
        let root = sourceTree.repositoryRoot
        let systemRoot = root.appendingPathComponent("SystemTests")

        XCTAssertEqual(
            try childNames(of: systemRoot),
            ["Package.resolved", "Package.swift", "Tests"]
        )
        XCTAssertEqual(
            try directoryPaths(below: systemRoot),
            ["Tests", "Tests/LyteClientHostTests"],
            "new SystemTests directories need an explicit architectural home"
        )

        for package in ["Client", "Common", "Host", "Wire"] {
            let manifest = try source(at: "\(package)/Package.swift")
            XCTAssertFalse(
                manifest.contains("../SystemTests"),
                "\(package) must not depend on the system-test package"
            )
            XCTAssertFalse(
                manifest.contains("LyteSystemTestKit"),
                "LyteSystemTestKit does not exist until reusable equipment earns it"
            )
        }

        let clientManifest = try source(at: "Client/Package.swift")
        XCTAssertFalse(
            clientManifest.contains("../Host"),
            "Client must not depend on the Host package"
        )
        XCTAssertFalse(
            clientManifest.contains("package: \"Host\""),
            "Client targets must not import Host products"
        )
        XCTAssertEqual(
            clientManifest.components(separatedBy: "\"LyteClientTestKit\"").count - 1,
            4,
            "the TestKit product/target may be consumed only by LyteTransportTests"
        )
        XCTAssertEqual(
            try importers(
                ofModule: "LyteClientTestKit",
                below: "Client/Sources"
            ),
            [],
            "shipping Client sources must not import test equipment"
        )
    }

    func testArqCarrierPackingLivesOnlyInWire() throws {
        for path in [
            "Client/Sources/LyteTransport/ReliableCtrlEndpoint.swift",
            "Host/Sources/HostWire/Session.swift",
        ] {
            let tokens = SwiftSourceScanner.tokens(in: try source(at: path))
            XCTAssertTrue(
                SwiftSourceScanner.contains(
                    ["maxDatagramPayloadByteCount", "="],
                    in: tokens
                ),
                "\(path) must inject its carrier ceiling into LyteWire"
            )
            XCTAssertTrue(
                tokens.contains("maxConnectionIdTaggedPlaintextByteCount"),
                "\(path) must consume the one connection-id budget"
            )
            XCTAssertFalse(
                SwiftSourceScanner.contains(
                    ["ArqFrame", ".", "decodeAll", "("], in: tokens
                ),
                "\(path) must not decode and re-cut LyteWire output"
            )
            XCTAssertFalse(
                tokens.contains { $0.lowercased().contains("repack") },
                "\(path) must not grow another downstream ARQ packer"
            )
        }
    }

    private func importers(
        of role: ProductRole,
        below relativeRoot: String
    ) throws -> [String] {
        try importers(below: relativeRoot) {
            belongsToRole($0, role: role)
        }
    }

    private func importers(
        ofModule module: String,
        below relativeRoot: String
    ) throws -> [String] {
        try importers(below: relativeRoot) { $0 == module }
    }

    private func importers(
        below relativeRoot: String,
        matching predicate: (String) -> Bool
    ) throws -> [String] {
        let root = sourceTree.repositoryRoot.appendingPathComponent(relativeRoot)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            XCTFail("cannot enumerate \(relativeRoot)")
            return []
        }

        var result: [String] = []
        for case let file as URL in enumerator
        where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            if SwiftSourceScanner.importedModules(in: source)
                .contains(where: predicate) {
                result.append(sourceTree.relativePath(for: file))
            }
        }
        return result.sorted()
    }

    private func swiftSources(
        below relativeRoot: String
    ) throws -> [String: String] {
        let root = sourceTree.repositoryRoot.appendingPathComponent(relativeRoot)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            throw NSError(domain: "SystemTestsLayoutTests", code: 1)
        }
        var result: [String: String] = [:]
        for case let file as URL in enumerator
        where file.pathExtension == "swift" {
            result[sourceTree.relativePath(for: file)] = try String(
                contentsOf: file,
                encoding: .utf8
            )
        }
        return result
    }

    private func sessionBoundaryViolations(
        in sources: [String: String]
    ) -> [String] {
        let nackPath =
            "SystemTests/Tests/LyteClientHostTests/NackRepairClientGateTests.swift"
        let pairingPath =
            "SystemTests/Tests/LyteClientHostTests/PairingGateTests.swift"
        let hostPath =
            "SystemTests/Tests/LyteClientHostTests/SystemHostSession.swift"
        let forbidden: [(label: String, tokens: [String])] = [
            ("direct VideoChannel construction", ["VideoChannel", "("]),
            ("direct enqueueRepair", ["enqueueRepair", "("]),
            ("manual FeedbackReport decode", ["FeedbackReport", ".", "decode", "("]),
            ("manual RepairRefusal construction", ["RepairRefusal", "("]),
            ("rebuilt Noise responder", ["NoiseSession"]),
            ("direct Noise transport", ["NoiseTransport"]),
            ("direct ArqEndpoint construction", ["ArqEndpoint"]),
            ("manual connection-id mint", ["ConnectionId", ".", "random", "("]),
            ("manual transport seal", ["seal", "("]),
            ("manual Envelope construction", ["Envelope", "("]),
            ("manual beacon construction", ["ClockBeacon", "("]),
            ("manual CTRL sequence", ["ctrlSeq"]),
            ("legacy host stand-in", ["HostStandIn"]),
        ]
        var violations: [String] = []
        for (path, source) in sources {
            let tokens = SwiftSourceScanner.tokens(in: source)
            for rule in forbidden where SwiftSourceScanner.contains(
                rule.tokens,
                in: tokens
            ) {
                violations.append("\(path): \(rule.label)")
            }
        }

        let required: [(path: String, label: String, tokens: [String])] = [
            (hostPath, "missing real Session construction",
             ["session", "=", "Session", "("]),
            (hostPath, "missing Session.receive ingress",
             ["session", ".", "receive", "("]),
            (nackPath, "repair missing shared real Session host",
             ["SystemHostSession", "("]),
            (nackPath, "missing real client Noise transport",
             ["NoiseTransportCrypto", "("]),
            (pairingPath, "pairing missing shared real Session host",
             ["SystemHostSession", "("]),
            (pairingPath, "pairing missing real client Noise transport",
             ["NoiseTransportCrypto", "("]),
            (pairingPath, "pairing missing real responder service",
             ["PairingResponderService", "("]),
            (pairingPath, "pairing missing handshake binding",
             ["handshakeCompleted", "("]),
            (pairingPath, "pairing missing reliable CTRL dispatch",
             ["reliableCtrl", "("]),
            (pairingPath, "pairing missing responder-service dispatch",
             ["hostService", ".", "handleReliableCtrl", "("]),
            (pairingPath, "pairing missing Session reply carriage",
             ["host", ".", "session", ".", "sendReliable", "("]),
        ]
        for rule in required {
            let tokens = sources[rule.path].map {
                SwiftSourceScanner.tokens(in: $0)
            } ?? []
            if !SwiftSourceScanner.contains(rule.tokens, in: tokens) {
                violations.append("\(rule.path): \(rule.label)")
            }
        }
        return violations.sorted()
    }

    private func belongsToRole(_ module: String, role: ProductRole) -> Bool {
        switch role {
        case .host:
            return ["HostCore", "HostEye", "HostWire"].contains(module)
                || module.hasPrefix("LyteHost")
        case .client:
            return ["LyteCorpus", "LyteHelperProtocol", "LyteTransport", "LyteUI"]
                .contains(module)
                || module.hasPrefix("LyteClient")
        }
    }

    private func source(at relativePath: String) throws -> String {
        try String(
            contentsOf: sourceTree.repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func childNames(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent).sorted()
    }

    private func directoryPaths(below root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("cannot enumerate \(root.path)")
            return []
        }

        var result: [String] = []
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                let relative = item.path.dropFirst(root.path.count + 1)
                result.append(String(relative))
            }
        }
        return result.sorted()
    }
}
