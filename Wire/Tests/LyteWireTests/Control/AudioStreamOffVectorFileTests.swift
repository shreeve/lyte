import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit
import LyteWireVectorGen

// Verifies the committed Vectors/audio-stream-off-v1.json byte-exact: the
// key-14 (audioStreamOff) capability spine.

final class AudioStreamOffVectorFileTests: XCTestCase {

    /// The accessors a vector's `flags` may name.
    private let accessors: [String: (Capabilities) -> Bool] = [
        "audioStreamOff": { $0.audioStreamOff },
        "hostAudioRouting": { $0.hostAudioRouting },
    ]

    private func loadFile() throws -> AudioStreamOffVectorFile {
        try AudioStreamOffVectorFile.loadCommitted()
    }

    /// Hand-computed anchors, so the codec never grades its own homework:
    /// key 14 appends `0E F5` to wireDefault's map (head 0xA8 → 0xA9), and
    /// beside key 9 the entries trail in key order (head 0xAA).
    func testHandComputedAnchors() throws {
        let hex = Dictionary(
            uniqueKeysWithValues: try loadFile().vectors.map { ($0.name, $0.messageHex) }
        )
        let wireDefault = "010002810103810104f5058006f407f408190480"
        XCTAssertEqual(hex["capability-key14-absent"], "a8" + wireDefault)
        XCTAssertEqual(hex["capability-key14-declared"], "a9" + wireDefault + "0ef5")
        XCTAssertEqual(
            hex["capability-key9-and-key14"], "aa" + wireDefault + "09f50ef5"
        )
    }

    func testEveryVectorDecodesToItsFlagsAndReencodesExactly() throws {
        let vectors = try loadFile().vectors
        XCTAssertEqual(
            Set(vectors.compactMap { $0.flags["audioStreamOff"] }), [true, false]
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
