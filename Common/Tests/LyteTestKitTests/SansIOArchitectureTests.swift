import Foundation
import LyteTestKit
import XCTest

/// The one enforcement point for the sans-IO law. Each registered pure
/// target may import only its declared inward leaves (an allowlist, so
/// Foundation, Dispatch, Network, Darwin, Glibc, CryptoKit and every other
/// OS module are refused by default), some leaves only below a narrower
/// path, and its tokens may name no IO, concurrency, synchronization, OS
/// clock or system randomness.
final class SansIOArchitectureTests: XCTestCase {
    private struct Boundary {
        let path: String
        let allowedImports: Set<String>
        /// Allowed modules that may appear only in files whose repository
        /// path starts with the given prefix (a directory or one file).
        var confinedImports: [String: String] = [:]
    }

    private let tree = RepositorySourceTree()

    /// This is the executable registry for every admitted pure role target.
    /// Adding a target here makes its source root mandatory and subjects every
    /// Swift file below it to the same import and side-effect vocabulary laws.
    private let boundaries = [
        Boundary(
            path: "Common/Sources/LyteCore",
            allowedImports: []
        ),
        Boundary(
            path: "Client/Sources/LyteClientCore",
            allowedImports: ["LyteCore", "LyteWire"]
        ),
        Boundary(
            path: "Client/Sources/LyteClientSession",
            allowedImports: ["LyteCore", "LyteWire"]
        ),
        Boundary(
            path: "Wire/Sources/LyteWire",
            allowedImports: ["CNanorsWire", "Crypto", "LyteCore"],
            // The crypto backend stays a leaf swap (WASM), and the FEC C
            // backend sits behind its one Swift adapter.
            confinedImports: [
                "Crypto": "Wire/Sources/LyteWire/Crypto/",
                "CNanorsWire": "Wire/Sources/LyteWire/Fec/NanorsBackend.swift",
            ]
        ),
        Boundary(
            path: "Host/Sources/HostCore",
            allowedImports: ["LyteCore"]
        ),
        Boundary(
            path: "Host/Sources/HostSession",
            allowedImports: ["LyteCore", "LyteWire"]
        ),
        // The host session core. Its file IO lives in the HostIO adapter
        // and its sockets, threads and clocks in lyte-host, so neither
        // may be imported here.
        Boundary(
            path: "Host/Sources/HostWire",
            allowedImports: ["HostCore", "HostSession", "LyteCore", "LyteWire"]
        ),
        // The browser's core under the JavaScriptKit shell: the page owns
        // every effect.
        Boundary(
            path: "Browser/Sources/LyteClientBrowserCore",
            allowedImports: [
                "LyteClientCore", "LyteClientSession", "LyteCore", "LyteWire",
            ]
        ),
    ]

    private static let forbiddenTokenSequences: [[String]] = [
        ["FileManager"], ["FileHandle"], ["ProcessInfo"], ["URLSession"],
        ["print", "("], ["readLine", "("],
        ["DispatchQueue"], ["DispatchSemaphore"],
        ["Task"], ["withTaskGroup"], ["withThrowingTaskGroup"],
        ["withDiscardingTaskGroup"], ["actor"], ["MainActor"],
        ["Thread"], ["NSLock"], ["Mutex"], ["os_unfair_lock"],
        ["ContinuousClock"], ["SuspendingClock"], ["Date", "("],
        ["clock_gettime", "("], ["mach_absolute_time", "("],
        ["SystemRandomNumberGenerator"], ["socket", "("],
        ["NWConnection"], ["NWListener"], ["NWPathMonitor"],
    ]

    /// Standard-library calls that draw from the system generator unless
    /// they are handed one.
    private static let implicitRandomCalls: Set<String> = [
        "random", "randomElement", "shuffled", "shuffle",
    ]

    /// `tokens`' side-effect violations: a forbidden sequence, or an
    /// implicit-randomness call whose argument list names no `using`.
    private static func vocabularyViolations(in tokens: [String]) -> [String] {
        var found = forbiddenTokenSequences
            .filter { SwiftSourceScanner.contains($0, in: tokens) }
            .map { $0.joined() }
        for index in tokens.indices.dropLast()
        where implicitRandomCalls.contains(tokens[index])
            && tokens[index + 1] == "("
            && (index == tokens.startIndex || tokens[index - 1] != "func") {
            var depth = 0
            var cursor = index + 1
            var namesGenerator = false
            repeat {
                switch tokens[cursor] {
                case "(": depth += 1
                case ")": depth -= 1
                case "using" where depth == 1: namesGenerator = true
                default: break
                }
                cursor += 1
            } while depth > 0 && cursor < tokens.endIndex
            if !namesGenerator {
                found.append("\(tokens[index])( without using:")
            }
        }
        return found
    }

