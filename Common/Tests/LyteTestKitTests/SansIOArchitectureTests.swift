import Foundation
import LyteTestKit
import XCTest

/// The one enforcement point for the sans-IO law. Each registered pure
/// target may import only its declared inward leaves (an allowlist, so
/// Foundation, Dispatch, Network, Darwin, Glibc, CryptoKit and every other
/// OS module are refused by default), some leaves only below a narrower
/// path, and its tokens may name no IO, synchronization, or OS clock.
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
            allowedImports: []
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
    ]

    private static let forbiddenTokenSequences: [[String]] = [
        ["FileManager"], ["FileHandle"], ["ProcessInfo"], ["URLSession"],
        ["DispatchQueue"], ["DispatchSemaphore"], ["Task", "{"],
        ["Thread"], ["NSLock"], ["Mutex"], ["os_unfair_lock"],
        ["ContinuousClock"], ["SuspendingClock"], ["Date", "("],
        ["clock_gettime", "("], ["mach_absolute_time", "("],
        ["SystemRandomNumberGenerator"], ["socket", "("],
        ["NWConnection"], ["NWListener"], ["NWPathMonitor"],
    ]

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
                let tokens = try tree.tokens(of: file)
                for sequence in Self.forbiddenTokenSequences
                where SwiftSourceScanner.contains(sequence, in: tokens) {
                    violations.append(
                        "\(tree.relativePath(for: file)): \(sequence.joined())"
                    )
                }
            }
        }
        XCTAssertEqual(
            violations.sorted(),
            [],
            "sans-IO targets receive time, randomness, and effects as values"
        )
    }
}
