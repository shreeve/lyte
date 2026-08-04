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
        let pairingImports = importedModules(from: pairing)
        XCTAssertTrue(pairingImports.contains("HostWire"))
        XCTAssertTrue(pairingImports.contains("LyteTransport"))

        let nack = try source(
            at: "SystemTests/Tests/LyteClientHostTests/NackRepairClientGateTests.swift"
        )
        let nackImports = importedModules(from: nack)
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
            importedModules(from: source),
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
            if importedModules(from: source).contains(where: predicate) {
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
            let tokens = swiftTokens(from: source)
            for rule in forbidden where contains(rule.tokens, in: tokens) {
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
            let tokens = sources[rule.path].map(swiftTokens(from:)) ?? []
            if !contains(rule.tokens, in: tokens) {
                violations.append("\(rule.path): \(rule.label)")
            }
        }
        return violations.sorted()
    }

    private func contains(
        _ needle: [String],
        in tokens: [String]
    ) -> Bool {
        guard !needle.isEmpty, tokens.count >= needle.count else {
            return false
        }
        return (0...(tokens.count - needle.count)).contains { start in
            Array(tokens[start..<(start + needle.count)]) == needle
        }
    }

    /// Enough Swift lexical structure for architectural source scans:
    /// comments and string contents disappear, whitespace is irrelevant,
    /// and identifiers plus the punctuation used by call sites remain.
    private func swiftTokens(from source: String) -> [String] {
        let characters = Array(source)
        var tokens: [String] = []
        var identifier = ""
        var index = 0
        var blockDepth = 0
        var inLineComment = false
        var stringHashes: Int?
        var stringQuotes = 0

        func flush() {
            if !identifier.isEmpty {
                tokens.append(identifier)
                identifier.removeAll(keepingCapacity: true)
            }
        }

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count
                ? characters[index + 1] : "\0"

            if inLineComment {
                if character == "\n" { inLineComment = false }
                index += 1
                continue
            }
            if blockDepth > 0 {
                if character == "/", next == "*" {
                    blockDepth += 1
                    index += 2
                } else if character == "*", next == "/" {
                    blockDepth -= 1
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if let hashes = stringHashes {
                if hashes == 0, character == "\\" {
                    index = min(index + 2, characters.count)
                    continue
                }
                if delimiter(
                    quoteCount: stringQuotes,
                    hashCount: hashes,
                    matches: characters,
                    at: index
                ) {
                    index += stringQuotes + hashes
                    stringHashes = nil
                } else {
                    index += 1
                }
                continue
            }
            if character == "/", next == "/" {
                flush()
                inLineComment = true
                index += 2
                continue
            }
            if character == "/", next == "*" {
                flush()
                blockDepth = 1
                index += 2
                continue
            }
            var hashes = 0
            while index + hashes < characters.count,
                  characters[index + hashes] == "#" {
                hashes += 1
            }
            let quoteIndex = index + hashes
            if quoteIndex < characters.count,
               characters[quoteIndex] == "\"" {
                flush()
                stringHashes = hashes
                stringQuotes = delimiter(
                    quoteCount: 3,
                    hashCount: 0,
                    matches: characters,
                    at: quoteIndex
                ) ? 3 : 1
                index = quoteIndex + stringQuotes
                continue
            }
            if character.isLetter || character.isNumber || character == "_" {
                identifier.append(character)
            } else {
                flush()
                if [".", "(", "="].contains(character) {
                    tokens.append(String(character))
                }
            }
            index += 1
        }
        flush()
        return tokens
    }

    private func delimiter(
        quoteCount: Int,
        hashCount: Int,
        matches characters: [Character],
        at start: Int
    ) -> Bool {
        let delimiter = Array(repeating: Character("\""), count: quoteCount)
            + Array(repeating: Character("#"), count: hashCount)
        guard start + delimiter.count <= characters.count else { return false }
        return Array(characters[start..<(start + delimiter.count)]) == delimiter
    }

    private func importedModules(from source: String) -> [String] {
        let importAccess: Set<String> = [
            "fileprivate", "internal", "package", "private", "public",
        ]
        let importKinds: Set<String> = [
            "class", "enum", "func", "let", "macro", "protocol", "struct",
            "typealias", "var",
        ]

        return source.split(separator: "\n").compactMap { line in
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let importIndex = tokens.firstIndex(of: "import"),
                  tokens[..<importIndex].allSatisfy({
                      $0.hasPrefix("@") || importAccess.contains($0)
                  })
            else {
                return nil
            }

            var moduleIndex = importIndex + 1
            guard moduleIndex < tokens.endIndex else { return nil }
            if importKinds.contains(tokens[moduleIndex]) {
                moduleIndex += 1
            }
            guard moduleIndex < tokens.endIndex else { return nil }
            return String(tokens[moduleIndex].split(separator: ".", maxSplits: 1)[0])
        }
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
