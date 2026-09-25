import XCTest
import LyteWire

// The anchor bytes below were computed by hand from the layout comment in
// FeedbackReport.swift, not by running the codec — same circularity-
// breaking rule as EnvelopeTests/FecFieldTests/ClockBeaconTests.

final class FeedbackReportTests: XCTestCase {

    // MARK: Hand-computed anchor

    // pathId=0, TLV flag set, clientTimestamp=0x4142434445464748,
    // dispersionBase=5,000,000 (0x4C4B40), 2 channel blocks, 3 samples,
    // 1 NACK (frame 0x000A0B0C, shards 0+2 → bitmap 0x05), 1 TLV
    // (type 0x7F, value aabb) — 80 bytes.
    private let anchorBytes: [UInt8] = [
        0x00, 0x01,
        0x48, 0x47, 0x46, 0x45, 0x44, 0x43, 0x42, 0x41,
        0x40, 0x4B, 0x4C, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x03, 0x01,
        // chan 2: highestSeq 0x1234, received 100000, missing 5, dup 2
        0x02, 0x34, 0x12, 0xA0, 0x86, 0x01, 0x00,
        0x05, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
        // chan 1: highestSeq 0xFFFF, received 200000, missing 0, dup 0
        0x01, 0xFF, 0xFF, 0x40, 0x0D, 0x03, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // samples: (2, 0x1230, 0) (2, 0x1231, 500) (2, 0x1232, 1000)
        0x02, 0x30, 0x12, 0x00, 0x00, 0x00,
        0x02, 0x31, 0x12, 0xF4, 0x01, 0x00,
        0x02, 0x32, 0x12, 0xE8, 0x03, 0x00,
        // NACK: frame 0x000A0B0C, bitmap 1 byte, shards {0, 2}
        0x0C, 0x0B, 0x0A, 0x00, 0x01, 0x05,
        // TLV block: 1 entry, type 0x7F, 2-byte value
        0x01, 0x7F, 0x02, 0xAA, 0xBB,
    ]

    private func anchorReport() throws -> FeedbackReport {
        FeedbackReport(
            pathId: 0,
            clientTimestamp: ClientTimestamp(microseconds: 0x4142_4344_4546_4748),
            channels: [
                .init(
                    channel: .videoActive,
                    highestSeq: ChannelSeq(rawValue: 0x1234),
                    received: 100_000, missing: 5, duplicates: 2
                ),
                .init(
                    channel: .audio,
                    highestSeq: ChannelSeq(rawValue: 0xFFFF),
                    received: 200_000, missing: 0, duplicates: 0
                ),
            ],
            dispersion: .init(
                base: ClientTimestamp(microseconds: 5_000_000),
                samples: [
                    .init(channel: .videoActive, seq: ChannelSeq(rawValue: 0x1230),
                          arrivalDeltaMicroseconds: 0),
                    .init(channel: .videoActive, seq: ChannelSeq(rawValue: 0x1231),
                          arrivalDeltaMicroseconds: 500),
                    .init(channel: .videoActive, seq: ChannelSeq(rawValue: 0x1232),
                          arrivalDeltaMicroseconds: 1_000),
                ]
            ),
            nacks: [
                try .init(frame: FrameNumber(rawValue: 0x000A_0B0C),
                          missingShards: [0, 2]),
            ],
            extensions: [
                try WireExtension(type: 0x7F, value: [0xAA, 0xBB]),
            ]
        )
    }

    func testAnchorEncode() throws {
        XCTAssertEqual(try anchorReport().encode(), anchorBytes)
    }

    func testAnchorDecode() throws {
        XCTAssertEqual(try FeedbackReport.decode(anchorBytes), try anchorReport())
    }

    // MARK: Empty sections

