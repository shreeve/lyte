import XCTest
import LyteWire

// The anchor bytes below were computed by hand from the layout comment in
// Envelope.swift, not by running the codec — they are what breaks the
// circularity between the codec and the vector files it generated.

final class EnvelopeTests: XCTestCase {

    private let nominal = Envelope(
        channel: .videoActive,
        seq: ChannelSeq(rawValue: 0x1234),
        frame: FrameNumber(rawValue: 0x0A0B_0C0D),
        timestamp: 0x0102_0304_0506_0708,
        fec: 0x1122_3344_5566_7788
    )

    private let nominalBytes: [UInt8] = [
        0x02,  // chan = video-active
        0x00,  // flags = no extensions
        0x34, 0x12,  // seq 0x1234 LE
        0x0D, 0x0C, 0x0B, 0x0A,  // frame 0x0A0B0C0D LE
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,  // timestamp LE
        0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,  // fec LE
        0x6C, 0x79, 0x74, 0x65,  // "lyte"
    ]

    func testAnchorEncode() throws {
        let encoded = try nominal.encode(payload: Array("lyte".utf8))
        XCTAssertEqual(encoded, nominalBytes)
    }

    func testAnchorDecode() throws {
        let (envelope, payload) = try Envelope.decode(nominalBytes)
        XCTAssertEqual(envelope, nominal)
        XCTAssertEqual(Array(payload), Array("lyte".utf8))
    }

    func testEmptyPayloadIsExactlyTwentyFourBytes() throws {
        let envelope = Envelope(
            channel: .ctrl,
            seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0),
            timestamp: 0,
            fec: 0
        )
        let encoded = try envelope.encode()
        XCTAssertEqual(encoded.count, WireBudget.envelopeByteCount)
        XCTAssertEqual(encoded, [0x00, 0x00] + [UInt8](repeating: 0, count: 22))
        let (decoded, payload) = try Envelope.decode(encoded)
        XCTAssertEqual(decoded, envelope)
        XCTAssertTrue(payload.isEmpty)
    }

    func testTlvAnchorEncode() throws {
        var envelope = nominal
        envelope.extensions = [
            try WireExtension(type: 0x7F, value: [0xAA, 0xBB, 0xCC])
        ]
        let encoded = try envelope.encode(payload: [0x01])
        // Header: fixed 24 with flags bit0, then count=1, then 7F 03 AA BB CC.
        var expected = nominalBytes.prefix(24).map { $0 }
        expected[1] = 0x01
        expected += [0x01, 0x7F, 0x03, 0xAA, 0xBB, 0xCC, 0x01]
        XCTAssertEqual(encoded, expected)

        let (decoded, payload) = try Envelope.decode(encoded)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(Array(payload), [0x01])
    }

    func testUnknownTlvTypesDecodeAndSurviveReencode() throws {
        var envelope = nominal
        envelope.extensions = [
            try WireExtension(type: 0xEE, value: [1, 2, 3, 4]),
            try WireExtension(type: 0x99, value: []),
        ]
        let encoded = try envelope.encode(payload: [0xFF])
        let (decoded, payload) = try Envelope.decode(encoded)
        XCTAssertEqual(decoded.extensions, envelope.extensions)
        XCTAssertEqual(Array(payload), [0xFF])
        // Preserved verbatim: re-encoding is byte-identical.
        XCTAssertEqual(try decoded.encode(payload: Array(payload)), encoded)
    }

    func testReservedFlagBitsIgnoredOnReceive() throws {
        var bytes = nominalBytes
        bytes[1] = 0x80
        let (envelope, payload) = try Envelope.decode(bytes)
        XCTAssertEqual(envelope, nominal)
        XCTAssertEqual(Array(payload), Array("lyte".utf8))
    }

    func testTruncatedEnvelopeRejected() {
        for length in 0..<WireBudget.envelopeByteCount {
            XCTAssertThrowsError(
                try Envelope.decode(Array(nominalBytes.prefix(length)))
            ) { error in
                XCTAssertEqual(error as? WireError, .truncatedEnvelope)
            }
        }
    }

    func testTruncatedTlvBlockRejected() throws {
        var envelope = nominal
        envelope.extensions = [
            try WireExtension(type: 0x10, value: [1, 2, 3, 4, 5])
        ]
        let encoded = try envelope.encode(payload: [])
        // Every strict prefix that still passes the fixed-envelope check
        // must fail as a truncated extension block, never trap.
        for length in WireBudget.envelopeByteCount..<encoded.count {
            XCTAssertThrowsError(
                try Envelope.decode(Array(encoded.prefix(length)))
            ) { error in
                XCTAssertEqual(error as? WireError, .truncatedExtensions)
            }
        }
    }

    func testExtensionValueTooLongRejectedAtConstruction() {
        XCTAssertThrowsError(
            try WireExtension(type: 1, value: [UInt8](repeating: 0, count: 256))
        ) { error in
            XCTAssertEqual(error as? WireError, .extensionValueTooLong)
        }
    }
}

