import Foundation
import LyteTestKit
import XCTest

/// The single-owner ratchets: each shared concept has one implementation.
/// Rules match SwiftSourceScanner tokens — comments and strings removed,
/// whole identifiers compared, numeric literals by value spelling — so a
/// doc comment naming a type, or a longer name that starts with one,
/// never trips a rule, and owners are found by what they declare rather
/// than by file path.
final class SingleOwnerTests: XCTestCase {
    private struct Source {
        let path: String
        let tokens: [String]
        /// Types declared at brace depth 0.
        let topLevelTypes: Set<String>
        /// Types declared at any depth.
        let types: [String]
    }

    private enum Owner {
        /// Files that declare this type at top level.
        case declarer(of: String)
        /// Files below this repository path.
        case directory(String)
        /// No production file.
        case nowhere
    }

    private struct ConfinedUse {
        let tokens: [String]
        let owner: Owner
        /// Repository path prefix the rule applies to; nil = every
        /// production root.
        var scope: String?
    }

    /// Every top-level type an owner target declares is declared nowhere
    /// else in scope: shared vocabulary is extracted once, never twinned.
    private let ownedVocabularies: [(owner: String, scope: String?)] = [
        ("Common/Sources/LyteCore/", nil),
        ("Common/Sources/LyteIO/", nil),
        ("Host/Sources/HostSession/", "Host/Sources/"),
    ]

    /// The named media and session seams: declared exactly once, inside
    /// their owner.
    private let seams: [(name: String, owner: String)] = [
        ("ScreenSource", "Host/Sources/HostEye/"),
        ("DirectScreenSource", "Host/Sources/HostEye/"),
        ("VideoSink", "Client/Sources/LyteTransport/"),
        ("SessionVideoSink", "Client/Sources/LyteTransport/"),
        ("LyteUdpSessionCore", "Client/Sources/LyteTransport/"),
    ]

    private let confinedUses: [ConfinedUse] = [
        // One monotonic clock end to end.
        ConfinedUse(tokens: ["DispatchTime", ".", "now"],
                    owner: .declarer(of: "SystemMonotonicClock")),
        ConfinedUse(tokens: ["clock_gettime", "(", "CLOCK_MONOTONIC"],
                    owner: .declarer(of: "SystemMonotonicClock")),
        ConfinedUse(tokens: ["ContinuousClock", ".", "now"],
                    owner: .declarer(of: "SystemMonotonicClock")),
        // One SHA-256: LyteCore's, and swift-crypto's behind Wire's Noise.
        ConfinedUse(tokens: ["0x428A_2F98"], owner: .declarer(of: "Sha256")),
        ConfinedUse(tokens: ["SHA256", ".", "hash"],
                    owner: .directory("Wire/Sources/LyteWire/Crypto/")),
        // One eye pipeline builds the GL context and the encoder, and
        // only the ScreenSource organ grabs scanout.
        ConfinedUse(tokens: ["EyeGL", "("],
                    owner: .declarer(of: "EyePipeline"),
                    scope: "Host/Sources/"),
        ConfinedUse(tokens: ["EyeVaapiEncoder", "("],
                    owner: .declarer(of: "EyePipeline"),
                    scope: "Host/Sources/"),
        ConfinedUse(tokens: ["grabTicket", "("],
                    owner: .directory("Host/Sources/HostEye/"),
                    scope: "Host/Sources/"),
        // The host's lifecycle machine belongs to SessionLifecycleLane.
        ConfinedUse(tokens: ["SessionStateMachine"],
                    owner: .directory("Host/Sources/HostSession/"),
                    scope: "Host/Sources/"),
        // Encryption is always on: no production shell selects the
        // session's plaintext test mode.
        ConfinedUse(tokens: ["testPassthrough"],
                    owner: .directory("Host/Sources/HostWire/")),
        // Decoded samples leave the session only through VideoSink.
        ConfinedUse(tokens: ["(", "CMSampleBuffer", "DecodeUnit", ")"],
                    owner: .nowhere),
    ]

