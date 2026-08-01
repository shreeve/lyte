import XCTest
import LyteWire
import LyteWireTestKit

// The packetizer's contract, anchored by hand: shard payloads are the
// balanced split plus parity, envelopes carry the right fields byte-for-
// byte, and seq allocation is contiguous ascending in shard-index order
// (the wire contract the assembler's NACK inference stands on).

final class VideoPacketizerTests: XCTestCase {

    /// A minimal IDR frame: 4-byte start code, IDR_W_RADL header, filler.
    private func idrFrame(totalByteCount: Int) -> [UInt8] {
        [0, 0, 0, 1, 0x26, 0x01]
            + (0..<(totalByteCount - 6)).map { UInt8(($0 + 2) & 0xFF) }
    }

    private func pFrame(totalByteCount: Int) -> [UInt8] {
        [0, 0, 0, 1, 0x02, 0x01]
            + (0..<(totalByteCount - 6)).map { UInt8(($0 + 2) & 0xFF) }
    }

    func testHandWalkedTinyFrame() throws {
        // 10 B IDR → k=1 (bucket 1…2 clean: m=1). Two shards: the data
        // shard is the frame verbatim, the parity shard is its RS image
        // (k=1 parity = data, the eye-verifiable nanors identity).
        let frame = idrFrame(totalByteCount: 10)
        var packetizer = VideoPacketizer(firstSeq: ChannelSeq(rawValue: 7))
        let shards = try packetizer.packetize(
            frame: frame,
            frameNumber: FrameNumber(rawValue: 42),
            captureTimestamp: HostTimestamp(microseconds: 0x1122_3344),
            isIDR: true,
            regime: .clean
        )
        XCTAssertEqual(shards.count, 2)
        XCTAssertEqual(shards[0].payload, frame)
        XCTAssertEqual(shards[1].payload, frame) // k=1: parity = data

        for (index, shard) in shards.enumerated() {
            XCTAssertEqual(shard.envelope.channel, .videoActive)
            XCTAssertEqual(shard.envelope.seq.rawValue, UInt16(7 + index))
            XCTAssertEqual(shard.envelope.frame.rawValue, 42)
            XCTAssertEqual(shard.envelope.timestamp, 0x1122_3344)
            let field = try FecField.decode(shard.envelope.fec)
            guard case .reedSolomon(let shardIndex, let geometry) = field else {
                return XCTFail("expected an RS field")
            }
            XCTAssertEqual(Int(shardIndex), index)
            XCTAssertEqual(geometry.dataShards, 1)
            XCTAssertEqual(geometry.parityShards, 1)
            XCTAssertEqual(geometry.groupByteCount, 10)
        }
        XCTAssertEqual(packetizer.nextSeq.rawValue, 9)

        // The datagram header, byte by byte (the W0 anchor discipline):
        // chan=2, flags=0, seq=7 LE, frame=42 LE, ts LE, fec LE.
        let datagram = try shards[0].encodeDatagram()
        XCTAssertEqual(Array(datagram[0..<8]), [2, 0, 7, 0, 42, 0, 0, 0])
        XCTAssertEqual(
            Array(datagram[8..<16]), [0x44, 0x33, 0x22, 0x11, 0, 0, 0, 0]
        )
        // fec: shardIndex=0, k=1, m=1, scheme=1, group=10 (u24 LE).
        XCTAssertEqual(Array(datagram[16..<24]), [0, 1, 1, 1, 10, 0, 0, 0])
        XCTAssertEqual(Array(datagram[24...]), frame)
    }

    func testBalancedSplitReconcatenatesToTheFrame() throws {
        // 2500 B → k=3, bs=834, trailing shard 832 B (unpadded).
        let frame = pFrame(totalByteCount: 2500)
        var packetizer = VideoPacketizer()
        let shards = try packetizer.packetize(
            frame: frame,
            frameNumber: FrameNumber(rawValue: 0),
            captureTimestamp: HostTimestamp(microseconds: 0),
            isIDR: false,
            regime: .clean
        )
        XCTAssertEqual(shards.count, 5) // k=3 (bucket 3…8 clean m=2)
        XCTAssertEqual(shards[0].payload.count, 834)
        XCTAssertEqual(shards[1].payload.count, 834)
        XCTAssertEqual(shards[2].payload.count, 832)
        XCTAssertEqual(shards[3].payload.count, 834) // parity: full bs
        XCTAssertEqual(shards[4].payload.count, 834)
        XCTAssertEqual(
            shards[0].payload + shards[1].payload + shards[2].payload, frame
        )
    }

    func testSeqAllocationIsContiguousAcrossFramesAndWraps() throws {
        var packetizer = VideoPacketizer(firstSeq: ChannelSeq(rawValue: 0xFFFE))
        let first = try packetizer.packetize(
            frame: pFrame(totalByteCount: 1500), // k=2 m=1: seqs FFFE FFFF 0000
            frameNumber: FrameNumber(rawValue: 1),
            captureTimestamp: HostTimestamp(microseconds: 0),
            isIDR: false, regime: .clean
        )
        XCTAssertEqual(first.map(\.envelope.seq.rawValue), [0xFFFE, 0xFFFF, 0x0000])
        let second = try packetizer.packetize(
            frame: pFrame(totalByteCount: 100), // k=1 m=1: seqs 0001 0002
            frameNumber: FrameNumber(rawValue: 2),
            captureTimestamp: HostTimestamp(microseconds: 16_667),
            isIDR: false, regime: .clean
        )
        XCTAssertEqual(second.map(\.envelope.seq.rawValue), [0x0001, 0x0002])
        XCTAssertEqual(packetizer.nextSeq.rawValue, 0x0003)
    }

