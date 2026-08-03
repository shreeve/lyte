#if !os(WASI)

import Foundation
import XCTest

final class NoFoundationLintTests: XCTestCase {
    private static var packageRoot: String {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false)
        components.removeLast(3)
        return components.joined(separator: "/")
    }

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

    func testLyteCoreSourcesAreSansIO() throws {
        XCTAssertEqual(try runLint(), 0)
    }

    func testLintCatchesForbiddenImports() throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyte-core-lint-\(UUID().uuidString)")
        try fileManager.createDirectory(
            at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        for (index, source) in [
            "import Foundation\n", "import Dispatch\n", "import Network\n",
            "import Crypto\n",
        ].enumerated() {
            let file = scratch.appendingPathComponent("Bad\(index).swift")
            try Data(source.utf8).write(to: file)
            XCTAssertEqual(try runLint(directory: scratch.path), 1)
            try fileManager.removeItem(at: file)
        }
    }
}

#endif
