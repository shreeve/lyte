import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/repair-refusal-v1.json byte-exact —
// the HS-32 repair-refusal CTRL message (0x23) both ends code against,
// on both platforms.

final class RepairRefusalVectorFileTests: XCTestCase {

    private static let vectorsPath =
        packageRoot + "/Vectors/repair-refusal-v1.json"

    private static var packageRoot: String {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false
        )
        components.removeLast(3)
        return components.joined(separator: "/")
    }

    private func loadFile() throws -> RepairRefusalVectorFile {
        try RepairRefusalVectorFile.load(from: Self.vectorsPath)
    }

    func testFileIdentity() throws {
        let file = try loadFile()
        XCTAssertEqual(file.format, RepairRefusalVectorFile.expectedFormat)
        XCTAssertEqual(file.formatVersion, 1)
        XCTAssertEqual(file.wireVersion, Int(WireVersion.major))
        XCTAssertFalse(file.vectors.isEmpty)
        let names = file.vectors.map(\.name)
        XCTAssertEqual(
            Set(names).count, names.count, "vector names must be unique"
        )
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
                XCTAssertThrowsError(
                    try RepairRefusal.decode(message), vector.name
                ) { error in
                    guard let error = error as? RepairRefusalError else {
                        return XCTFail("\(vector.name): foreign error")
                    }
                    XCTAssertEqual(
                        repairRefusalErrorName(error), vector.error,
                        vector.name
                    )
                }
            }
        }
    }
}