    private static func importViolations(
        of boundary: Boundary,
        path: String,
        source: String
    ) -> [String] {
        SwiftSourceScanner.importedModules(in: source).compactMap { module in
            if module == "Swift" { return nil }
            guard boundary.allowedImports.contains(module) else {
                return "\(path): import \(module)"
            }
            if let confinement = boundary.confinedImports[module],
               !path.hasPrefix(confinement) {
                return "\(path): import \(module) outside \(confinement)"
            }
            return nil
        }
    }

    func testRegisteredSansIOBoundariesPointOnlyInward() throws {
        var violations: [String] = []
        for boundary in boundaries {
            for file in try tree.swiftFiles(below: boundary.path) {
                violations += Self.importViolations(
                    of: boundary,
                    path: tree.relativePath(for: file),
                    source: try tree.source(of: file))
            }
        }
        XCTAssertEqual(
            violations.sorted(),
            [],
            "sans-IO targets may import only their declared inward leaves"
        )
    }

    /// The import check itself: OS modules are refused by the allowlist,
    /// confined leaves are refused outside their path, and every spelling
    /// of an import declaration counts.
    func testImportCheckRefusesOSModulesAndMisplacedLeaves() {
        let wire = boundaries.first { $0.path == "Wire/Sources/LyteWire" }!
        let core = boundaries.first { $0.path == "Common/Sources/LyteCore" }!
        let refused: [(Boundary, String, String)] = [
            (core, "Common/Sources/LyteCore/A.swift", "import Foundation\n"),
            (core, "Common/Sources/LyteCore/A.swift", "import Dispatch\n"),
            (core, "Common/Sources/LyteCore/A.swift", "@preconcurrency import Network\n"),
            (core, "Common/Sources/LyteCore/A.swift", "import class Foundation.Thread\n"),
            (core, "Common/Sources/LyteCore/A.swift", "import Glibc\n"),
            (wire, "Wire/Sources/LyteWire/Crypto/A.swift", "import CryptoKit\n"),
            (wire, "Wire/Sources/LyteWire/Video/A.swift", "import Crypto\n"),
            (wire, "Wire/Sources/LyteWire/Fec/Other.swift", "import CNanorsWire\n"),
        ]
        for (boundary, path, source) in refused {
            XCTAssertEqual(
                Self.importViolations(of: boundary, path: path, source: source)
                    .count, 1, "\(path): \(source)")
        }
        let admitted: [(Boundary, String, String)] = [
            (wire, "Wire/Sources/LyteWire/Crypto/Noise/A.swift", "import Crypto\n"),
            (wire, "Wire/Sources/LyteWire/Fec/NanorsBackend.swift", "import CNanorsWire\n"),
            (wire, "Wire/Sources/LyteWire/Video/A.swift", "import LyteCore\n"),
            (core, "Common/Sources/LyteCore/A.swift", "// import Foundation\n"),
        ]
        for (boundary, path, source) in admitted {
            XCTAssertEqual(
                Self.importViolations(of: boundary, path: path, source: source),
                [], "\(path): \(source)")
        }
    }

    func testRegisteredSansIOBoundariesContainNoIOSynchronizationOrOSClocks()
        throws
    {
        var violations: [String] = []
        for boundary in boundaries {
            for file in try tree.swiftFiles(below: boundary.path) {
                let path = tree.relativePath(for: file)
                violations += Self.vocabularyViolations(
                    in: try tree.tokens(of: file)
                ).map { "\(path): \($0)" }
            }
        }
        XCTAssertEqual(
            violations.sorted(),
            [],
            "sans-IO targets receive time, randomness, and effects as values"
        )
    }

    /// The vocabulary check itself: concurrency in every spelling, stdout,
    /// and randomness drawn without an injected generator are refused;
    /// injected randomness, a declaration named `random`, and mentions in
    /// comments or strings are not.
    func testVocabularyCheckRefusesConcurrencyStdoutAndImplicitRandomness() {
        let refused = [
            "Task.detached { work() }",
            "Task(priority: .high) { work() }",
            "let task: Task<Void, Never>",
            "await withTaskGroup(of: Int.self) { _ in }",
            "actor Box {}",
            "@MainActor final class View {}",
            "print(value)",
            "let x = Int.random(in: 0...9)",
            "let b = Bool.random()",
            "let e = values.randomElement()",
            "let s = values.shuffled()",
            "let x = Int.random(in: Swift.min(a, b)...9)",
        ]
        for source in refused {
            XCTAssertFalse(
                Self.vocabularyViolations(
                    in: SwiftSourceScanner.tokens(in: source)).isEmpty,
                source)
        }
        let admitted = [
            "let x = Int.random(in: 0...9, using: &rng)",
            "let s = values.shuffled(using: &generator)",
            "public static func random(using rng: inout some RandomNumberGenerator)",
            "// Task.detached and print( in a comment",
            #"let text = "Task { print(x) }""#,
            "let taskCount = tasks.count",
        ]
        for source in admitted {
            XCTAssertEqual(
                Self.vocabularyViolations(
                    in: SwiftSourceScanner.tokens(in: source)), [], source)
        }
    }
}
