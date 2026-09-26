import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit
import LyteWireVectorGen

// Verifies the committed Vectors/repair-refusal-v1.json byte-exact —
// the repair-refusal CTRL message (0x23) both ends code against,
// on both platforms.

final class RepairRefusalVectorFileTests: XCTestCase {

    private func loadFile() throws -> RepairRefusalVectorFile {
        try RepairRefusalVectorFile.loadCommitted()
    }

    func testCoverageDiscipline() throws {
        // The reason space is tiny; the file must pin all of it so an
        // enum addition can never slip in silently — and every
        // decode-reachable error name must be exercised.
        let file = try loadFile()
        let reasons = Set(file.vectors
            .filter { $0.kind == .roundtrip }
            .compactMap(\.reason))
        XCTAssertEqual(
            reasons, Set(RepairRefusalReason.allCases.map(\.rawValue))
        )
        let errors = Set(file.vectors
            .filter { $0.kind == .decodeReject }
            .compactMap(\.error))
        XCTAssertEqual(errors, [
            "truncatedMessage", "trailingBytes",
            "unexpectedType", "unknownReason",
        ])
    }

    func testAllRepairRefusalVectors() throws {
        for vector in try loadFile().vectors {
            guard let message = Hex.bytes(vector.messageHex) else {
                XCTFail("\(vector.name): malformed messageHex")
                continue
            }
            switch vector.kind {
            case .roundtrip:
                let frame = try XCTUnwrap(vector.frame, vector.name)
                let reasonValue = try XCTUnwrap(vector.reason, vector.name)
                let reason = try XCTUnwrap(
                    RepairRefusalReason(rawValue: reasonValue), vector.name
                )
                let refusal = RepairRefusal(
                    frame: FrameNumber(rawValue: frame), reason: reason
                )
                XCTAssertEqual(refusal.encode(), message, vector.name)
                XCTAssertEqual(
                    try RepairRefusal.decode(message), refusal, vector.name
                )
            case .decodeReject:
                assertVectorReject(
                    RepairRefusalError.self, vector.error, vector.name
                ) {
                    try RepairRefusal.decode(message)
                }
            }
        }
    }
}