    func testEveryShardEncodesWithinTheDatagramBudget() throws {
        // A frame that fills shards to the 1112 B budget exactly.
        let frame = pFrame(totalByteCount: 2 * 1112)
        var packetizer = VideoPacketizer()
        for shard in try packetizer.packetize(
            frame: frame, frameNumber: FrameNumber(rawValue: 0),
            captureTimestamp: HostTimestamp(microseconds: 0),
            isIDR: false, regime: .lossy
        ) {
            let datagram = try shard.encodeDatagram()
            XCTAssertLessThanOrEqual(datagram.count, WireBudget.maxDatagramByteCount)
            XCTAssertEqual(datagram.count, 24 + shard.payload.count)
        }
    }

    func testRejectsNonFrameShapedInput() {
        var packetizer = VideoPacketizer()
        // No start code.
        XCTAssertThrowsError(try packetizer.packetize(
            frame: [0xFF, 0x00, 0x01, 0x02],
            frameNumber: FrameNumber(rawValue: 0),
            captureTimestamp: HostTimestamp(microseconds: 0),
            isIDR: false, regime: .clean
        )) { XCTAssertEqual($0 as? VideoError, .frameNotFrameShaped) }
        // Parameter sets only, no VCL.
        XCTAssertThrowsError(try packetizer.packetize(
            frame: [0, 0, 0, 1, 0x40, 0x01, 0x0C],
            frameNumber: FrameNumber(rawValue: 0),
            captureTimestamp: HostTimestamp(microseconds: 0),
            isIDR: false, regime: .clean
        )) { XCTAssertEqual($0 as? VideoError, .frameNotFrameShaped) }
        // The counter must not have moved on failure.
        XCTAssertEqual(packetizer.nextSeq.rawValue, 0)
    }

    func testRejectsIdrFlagDisagreeingWithBitstream() {
        var packetizer = VideoPacketizer()
        XCTAssertThrowsError(try packetizer.packetize(
            frame: idrFrame(totalByteCount: 20),
            frameNumber: FrameNumber(rawValue: 0),
            captureTimestamp: HostTimestamp(microseconds: 0),
            isIDR: false, regime: .clean
        )) {
            XCTAssertEqual(
                $0 as? VideoError, .idrFlagMismatch(claimed: false, derived: true)
            )
        }
        XCTAssertThrowsError(try packetizer.packetize(
            frame: pFrame(totalByteCount: 20),
            frameNumber: FrameNumber(rawValue: 0),
            captureTimestamp: HostTimestamp(microseconds: 0),
            isIDR: true, regime: .clean
        )) {
            XCTAssertEqual(
                $0 as? VideoError, .idrFlagMismatch(claimed: true, derived: false)
            )
        }
    }

    func testRejectsFrameBeyondTheProtectableCeiling() {
        // 232 data shards clean is past the GF(2⁸) truncation (k ≤ 231);
        // the packetizer throws rather than under-protects.
        let frame = pFrame(totalByteCount: 232 * 1112)
        var packetizer = VideoPacketizer()
        XCTAssertThrowsError(try packetizer.packetize(
            frame: frame, frameNumber: FrameNumber(rawValue: 0),
            captureTimestamp: HostTimestamp(microseconds: 0),
            isIDR: false, regime: .clean
        )) { error in
            guard case .unprotectableDataShardCount? = error as? FecError else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testBorrowedPacketizerMatchesArrayAndDoesNotRetainInput() throws {
        let original = idrFrame(totalByteCount: 7_003)
        var arrayPacketizer = VideoPacketizer(
            firstSeq: ChannelSeq(rawValue: 900)
        )
        let expected = try arrayPacketizer.packetize(
            frame: original, frameNumber: FrameNumber(rawValue: 44),
            captureTimestamp: HostTimestamp(microseconds: 123_456),
            isIDR: true, regime: .lossy
        )

        let pointer = UnsafeMutableBufferPointer<UInt8>.allocate(
            capacity: original.count
        )
        _ = pointer.initialize(from: original)
        var borrowedPacketizer = VideoPacketizer(
            firstSeq: ChannelSeq(rawValue: 900)
        )
        let actual = try borrowedPacketizer.packetize(
            frame: UnsafeBufferPointer(pointer),
            frameNumber: FrameNumber(rawValue: 44),
            captureTimestamp: HostTimestamp(microseconds: 123_456),
            isIDR: true, regime: .lossy
        )
        pointer.update(repeating: 0xCC)
        pointer.deallocate()

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(borrowedPacketizer.nextSeq, arrayPacketizer.nextSeq)
    }
}
