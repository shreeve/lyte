import XCTest
import LyteWire
import LyteWireTestKit

// The promoted session codecs (codec-unification slice): conn-id TLV
// value codec + path challenge/response (HS-12, moved from HostWire) and
// the IDR request (CL-3/HS-7, reconciled from the two byte-identical
// end-side copies). The tests came with the codecs — same assertions the
// end packages ran — plus the hand-computed anchors that keep the
// session-v1.json vectorgen from grading its own homework.

final class SessionCodecTests: XCTestCase {

    private func makeConnectionId(seed: UInt64 = 0xC1D) -> ConnectionId {
        var rng = SplitMix64(seed: seed)
        return ConnectionId.random(using: &rng)
    }

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
        let connId = makeConnectionId()
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

    func testConnectionIdDecodeIsLoudOnHostileValues() throws {
        // Wrong width: the W0 vector pins 8 bytes.
        XCTAssertThrowsError(try ConnectionId(bytes: [1, 2, 3])) {
            XCTAssertEqual(
                $0 as? ConnectionIdError, .invalidValueLength(3)
            )
        }
        // Two identity claims in one envelope is ambiguity, not a tie.
        let connId = makeConnectionId()
        XCTAssertThrowsError(try ConnectionId.decode(extensions: [
            connId.wireExtension,
            makeConnectionId(seed: 0xBAD).wireExtension,
        ])) {
            XCTAssertEqual($0 as? ConnectionIdError, .duplicateTlv)
        }
        // A malformed value inside the reserved type is loud too.
        XCTAssertThrowsError(try ConnectionId.decode(extensions: [
            try WireExtension(
                type: WireExtension.ReservedType.connectionId,
                value: [0xAA]
            )
        ])) {
            XCTAssertEqual(
                $0 as? ConnectionIdError, .invalidValueLength(1)
            )
        }
    }

    // MARK: Challenge/response codec

    func testPathMessageCodecsRoundTripAndReject() throws {
        let challenge = PathChallenge(token: 0x0102_0304_0506_0708)
        let challengeWire = challenge.encode()
        XCTAssertEqual(challengeWire.count, PathChallenge.encodedByteCount)
        XCTAssertEqual(challengeWire[0], CtrlMessageType.pathChallenge)
        XCTAssertEqual(try PathChallenge.decode(challengeWire), challenge)

        let response = PathResponse(echoing: challenge)
        XCTAssertEqual(response.token, challenge.token)
        let responseWire = response.encode()
        XCTAssertEqual(responseWire[0], CtrlMessageType.pathResponse)
        XCTAssertEqual(try PathResponse.decode(responseWire), response)

        // Truncation and type confusion reject; they never cross-decode.
        XCTAssertThrowsError(
            try PathChallenge.decode(Array(challengeWire.dropLast()))
        )
        XCTAssertThrowsError(try PathResponse.decode(challengeWire)) {
            XCTAssertEqual(
                $0 as? PathMessageError,
                .unexpectedType(CtrlMessageType.pathChallenge)
            )
        }
    }

    // MARK: IDR-request codec

    func testIdrRequestCodecRoundTripsAndRejects() throws {
        let request = IdrRequest(
            requestSeq: 3, frame: FrameNumber(rawValue: 123_456),
            coalescedCount: 7)
        let bytes = request.encode()
        XCTAssertEqual(bytes.count, IdrRequest.encodedByteCount)
        XCTAssertEqual(bytes[0], CtrlMessageType.idrRequest)
        XCTAssertEqual(try IdrRequest.decode(bytes), request)

        XCTAssertThrowsError(try IdrRequest.decode(Array(bytes.dropLast()))) {
            XCTAssertEqual($0 as? IdrRequestError, .truncatedMessage)
        }
        XCTAssertThrowsError(try IdrRequest.decode(bytes + [0])) {
            XCTAssertEqual($0 as? IdrRequestError, .trailingBytes)
        }
        var foreign = bytes
        foreign[0] = CtrlMessageType.beaconEcho
        XCTAssertThrowsError(try IdrRequest.decode(foreign)) {
            XCTAssertEqual($0 as? IdrRequestError, .unexpectedType(0x02))
        }
    }
}
