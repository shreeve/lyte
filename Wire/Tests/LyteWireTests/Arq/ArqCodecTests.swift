import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// The ARQ frame codecs against hand-computed bytes — the anchor that
// keeps arq-v1.json honest (the vectorgen output is checked against
// these exact frames, so the codec never grades its own homework) —
// plus the construction bounds. Decode rejects live in the vectors and
// the never-trap sweep in CtrlDecoderFuzzTests.

final class ArqCodecTests: XCTestCase {

    // MARK: Hand-computed anchors

    func testHandComputedSegment() throws {
        let segment = try ArqSegment(
            group: ArqGroupId(rawValue: 5),
            seq: ArqSegmentSeq(rawValue: 0x0203),
            endOfMessage: true,
            body: [0xAA, 0xBB, 0xCC]
        )
        // type 07 | flags 01 (endOfMessage) | group 05 00 LE |
        // seq 03 02 LE | bodyLen 03 00 LE | body AA BB CC
        XCTAssertEqual(
            Hex.string(segment.encode()),
            "0701050003020300aabbcc"
        )
        let decoded = try ArqFrame.decodeAll(segment.encode())
        XCTAssertEqual(decoded, [.segment(segment)])
    }

    func testHandComputedAck() throws {
        let ack = try ArqAck(blocks: [
            ArqAck.Block(
                channel: .ctrl,
                group: ArqGroupId(rawValue: 5),
                cumulative: ArqSegmentSeq(rawValue: 0x0203),
                receivedBitmap: [0x05]
            )
        ])
        // type 08 | flags 00 | blockCount 01 | chan 00 | group 05 00 |
        // cumulative 03 02 | bitmapLen 01 | bitmap 05
        XCTAssertEqual(Hex.string(ack.encode()), "08000100050003020105")
        let decoded = try ArqFrame.decodeAll(ack.encode())
        XCTAssertEqual(decoded, [.ack(ack)])
        // Bitmap bit 2 names the seq three past the cumulative.
        XCTAssertEqual(ack.blocks[0].highestReported.rawValue, 0x0206)
    }

    func testHighestReportedWithEmptyBitmap() throws {
        let block = try ArqAck.Block(
            channel: .ctrl,
            group: .orderedStream,
            cumulative: ArqSegmentSeq(rawValue: 41)
        )
        XCTAssertEqual(block.highestReported.rawValue, 41)
    }

    // MARK: Construction bounds

    func testSegmentBounds() {
        assertThrows(ArqFrameError.zeroLengthSegmentBody) {
            try ArqSegment(
                group: .orderedStream, seq: ArqSegmentSeq(rawValue: 0),
                endOfMessage: true, body: []
            )
        }
        assertThrows(
            ArqFrameError.segmentBodyOverBudget(ArqBounds.maxSegmentBodyByteCount + 1)
        ) {
            try ArqSegment(
                group: .orderedStream, seq: ArqSegmentSeq(rawValue: 0),
                endOfMessage: true,
                body: [UInt8](
                    repeating: 0, count: ArqBounds.maxSegmentBodyByteCount + 1
                )
            )
        }
        // The max body fills the shard budget exactly.
        let max = try? ArqSegment(
            group: .orderedStream, seq: ArqSegmentSeq(rawValue: 0),
            endOfMessage: true,
            body: [UInt8](
                repeating: 0, count: ArqBounds.maxSegmentBodyByteCount
            )
        )
        XCTAssertEqual(
            max?.encodedByteCount, WireBudget.maxPlaintextShardByteCount
        )
    }

    func testAckBounds() throws {
        assertThrows(ArqFrameError.zeroAckBlocks) { try ArqAck(blocks: []) }
        let block = try ArqAck.Block(
            channel: .ctrl, group: .orderedStream,
            cumulative: ArqSegmentSeq(rawValue: 0)
        )
        assertThrows(
            ArqFrameError.tooManyAckBlocks(ArqBounds.maxAckBlocks + 1)
        ) {
            try ArqAck(
                blocks: Array(
                    repeating: block, count: ArqBounds.maxAckBlocks + 1
                )
            )
        }
        assertThrows(
            ArqFrameError.ackBitmapTooLong(ArqBounds.maxAckBitmapByteCount + 1)
        ) {
            try ArqAck.Block(
                channel: .ctrl, group: .orderedStream,
                cumulative: ArqSegmentSeq(rawValue: 0),
                receivedBitmap: [UInt8](
                    repeating: 1, count: ArqBounds.maxAckBitmapByteCount + 1
                )
            )
        }
        assertThrows(ArqFrameError.nonCanonicalAckBitmap) {
            try ArqAck.Block(
                channel: .ctrl, group: .orderedStream,
                cumulative: ArqSegmentSeq(rawValue: 0),
                receivedBitmap: [0x05, 0x00]
            )
        }
    }

    func testSerialArithmetic() {
        let low = ArqSegmentSeq(rawValue: 2)
        let high = ArqSegmentSeq(rawValue: 0xFFFE)
        // Serially, 0xFFFE is BEHIND 2 across the wrap.
        XCTAssertTrue(high < low)
        XCTAssertEqual(high.distance(to: low), 4)
        XCTAssertEqual(ArqSegmentSeq(rawValue: 0xFFFF).next.rawValue, 0)
    }
}
