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
            try repairBoundaryViolations(
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

    func testRepairBoundaryScannerRejectsDeadTokensAndRelocatedFakes() {
        let nackPath =
            "SystemTests/Tests/LyteClientHostTests/NackRepairClientGateTests.swift"
        let deadTokens = [
            nackPath: """
            // SessionRepairHost session = Session( session.receive(
            let decoy = "NoiseTransportCrypto("
            """,
        ]
        let deadViolations = repairBoundaryViolations(in: deadTokens)
        XCTAssertTrue(deadViolations.contains {
            $0.contains("missing real Session construction")
        })
        XCTAssertTrue(deadViolations.contains {
            $0.contains("missing Session.receive ingress")
        })
        XCTAssertTrue(deadViolations.contains {
            $0.contains("missing real client Noise transport")
        })

        let relocatedFake = [
            nackPath: """
            final class SessionRepairHost {
                lazy var session = Session(config: config)
                func absorb() { session.receive(bytes) }
            }
            let crypto = NoiseTransportCrypto(hostAddress: "")
            """,
            "SystemTests/Tests/LyteClientHostTests/PairingGateTests.swift": """
            let channel = HostWire.VideoChannel /* whitespace evasion */ (
                config: config
            )
            channel.enqueueRepair (frame: frame, shardIndices: [])
            let report = FeedbackReport . decode (bytes)
            let refusal = RepairRefusal /* moved fake */ (frame: frame)
            """,
        ]
        let relocatedViolations = repairBoundaryViolations(in: relocatedFake)
        XCTAssertTrue(relocatedViolations.contains {
            $0.contains("direct VideoChannel construction")
        })
        XCTAssertTrue(relocatedViolations.contains {
            $0.contains("direct enqueueRepair")
        })
        XCTAssertTrue(relocatedViolations.contains {
            $0.contains("manual FeedbackReport decode")
        })
        XCTAssertTrue(relocatedViolations.contains {
            $0.contains("manual RepairRefusal construction")
        })

        let multilineSource = [
            "let prose = " + String(repeating: "\"", count: 3),
            "an unmatched ordinary quote: \"",
            String(repeating: "\"", count: 3),
            "let decoy = #\"enqueueRepair(\"#",
            "let channel = VideoChannel(config: config)",
        ].joined(separator: "\n")
        let multilineViolations = repairBoundaryViolations(in: [
            nackPath: relocatedFake[nackPath]!,
            "SystemTests/Tests/LyteClientHostTests/PairingGateTests.swift":
                multilineSource,
        ])
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

    private func repairBoundaryViolations(
        in sources: [String: String]
    ) -> [String] {
        let nackPath =
            "SystemTests/Tests/LyteClientHostTests/NackRepairClientGateTests.swift"
        let forbidden: [(label: String, tokens: [String])] = [
            ("direct VideoChannel construction", ["VideoChannel", "("]),
            ("direct enqueueRepair", ["enqueueRepair", "("]),
            ("manual FeedbackReport decode", ["FeedbackReport", ".", "decode", "("]),
            ("manual RepairRefusal construction", ["RepairRefusal", "("]),
        ]
        var violations: [String] = []
        for (path, source) in sources {
            let tokens = swiftTokens(from: source)
            for rule in forbidden where contains(rule.tokens, in: tokens) {
                violations.append("\(path): \(rule.label)")
            }
            if path == nackPath, tokens.contains("NoiseSession") {
                violations.append("\(path): rebuilt Noise responder")
            }
        }

        let nackTokens = sources[nackPath].map(swiftTokens(from:)) ?? []
        let required: [(label: String, tokens: [String])] = [
            ("missing real Session construction", ["session", "=", "Session", "("]),
            ("missing Session.receive ingress", ["session", ".", "receive", "("]),
            ("missing real client Noise transport", ["NoiseTransportCrypto", "("]),
        ]
        for rule in required where !contains(rule.tokens, in: nackTokens) {
            violations.append("\(nackPath): \(rule.label)")
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