final class BudgetTests: XCTestCase {

    private func envelope() -> Envelope {
        Envelope(
            channel: .videoActive,
            seq: ChannelSeq(rawValue: 1),
            frame: FrameNumber(rawValue: 1),
            timestamp: 1,
            fec: 1
        )
    }

    func testBudgetConstantsAgree() {
        // 24 + 1128 = 1152 and 1112 + 16 = 1128 — the §4.2 ruling as math.
        XCTAssertEqual(
            WireBudget.envelopeByteCount + WireBudget.maxWirePayloadByteCount,
            WireBudget.maxDatagramByteCount
        )
        XCTAssertEqual(
            WireBudget.maxPlaintextShardByteCount + WireBudget.aeadTagByteCount,
            WireBudget.maxWirePayloadByteCount
        )
        XCTAssertEqual(
            WireBudget.maxConnectionIdTaggedPlaintextByteCount,
            1_101
        )
        XCTAssertEqual(
            WireBudget.maxConnectionIdTaggedPlaintextByteCount
                + 1 + 2 + ConnectionId.byteCount,
            WireBudget.maxPlaintextShardByteCount
        )
    }

    func testShardBudgetExactAt1112() throws {
        let atLimit = [UInt8](repeating: 0xAB, count: 1112)
        XCTAssertNoThrow(try envelope().encode(plaintextShard: atLimit))

        let over = [UInt8](repeating: 0xAB, count: 1113)
        XCTAssertThrowsError(try envelope().encode(plaintextShard: over)) {
            XCTAssertEqual($0 as? WireError, .shardOverBudget(1113))
        }
    }

    func testWirePayloadBudgetExactAt1128() throws {
        let atLimit = [UInt8](repeating: 0xCD, count: 1128)
        let datagram = try envelope().encode(payload: atLimit)
        XCTAssertEqual(datagram.count, WireBudget.maxDatagramByteCount)

        let over = [UInt8](repeating: 0xCD, count: 1129)
        XCTAssertThrowsError(try envelope().encode(payload: over)) {
            XCTAssertEqual($0 as? WireError, .payloadOverBudget(1129))
        }
    }

    func testTlvBytesCountAgainstDatagramBudget() throws {
        var withTlv = envelope()
        withTlv.extensions = [
            try WireExtension(type: 0x7F, value: [UInt8](repeating: 0, count: 21))
        ]
        // Header grows to 48; a max wire payload no longer fits.
        let payload = [UInt8](repeating: 0xEF, count: 1128)
        XCTAssertThrowsError(try withTlv.encode(payload: payload)) {
            XCTAssertEqual($0 as? WireError, .datagramOverBudget(1176))
        }
        // Shrinking the payload by the TLV block size fits exactly.
        let fitted = [UInt8](repeating: 0xEF, count: 1128 - 24)
        let datagram = try withTlv.encode(payload: fitted)
        XCTAssertEqual(datagram.count, WireBudget.maxDatagramByteCount)
    }

    func testOversizeDatagramRejectedOnDecode() throws {
        let junk = [UInt8](repeating: 0, count: 1153)
        XCTAssertThrowsError(try Envelope.decode(junk)) {
            XCTAssertEqual($0 as? WireError, .datagramOverBudget(1153))
        }
        // At exactly the budget, decode proceeds.
        let atLimit = try envelope().encode(
            payload: [UInt8](repeating: 1, count: 1128)
        )
        XCTAssertEqual(atLimit.count, 1152)
        XCTAssertNoThrow(try Envelope.decode(atLimit))
    }
}
