import Foundation
import LyteTestKit
import XCTest

final class SansIOArchitectureTests: XCTestCase {
    private struct Boundary {
        let path: String
        let allowedImports: Set<String>
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
            path: "Wire/Sources/LyteWire",
            allowedImports: ["CNanorsWire", "Crypto", "LyteCore"]
        ),
        Boundary(
            path: "Host/Sources/HostCore",
            allowedImports: ["LyteCore"]
        ),
    ]

    func testRegisteredSansIOBoundariesPointOnlyInward() throws {
        var violations: [String] = []
        for boundary in boundaries {
            for file in try tree.swiftFiles(below: boundary.path) {
                let source = try String(contentsOf: file, encoding: .utf8)
                for module in SwiftSourceScanner.importedModules(in: source)
                where module != "Swift"
                    && !boundary.allowedImports.contains(module) {
                    violations.append(
                        "\(tree.relativePath(for: file)): import \(module)"
                    )
                }
            }
        }
        XCTAssertEqual(
            violations.sorted(),
            [],
            "sans-IO targets may import only their declared inward leaves"
        )
    }

    func testRegisteredSansIOBoundariesContainNoIOSynchronizationOrOSClocks()
        throws
    {
        let forbiddenTokenSequences: [[String]] = [
            ["FileManager"], ["FileHandle"], ["ProcessInfo"], ["URLSession"],
            ["DispatchQueue"], ["DispatchSemaphore"], ["Task", "{"],
            ["Thread"], ["NSLock"], ["Mutex"], ["os_unfair_lock"],
            ["ContinuousClock"], ["SuspendingClock"], ["Date", "("],
            ["clock_gettime", "("], ["mach_absolute_time", "("],
            ["SystemRandomNumberGenerator"], ["socket", "("],
            ["NWConnection"], ["NWListener"], ["NWPathMonitor"],
        ]
        var violations: [String] = []
        for boundary in boundaries {
            for file in try tree.swiftFiles(below: boundary.path) {
                let source = try String(contentsOf: file, encoding: .utf8)
                let tokens = SwiftSourceScanner.tokens(in: source)
                for sequence in forbiddenTokenSequences
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
