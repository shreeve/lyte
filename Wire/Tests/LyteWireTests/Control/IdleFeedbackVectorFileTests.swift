import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit
import LyteWireVectorGen

// Verifies the committed Vectors/idle-feedback-v1.json byte-exact: the
// key-17 (idleFeedback) capability spine.

final class IdleFeedbackVectorFileTests: XCTestCase {

    /// The accessors a vector's `flags` may name.
    private let accessors: [String: (Capabilities) -> Bool] = [
        "idleFeedback": { $0.idleFeedback },
        "videoQuietPosture": { $0.videoQuietPosture },
    ]

    private func loadFile() throws -> IdleFeedbackVectorFile {
        try IdleFeedbackVectorFile.loadCommitted()
    }

    /// Hand-computed anchors, so the codec never grades its own homework:
    /// key 17 appends `11 F5` to wireDefault's map (head 0xA8 → 0xA9), and
    /// beside key 16 the entries trail in key order (head 0xAA).
    func testHandComputedAnchors() throws {
        let hex = Dictionary(
            uniqueKeysWithValues: try loadFile().vectors.map { ($0.name, $0.messageHex) }
        )
        let wireDefault = "010002810103810104f5058006f407f408190480"
        XCTAssertEqual(hex["capability-key17-absent"], "a8" + wireDefault)
        XCTAssertEqual(hex["capability-key17-declared"], "a9" + wireDefault + "11f5")
        XCTAssertEqual(
            hex["capability-key16-and-key17"], "aa" + wireDefault + "10f511f5"
        )
    }

    func testEveryVectorDecodesToItsFlagsAndReencodesExactly() throws {
        let vectors = try loadFile().vectors
        XCTAssertEqual(
            Set(vectors.compactMap { $0.flags["idleFeedback"] }), [true, false]
        )
        for vector in vectors {
            let message = try XCTUnwrap(Hex.bytes(vector.messageHex), vector.name)
            let decoded = try Capabilities.decodeCbor(message)
            XCTAssertEqual(Set(vector.flags.keys), Set(accessors.keys), vector.name)
            for (flag, expected) in vector.flags {
                XCTAssertEqual(accessors[flag]?(decoded), expected, "\(vector.name) \(flag)")
            }
            XCTAssertEqual(try decoded.encodeCbor(), message, vector.name)
        }
    }
}
