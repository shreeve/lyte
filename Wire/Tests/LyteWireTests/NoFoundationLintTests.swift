// WASI has no processes, so this Process-driven runner cannot exist there.
// The lint is a source-text check and keeps running everywhere native CI
// does (`swift test` on macOS and Linux); the wasm leg
// (Scripts/wasm-test.sh) skips it by construction.
#if !os(WASI)

import XCTest
import Foundation

// Runs Scripts/lint-no-foundation.sh as part of `swift test` on both
// platforms, so CI needs no extra wiring — the lint cannot be forgotten.
// The negative case runs the same script against a scratch tree with a
// deliberate violation, proving the lint actually bites.

final class NoFoundationLintTests: XCTestCase {

    private static let packageRoot = WireTestPaths.packageRoot

    private static let script = packageRoot + "/Scripts/lint-no-foundation.sh"

    private func runLint(directory: String? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [Self.script] + (directory.map { [$0] } ?? [])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testLyteWireSourcesAreFoundationFree() throws {
        XCTAssertEqual(try runLint(), 0, "lint failed on Sources/LyteWire")
    }

    func testLintCatchesForbiddenImports() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyte-wire-lint-\(UUID().uuidString)")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let violations = [
            "import Foundation\n",
            "  import Dispatch\n",
            "@preconcurrency import Network\n",
            "import class Foundation.Thread\n",
            "import FoundationNetworking\n",
        ]
        for (i, line) in violations.enumerated() {
            let file = scratch.appendingPathComponent("Bad\(i).swift")
            try Data(line.utf8).write(to: file)
            XCTAssertEqual(
                try runLint(directory: scratch.path), 1,
                "lint must reject: \(line.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
            try fileManager.removeItem(at: file)
        }

        // And it must not fire on innocents: identifiers that merely
        // contain the module names, or imports in comments.
        let innocent = """
        // import Foundation would be a violation, but this is a comment.
        let networkByteOrder = false
        struct FoundationStone {}
        import LyteWire
        """
        try Data(innocent.utf8).write(
            to: scratch.appendingPathComponent("Good.swift")
        )
        XCTAssertEqual(try runLint(directory: scratch.path), 0)
    }
}

#endif // !os(WASI)
