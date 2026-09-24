import Foundation
import LyteTransport
import XCTest

/// A witness writes only where its configured environment names a file,
/// so a host app can gate it with the rest of its diagnostics.
final class JsonlWitnessTests: XCTestCase {
    func testConfiguredEnvironmentDecidesWhetherAndWhereItWrites() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyte-witness-\(UUID().uuidString).jsonl")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let witness = JsonlWitness(
            environmentKey: "LYTE_TEST_WITNESS",
            environment: ["LYTE_TEST_WITNESS": path])
        XCTAssertTrue(witness.isEnabled)

        witness.configure(environment: [:])
        XCTAssertFalse(witness.isEnabled)
        witness.record("dropped", fields: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        witness.configure(environment: ["LYTE_TEST_WITNESS": path])
        witness.record("kept", fields: ["n": "1"])
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("\"event\":\"kept\""))
    }
}