    /// Files declaring these types never name these tokens: the session
    /// core stays free of native media types, and the video policies
    /// receive time instead of reading the shell clock.
    private let excludedUses: [(declarer: String, tokens: [String])] = [
        ("LyteUdpSessionCore", ["CoreMedia"]),
        ("LyteUdpSessionCore", ["CMSampleBuffer"]),
        ("LyteVideoPipeline", ["SystemMonotonicClock"]),
        ("VideoFlightRecorder", ["SystemMonotonicClock"]),
    ]

    /// ARQ carrier packing lives only in Wire: its segment, ack and frame
    /// codecs are Wire's, and no role decodes and re-cuts what Wire's
    /// endpoint packed (a second, downstream packer).
    private let arqCodecTypes = ["ArqFrame", "ArqSegment", "ArqAck"]

    func testArqCarrierPackingLivesOnlyInWire() throws {
        let sources = try productionSources()
        let rules = arqCodecTypes.map {
            ConfinedUse(tokens: [$0], owner: .directory("Wire/Sources/"))
        }
        XCTAssertEqual(
            Self.confinedUseViolations(rules, in: sources), [],
            "ARQ frames were packed or re-cut outside Wire")
        let wireTypes = Set(sources
            .filter { $0.path.hasPrefix("Wire/Sources/") }
            .flatMap(\.topLevelTypes))
        XCTAssertEqual(arqCodecTypes.filter { !wireTypes.contains($0) }, [],
                       "a renamed codec would pass this rule vacuously")
    }

    /// Only the Browser package's test targets depend on Host products:
    /// the browser client meets the host role in its tests alone. Read from
    /// the evaluated manifest's target graph, not the manifest's text.
    func testOnlyBrowserTestTargetsDependOnHost() throws {
        let root = RepositorySourceTree().repositoryRoot
        let host = try Self.dumpPackage(root.appendingPathComponent("Host"))
        let browser = try Self.dumpPackage(
            root.appendingPathComponent("Browser"))
        let hostProducts = Set(host.products.map(\.name))
        XCTAssertFalse(hostProducts.isEmpty)

        let dependents = browser.targets.filter { target in
            target.dependencies.contains {
                $0.dependsOnPackage("host", products: hostProducts)
            }
        }
        XCTAssertFalse(dependents.isEmpty,
                       "the browser tests drive a real host session")
        XCTAssertEqual(
            dependents.filter { $0.type != "test" }.map(\.name), [],
            "a shipping Browser target depends on Host")
    }