    func testEmptyReportRoundTrip() throws {
        let report = FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: 123_456)
        )
        let bytes = try report.encode()
        XCTAssertEqual(bytes.count, FeedbackBounds.fixedHeaderByteCount)
        XCTAssertTrue(
            bytes[10..<18].allSatisfy { $0 == 0 },
            "dispersionBase must be zero without samples"
        )
        XCTAssertEqual(try FeedbackReport.decode(bytes), report)
    }

    func testNonZeroBaseWithoutSamplesRejected() throws {
        var bytes = try FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: 1)
        ).encode()
        bytes[10] = 0x01
        assertThrows(FeedbackError.nonZeroBaseWithoutSamples) {
            try FeedbackReport.decode(bytes)
        }
    }

    func testEmptyDispersionSectionRejectedAtEncode() {
        let report = FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: 1),
            dispersion: .init(base: ClientTimestamp(microseconds: 2), samples: [])
        )
        assertThrows(FeedbackError.emptyDispersionSection) {
            try report.encode()
        }
    }

    // MARK: Bounds enforcement (encode and decode agree)

    private func statsBlock(_ n: UInt8) -> FeedbackReport.ChannelStats {
        .init(channel: ChannelId(rawValue: n),
              highestSeq: ChannelSeq(rawValue: UInt16(n)),
              received: 1, missing: 0, duplicates: 0)
    }

    private func sample(_ i: Int) -> FeedbackReport.Dispersion.Sample {
        .init(channel: .videoActive, seq: ChannelSeq(rawValue: UInt16(i)),
              arrivalDeltaMicroseconds: UInt32(i))
    }

    func testChannelBlockBound() throws {
        let over = FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: 1),
            channels: (0...8).map { statsBlock($0) }
        )
        assertThrows(FeedbackError.tooManyChannelBlocks(9)) {
            try over.encode()
        }
        var atBound = over
        atBound.channels.removeLast()
        XCTAssertNoThrow(try atBound.encode())
        // Decode side: a count byte over the bound rejects before any
        // section parsing.
        var bytes = try atBound.encode()
        bytes[18] = 9
        assertThrows(FeedbackError.tooManyChannelBlocks(9)) {
            try FeedbackReport.decode(bytes)
        }
    }

    func testDispersionSampleBound() throws {
        let over = FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: 1),
            dispersion: .init(
                base: ClientTimestamp(microseconds: 0),
                samples: (0..<113).map { sample($0) }
            )
        )
        assertThrows(FeedbackError.tooManyDispersionSamples(113)) {
            try over.encode()
        }
        var atBound = over
        atBound.dispersion?.samples.removeLast()
        let bytes = try atBound.encode()
        XCTAssertEqual(try FeedbackReport.decode(bytes), atBound)
        var corrupt = bytes
        corrupt[19] = 200
        assertThrows(FeedbackError.tooManyDispersionSamples(200)) {
            try FeedbackReport.decode(corrupt)
        }
    }

    func testNackEntryBound() throws {
        let entries = try (0..<7).map {
            try FeedbackReport.NackEntry(
                frame: FrameNumber(rawValue: UInt32($0)), missingShards: [0]
            )
        }
        let over = FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: 1), nacks: entries
        )
        assertThrows(FeedbackError.tooManyNackEntries(7)) { try over.encode() }
        var atBound = over
        atBound.nacks.removeLast()
        var bytes = try atBound.encode()
        XCTAssertEqual(try FeedbackReport.decode(bytes), atBound)
        bytes[20] = 7
        assertThrows(FeedbackError.tooManyNackEntries(7)) {
            try FeedbackReport.decode(bytes)
        }
    }

    func testArrivalDeltaBound() throws {
        var report = FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: 1),
            dispersion: .init(
                base: ClientTimestamp(microseconds: 0),
                samples: [.init(channel: .videoActive,
                                seq: ChannelSeq(rawValue: 0),
                                arrivalDeltaMicroseconds: 0x0100_0000)]
            )
        )
        assertThrows(FeedbackError.arrivalDeltaOutOfRange(0x0100_0000)) {
            try report.encode()
        }
        report.dispersion?.samples[0].arrivalDeltaMicroseconds = 0xFF_FFFF
        XCTAssertEqual(
            try FeedbackReport.decode(try report.encode()), report,
            "the u24 ceiling itself round-trips"
        )
    }

    // MARK: NACK canonical form

    func testNackEntryCanonicalizes() throws {
        let entry = try FeedbackReport.NackEntry(
            frame: FrameNumber(rawValue: 9),
            missingShards: [200, 3, 3, 0, 200]
        )
        XCTAssertEqual(entry.missingShards, [0, 3, 200])
        assertThrows(FeedbackError.emptyNackShardList) {
            try FeedbackReport.NackEntry(
                frame: FrameNumber(rawValue: 9), missingShards: []
            )
        }
    }

    func testNackShard254UsesFullBitmap() throws {
        let report = FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: 1),
            nacks: [try .init(frame: FrameNumber(rawValue: 1),
                              missingShards: [254])]
        )
        let bytes = try report.encode()
        // 21 header + 4 frame + 1 count + 32 bitmap bytes.
        XCTAssertEqual(bytes.count, 21 + 5 + 32)
        XCTAssertEqual(bytes[25], 32)
        XCTAssertEqual(try FeedbackReport.decode(bytes), report)
    }

    func testNonCanonicalBitmapRejected() throws {
        // frame 1, bitmapByteCount 2, bitmap 0x01 0x00: zero final byte.
        let bytes = try FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: 1)
        ).encode()
        var corrupt = Array(bytes[..<20]) + [1]
            + [0x01, 0x00, 0x00, 0x00, 0x02, 0x01, 0x00]
        assertThrows(FeedbackError.nonCanonicalNackBitmap) {
            try FeedbackReport.decode(corrupt)
        }
        // bitmapByteCount 0 and 33 both reject on the count itself.
        corrupt = Array(bytes[..<20]) + [1] + [0x01, 0x00, 0x00, 0x00, 0x00]
        assertThrows(FeedbackError.nackBitmapByteCountOutOfRange(0)) {
            try FeedbackReport.decode(corrupt)
        }
        corrupt = Array(bytes[..<20]) + [1] + [0x01, 0x00, 0x00, 0x00, 33]
            + [UInt8](repeating: 0xFF, count: 33)
        assertThrows(FeedbackError.nackBitmapByteCountOutOfRange(33)) {
            try FeedbackReport.decode(corrupt)
        }
    }

    // MARK: Budget

    func testBoundsMaxedReportFitsTheShardBudget() throws {
        XCTAssertEqual(FeedbackBounds.maxEncodedByteCountWithoutExtensions, 1035)
        let maxed = try maxedReport()
        let bytes = try maxed.encode()
        XCTAssertEqual(bytes.count, 1035)
        XCTAssertLessThanOrEqual(
            bytes.count, WireBudget.maxPlaintextShardByteCount
        )
        XCTAssertEqual(try FeedbackReport.decode(bytes), maxed)
    }

    func testOverBudgetViaExtensionsRejected() throws {
        var report = try maxedReport()
        // 1035 structural + 1 TLV-count + (2 + 75) = 1113 > 1112.
        report.extensions = [try WireExtension(
            type: 0x7F, value: [UInt8](repeating: 0xEE, count: 75)
        )]
        assertThrows(FeedbackError.reportOverBudget(1113)) {
            try report.encode()
        }
        // One byte less fits exactly.
        report.extensions = [try WireExtension(
            type: 0x7F, value: [UInt8](repeating: 0xEE, count: 74)
        )]
        XCTAssertEqual(try report.encode().count, 1112)
    }

    func testTrailingBytesRejected() throws {
        let bytes = try anchorReport().encode()
        assertThrows(FeedbackError.trailingBytes) {
            try FeedbackReport.decode(bytes + [0x00])
        }
    }

    func testTruncationSweepNeverTraps() throws {
        let bytes = try anchorReport().encode()
        for cut in 0..<bytes.count {
            XCTAssertThrowsError(
                try FeedbackReport.decode(Array(bytes.prefix(cut))), "cut \(cut)"
            )
        }
    }

    /// Every bound at its maximum: 8 channel blocks, 112 samples, 6 NACK
    /// entries with full 32-byte bitmaps — the 1035 B structural ceiling.
    private func maxedReport() throws -> FeedbackReport {
        FeedbackReport(
            pathId: 0,
            clientTimestamp: ClientTimestamp(microseconds: 0xFFFF_FFFF_FFFF_FFFF),
            channels: (0..<8).map { statsBlock($0) },
            dispersion: .init(
                base: ClientTimestamp(microseconds: 1),
                samples: (0..<112).map { sample($0) }
            ),
            nacks: try (0..<6).map {
                try .init(
                    frame: FrameNumber(rawValue: UInt32($0)),
                    missingShards: Array(0...254)
                )
            }
        )
    }
}
