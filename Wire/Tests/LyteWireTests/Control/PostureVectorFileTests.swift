import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit
import LyteWireVectorGen

// Verifies the committed Vectors/postures-v1.json byte-exact: the quiet-
// posture announcements AudioTrackState (0x25) and VideoPostureState
// (0x26), and the key-15/16 capability spine.

final class PostureVectorFileTests: XCTestCase {

    private func loadFile() throws -> PostureVectorFile {
        try PostureVectorFile.loadCommitted()
    }

    /// Every state, posture and error case is pinned, and the spine is
    /// pinned declared and absent for both keys.
    func testCoverageDiscipline() throws {
        let vectors = try loadFile().vectors
        func errors(_ codec: PostureVector.Codec) -> Set<String> {
            Set(vectors.filter { $0.codec == codec }.compactMap(\.error))
        }
        XCTAssertEqual(
            Set(vectors.compactMap(\.state)),
            Set(AudioTrackState.State.allCases.map { "\($0)" })
        )
        XCTAssertEqual(
            Set(vectors.compactMap(\.posture)),
            Set(VideoPostureState.Posture.allCases.map { "\($0)" })
        )
        XCTAssertEqual(errors(.audioTrackState), [
            "truncatedMessage", "unexpectedType", "trailingBytes", "unknownState",
        ])
        XCTAssertEqual(errors(.videoPostureState), [
            "truncatedMessage", "unexpectedType", "trailingBytes",
            "unknownPosture", "zeroInterval",
        ])
        XCTAssertEqual(Set(vectors.compactMap(\.audioQuietPosture)), [true, false])
        XCTAssertEqual(Set(vectors.compactMap(\.videoQuietPosture)), [true, false])
    }

    /// Hand-computed anchors, so the codec never grades its own
    /// homework: 30 = 0x1E; keys 15/16 append `0F F5` / `10 F5` to
    /// wireDefault's map (head 0xA8 → 0xA9 → 0xAA).
    func testHandComputedAnchors() throws {
        let hex = Dictionary(
            uniqueKeysWithValues: try loadFile().vectors.map { ($0.name, $0.messageHex) }
        )
        let wireDefault = "010002810103810104f5058006f407f408190480"
        XCTAssertEqual(hex["audio-track-quiet"], "2502")
        XCTAssertEqual(hex["video-posture-active-1s"], "260101")
        XCTAssertEqual(hex["video-posture-quiet-30s"], "26021e")
        XCTAssertEqual(hex["capability-postures-absent"], "a8" + wireDefault)
        XCTAssertEqual(hex["capability-key15-declared"], "a9" + wireDefault + "0ff5")
        XCTAssertEqual(hex["capability-key16-declared"], "a9" + wireDefault + "10f5")
        XCTAssertEqual(
            hex["capability-key15-and-key16"], "aa" + wireDefault + "0ff510f5"
        )
    }

    func testAllPostureVectors() throws {
        for vector in try loadFile().vectors {
            let message = try XCTUnwrap(Hex.bytes(vector.messageHex), vector.name)
            switch (vector.codec, vector.kind) {
            case (.audioTrackState, .roundtrip):
                let decoded = try AudioTrackState.decode(message)
                XCTAssertEqual("\(decoded.state)", vector.state, vector.name)
                XCTAssertEqual(decoded.encode(), message, vector.name)
            case (.audioTrackState, .decodeReject):
                assertVectorReject(
                    AudioTrackStateError.self, vector.error, vector.name
                ) {
                    try AudioTrackState.decode(message)
                }
            case (.videoPostureState, .roundtrip):
                let decoded = try VideoPostureState.decode(message)
                XCTAssertEqual("\(decoded.posture)", vector.posture, vector.name)
                XCTAssertEqual(
                    Int(decoded.keepaliveSeconds), vector.keepaliveSeconds, vector.name
                )
                XCTAssertEqual(decoded.encode(), message, vector.name)
            case (.videoPostureState, .decodeReject):
                assertVectorReject(
                    VideoPostureStateError.self, vector.error, vector.name
                ) {
                    try VideoPostureState.decode(message)
                }
            case (.capabilitySet, _):
                let decoded = try Capabilities.decodeCbor(message)
                XCTAssertEqual(decoded.audioQuietPosture, vector.audioQuietPosture, vector.name)
                XCTAssertEqual(decoded.videoQuietPosture, vector.videoQuietPosture, vector.name)
                XCTAssertEqual(try decoded.encodeCbor(), message, vector.name)
            }
        }
    }
}
