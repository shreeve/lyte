import XCTest
import LyteWire
import LyteWireTestKit

// The ARQ frame codecs against hand-computed bytes — the anchor that
// keeps arq-v1.json honest (the vectorgen output is checked against
// these exact frames, so the codec never grades its own homework) —
// plus decode-reject coverage and a never-traps fuzz.

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
        // Bitmap bits 0 and 2 name the seqs one and three past the
        // cumulative.
        XCTAssertEqual(
            ack.blocks[0].bitmapSeqs.map(\.rawValue),
            [0x0204, 0x0206]
        )
        XCTAssertEqual(ack.blocks[0].highestReported.rawValue, 0x0206)
    }

    func testHighestReportedWithEmptyBitmap() throws {
        let block = try ArqAck.Block(
            channel: .ctrl,
            group: .orderedStream,
            cumulative: ArqSegmentSeq(rawValue: 41)
        )
        XCTAssertEqual(block.highestReported.rawValue, 41)
        XCTAssertEqual(block.bitmapSeqs, [])
    }

    func testCoalescedFrameSequence() throws {
        let ack = try ArqAck(blocks: [
            ArqAck.Block(
                channel: .ctrl, group: .orderedStream,
                cumulative: ArqSegmentSeq(rawValue: 2)
            )
        ])
        let seg = try ArqSegment(
            group: .orderedStream,
            seq: ArqSegmentSeq(rawValue: 3),
            endOfMessage: true,
            body: [1, 2, 3, 4]
        )
        let payload = try ArqFrame.encodeAll([.ack(ack), .segment(seg)])
        XCTAssertEqual(
            try ArqFrame.decodeAll(payload),
            [.ack(ack), .segment(seg)]
        )
    }

    // MARK: Construction bounds

    func testSegmentBounds() {
        XCTAssertThrowsError(try ArqSegment(
            group: .orderedStream, seq: ArqSegmentSeq(rawValue: 0),
            endOfMessage: true, body: []
        )) {
            XCTAssertEqual(
                $0 as? ArqFrameError, .zeroLengthSegmentBody
            )
        }
        XCTAssertThrowsError(try ArqSegment(
            group: .orderedStream, seq: ArqSegmentSeq(rawValue: 0),
            endOfMessage: true,
            body: [UInt8](
                repeating: 0, count: ArqBounds.maxSegmentBodyByteCount + 1
            )
        )) {
            XCTAssertEqual(
                $0 as? ArqFrameError,
                .segmentBodyOverBudget(ArqBounds.maxSegmentBodyByteCount + 1)
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
        XCTAssertThrowsError(try ArqAck(blocks: [])) {
            XCTAssertEqual($0 as? ArqFrameError, .zeroAckBlocks)
        }
        let block = try ArqAck.Block(
            channel: .ctrl, group: .orderedStream,
            cumulative: ArqSegmentSeq(rawValue: 0)
        )
        XCTAssertThrowsError(try ArqAck(
            blocks: Array(
                repeating: block, count: ArqBounds.maxAckBlocks + 1
            )
        )) {
            XCTAssertEqual(
                $0 as? ArqFrameError,
                .tooManyAckBlocks(ArqBounds.maxAckBlocks + 1)
            )
        }
        XCTAssertThrowsError(try ArqAck.Block(
            channel: .ctrl, group: .orderedStream,
            cumulative: ArqSegmentSeq(rawValue: 0),
            receivedBitmap: [UInt8](
                repeating: 1, count: ArqBounds.maxAckBitmapByteCount + 1
            )
        )) {
            XCTAssertEqual(
                $0 as? ArqFrameError,
                .ackBitmapTooLong(ArqBounds.maxAckBitmapByteCount + 1)
            )
        }
        XCTAssertThrowsError(try ArqAck.Block(
            channel: .ctrl, group: .orderedStream,
            cumulative: ArqSegmentSeq(rawValue: 0),
            receivedBitmap: [0x05, 0x00]
        )) {
            XCTAssertEqual($0 as? ArqFrameError, .nonCanonicalAckBitmap)
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

    // MARK: Never traps

    func testDecodeNeverTrapsOnArbitraryBytes() {
        var rng = SplitMix64(seed: 0xA2_00_00_01)
        for _ in 0..<20_000 {
            let length = Int.random(in: 0...1200, using: &rng)
            var bytes = rng.bytes(length)
            // Bias toward the parser's edges: valid-looking frame types
            // with hostile interiors.
            if !bytes.isEmpty, Bool.random(using: &rng) {
                bytes[0] = Bool.random(using: &rng)
                    ? CtrlMessageType.arqSegment : CtrlMessageType.arqAck
            }
            _ = try? ArqFrame.decodeAll(bytes)
        }
    }

    func testDecodeOfTruncatedValidPayloadNeverTraps() throws {
        var rng = SplitMix64(seed: 0xA2_00_00_02)
        let seg = try ArqSegment(
            group: ArqGroupId(rawValue: 3),
            seq: ArqSegmentSeq(rawValue: 9),
            endOfMessage: true,
            body: rng.bytes(300)
        )
        let ack = try ArqAck(blocks: [
            ArqAck.Block(
                channel: .ctrl, group: ArqGroupId(rawValue: 3),
                cumulative: ArqSegmentSeq(rawValue: 8),
                receivedBitmap: [0xFF, 0x01]
            )
        ])
        let payload = try ArqFrame.encodeAll([.ack(ack), .segment(seg)])
        for cut in 0..<payload.count {
            _ = try? ArqFrame.decodeAll(Array(payload.prefix(cut)))
        }
    }
}