    func testDependsOnPackageReadsProductAndByNameEdges() throws {
        let json = Data(#"""
            {"name": "X", "products": [], "targets": [
              {"name": "A", "type": "regular", "dependencies": [
                {"product": ["HostWire", "Host", null, null]}]},
              {"name": "B", "type": "regular", "dependencies": [
                {"byName": ["HostSession", null]}]},
              {"name": "C", "type": "regular", "dependencies": [
                {"product": ["LyteWire", "Wire", null, null]},
                {"byName": ["C2", null]},
                {"target": ["HostWire", null]}]}]}
            """#.utf8)
        let manifest = try JSONDecoder().decode(DumpedPackage.self, from: json)
        let products: Set<String> = ["HostWire", "HostSession"]
        XCTAssertEqual(manifest.targets.filter { target in
            target.dependencies.contains {
                $0.dependsOnPackage("host", products: products)
            }
        }.map(\.name), ["A", "B"])
    }

    func testOwnedVocabulariesHaveNoTwins() throws {
        let sources = try productionSources()
        XCTAssertEqual(
            Self.vocabularyViolations(ownedVocabularies, in: sources), [],
            "a shared type was declared a second time")
    }

    func testSeamsAreDeclaredOnceByTheirOwners() throws {
        let sources = try productionSources()
        XCTAssertEqual(Self.seamViolations(seams, in: sources), [])
    }

    func testConfinedTokensAppearOnlyInTheirOwners() throws {
        let sources = try productionSources()
        XCTAssertEqual(
            Self.confinedUseViolations(confinedUses, in: sources), [],
            "a second implementation reached past its owner")
        XCTAssertEqual(
            Self.excludedUseViolations(excludedUses, in: sources), [])
    }

    /// Every declarer a rule names still exists, so no rule passes
    /// vacuously after a rename.
    func testEveryNamedOwnerIsDeclared() throws {
        let declared = Set(try productionSources().flatMap(\.topLevelTypes))
        var named: [String] = excludedUses.map(\.declarer)
        for rule in confinedUses {
            if case .declarer(let name) = rule.owner { named.append(name) }
        }
        XCTAssertEqual(named.filter { !declared.contains($0) }, [])
    }

    // MARK: The engine on fixtures

    func testVocabularyRuleMatchesWholeDeclarationsOnly() {
        let sources = [
            Self.source("Common/Sources/LyteCore/Histogram.swift", """
                /// struct Hex is described here, not declared.
                public struct Histogram<Value> { struct Bucket {} }
                """),
            Self.source("Client/Sources/A/View.swift", """
                // struct Histogram in a comment
                let text = "struct Histogram"
                struct HistogramView {}
                final class Bucket {}
                class func make() {}
                import struct LyteCore.Histogram
                """),
            Self.source("Host/Sources/B/Twin.swift", """
                enum Outer { final class Histogram {} }
                """),
        ]
        XCTAssertEqual(
            Self.vocabularyViolations(
                [("Common/Sources/LyteCore/", nil)], in: sources),
            ["Host/Sources/B/Twin.swift: Histogram"])
    }

    func testConfinedUseRulesHonorOwnersScopesAndLiterals() {
        let sources = [
            Self.source("Common/Sources/LyteCore/Sha256.swift", """
                public struct Sha256 { let k = [0x428A_2F98] }
                """),
            Self.source("Client/Sources/A/Hash.swift", """
                // 0x428A_2F98 in a comment is fine
                let k: UInt32 = 0x428a2f98
                """),
            Self.source("Client/Sources/A/Clock.swift", """
                let machine = SessionStateMachine()
                """),
            Self.source("Host/Sources/HostWire/Session.swift", """
                let machine = SessionStateMachine()
                """),
        ]
        let rules = [
            ConfinedUse(tokens: ["0x428A_2F98"], owner: .declarer(of: "Sha256")),
            ConfinedUse(tokens: ["SessionStateMachine"],
                        owner: .directory("Host/Sources/HostSession/"),
                        scope: "Host/Sources/"),
        ]
        XCTAssertEqual(Self.confinedUseViolations(rules, in: sources), [
            "Client/Sources/A/Hash.swift: 0x428A_2F98",
            "Host/Sources/HostWire/Session.swift: SessionStateMachine",
        ])
    }

    func testSeamRuleWantsExactlyOneDeclarationInTheOwner() {
        let sources = [
            Self.source("Client/Sources/LyteTransport/VideoSink.swift",
                        "public protocol VideoSink {}"),
            Self.source("Client/Sources/Other/Sink.swift",
                        "protocol VideoSink {}"),
        ]
        XCTAssertEqual(
            Self.seamViolations(
                [("VideoSink", "Client/Sources/LyteTransport/"),
                 ("ScreenSource", "Host/Sources/HostEye/")],
                in: sources),
            [
                "ScreenSource: declared in []",
                #"VideoSink: declared in ["Client/Sources/LyteTransport/VideoSink.swift", "Client/Sources/Other/Sink.swift"]"#,
            ])
    }

    // MARK: - Engine

    /// The fields of `swift package dump-package` the graph rule reads.
    fileprivate struct DumpedPackage: Decodable {
        struct Product: Decodable { let name: String }
        struct Target: Decodable {
            let name: String
            let type: String
            let dependencies: [Dependency]
        }
        /// One target dependency: `product` is [name, package, …],
        /// `byName` is [name, …], `target` is [name, …].
        struct Dependency: Decodable {
            let product: [String?]?
            let byName: [String?]?

            func dependsOnPackage(
                _ identity: String, products: Set<String>
            ) -> Bool {
                if let product, product.count > 1,
                   product[1]?.lowercased() == identity {
                    return true
                }
                if let name = byName?.first ?? nil {
                    return products.contains(name)
                }
                return false
            }
        }
        let products: [Product]
        let targets: [Target]
    }

    /// Evaluates `package`'s manifest with SwiftPM, in a private scratch
    /// path so no other build's lock is touched.
    fileprivate static func dumpPackage(_ package: URL) throws -> DumpedPackage {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyte-dump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift", "package", "--package-path", package.path,
            "--scratch-path", scratch.path, "dump-package",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DumpPackageFailed(
                package: package.lastPathComponent,
                status: process.terminationStatus)
        }
        return try JSONDecoder().decode(DumpedPackage.self, from: data)
    }

    private struct DumpPackageFailed: Error {
        let package: String
        let status: Int32
    }

    private func productionSources() throws -> [Source] {
        let tree = RepositorySourceTree()
        return try tree.productionSwiftFiles().map { file in
            Self.source(tree.relativePath(for: file), tokens: try tree.tokens(of: file))
        }
    }

    private static func source(_ path: String, _ text: String) -> Source {
        source(path, tokens: SwiftSourceScanner.tokens(in: text))
    }

    private static func source(_ path: String, tokens: [String]) -> Source {
        let declarations = SwiftSourceScanner.typeDeclarations(in: tokens)
        return Source(
            path: path,
            tokens: tokens.map(normalized),
            topLevelTypes: Set(declarations.filter { $0.depth == 0 }.map(\.name)),
            types: declarations.map(\.name))
    }

    /// Numeric literals compare by value spelling: case and digit
    /// separators do not matter.
    private static func normalized(_ token: String) -> String {
        guard token.first?.isNumber == true else { return token }
        return token.lowercased().replacingOccurrences(of: "_", with: "")
    }

    private static func inScope(_ source: Source, _ scope: String?) -> Bool {
        scope.map(source.path.hasPrefix) ?? true
    }

    private static func vocabularyViolations(
        _ vocabularies: [(owner: String, scope: String?)], in sources: [Source]
    ) -> [String] {
        var violations: [String] = []
        for (owner, scope) in vocabularies {
            let owned = Set(sources.filter { $0.path.hasPrefix(owner) }
                .flatMap(\.topLevelTypes))
            for source in sources
            where inScope(source, scope) && !source.path.hasPrefix(owner) {
                for name in source.types where owned.contains(name) {
                    violations.append("\(source.path): \(name)")
                }
            }
        }
        return violations.sorted()
    }

    private static func seamViolations(
        _ seams: [(name: String, owner: String)], in sources: [Source]
    ) -> [String] {
        seams.compactMap { seam in
            let declarers = sources.filter { $0.types.contains(seam.name) }
                .map(\.path).sorted()
            guard declarers.count == 1, declarers[0].hasPrefix(seam.owner)
            else { return "\(seam.name): declared in \(declarers)" }
            return nil
        }.sorted()
    }

    private static func confinedUseViolations(
        _ rules: [ConfinedUse], in sources: [Source]
    ) -> [String] {
        var violations: [String] = []
        for rule in rules {
            let needle = rule.tokens.map(normalized)
            for source in sources where inScope(source, rule.scope) {
                let allowed: Bool
                switch rule.owner {
                case .declarer(let name):
                    allowed = source.topLevelTypes.contains(name)
                case .directory(let path):
                    allowed = source.path.hasPrefix(path)
                case .nowhere:
                    allowed = false
                }
                if !allowed,
                   SwiftSourceScanner.contains(needle, in: source.tokens) {
                    violations.append(
                        "\(source.path): \(rule.tokens.joined())")
                }
            }
        }
        return violations.sorted()
    }

    private static func excludedUseViolations(
        _ rules: [(declarer: String, tokens: [String])], in sources: [Source]
    ) -> [String] {
        var violations: [String] = []
        for rule in rules {
            for source in sources
            where source.topLevelTypes.contains(rule.declarer)
                && SwiftSourceScanner.contains(rule.tokens, in: source.tokens) {
                violations.append(
                    "\(source.path): \(rule.declarer) names \(rule.tokens.joined())")
            }
        }
        return violations.sorted()
    }
}
