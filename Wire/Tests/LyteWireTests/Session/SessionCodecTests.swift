import XCTest
import LyteWire
import LyteWireTestKit

// The session codecs: hand-computed anchors that keep session-v1.json's
// vectorgen from grading its own homework, plus the conn-id cases the
// vectors do not carry. Decode rejects live in the vectors.

final class SessionCodecTests: XCTestCase {

    // MARK: Hand-computed anchors

    func testPathMessageAnchorBytes() throws {
        // type 0x03, flags 0, token 0x0102030405060708 little-endian.
        let challenge = PathChallenge(token: 0x0102_0304_0506_0708)
        XCTAssertEqual(
            challenge.encode(),
            [0x03, 0x00, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]
        )
        XCTAssertEqual(
            PathResponse(echoing: challenge).encode(),
            [0x04, 0x00, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]
        )
    }

    func testIdrRequestAnchorBytes() throws {
        // type 0x10, requestSeq 3 LE, frame 123456 (0x0001E240) LE,
        // coalescedCount 5.
        let request = IdrRequest(
            requestSeq: 3, frame: FrameNumber(rawValue: 123_456),
            coalescedCount: 5
        )
        XCTAssertEqual(
            request.encode(),
            [0x10, 0x03, 0x00, 0x00, 0x00, 0x40, 0xE2, 0x01, 0x00, 0x05]
        )
    }

    // MARK: Conn-id TLV value codec

    func testConnectionIdRoundTripsThroughEnvelopeTlv() throws {
        var rng = SplitMix64(seed: 0xC1D)
        let connId = ConnectionId.random(using: &rng)
        let envelope = Envelope(
            channel: .videoActive,
            seq: ChannelSeq(rawValue: 7),
            frame: FrameNumber(rawValue: 3),
            timestamp: 1_000_000,
            fec: 0,
            extensions: [
                // An unknown type rides alongside: skipped, not tripped on.
                try WireExtension(type: 0x7F, value: [0xEE]),
                connId.wireExtension,
            ]
        )
        let wire = try envelope.encode(plaintextShard: [1, 2, 3])
        let (decoded, payload) = try Envelope.decode(wire)
        XCTAssertEqual(
            try ConnectionId.decode(extensions: decoded.extensions), connId
        )
        XCTAssertEqual(Array(payload), [1, 2, 3])

        // Absent TLV is a legal envelope: nil, not an error.
        XCTAssertNil(try ConnectionId.decode(extensions: [
            try WireExtension(type: 0x7F, value: [0xEE])
        ]))
        XCTAssertNil(try ConnectionId.decode(extensions: []))
    }

    func testConnectionIdRefusesAWrongWidth() {
        assertThrows(ConnectionIdError.invalidValueLength(3)) {
            try ConnectionId(bytes: [1, 2, 3])
        }
    }
}
