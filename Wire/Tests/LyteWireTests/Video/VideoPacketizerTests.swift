import XCTest
import LyteCore
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

    // MARK: Shard budget

    /// A session carrier that reserves envelope TLV headroom fills
    /// shards to less than 1112 B. This independent transcription of the
    /// budgeted packetizer is the oracle the Wire path must match shard
    /// for shard.
    private func budgetedReference(
        _ frame: [UInt8], isKeyframe: Bool, regime: FecRegime, budget: Int
    ) throws -> [VideoShardPayload] {
        let classification = AnnexBCheck.classifyFrame(frame)
        guard classification.isFrameShaped else {
            throw VideoError.frameNotFrameShaped
        }
        guard isKeyframe == classification.containsIrap else {
            throw VideoError.idrFlagMismatch(
                claimed: isKeyframe, derived: classification.containsIrap
            )
        }
        let k = (frame.count + budget - 1) / budget
        let m = try FecGeometryTable.parityShards(forDataShards: k, regime: regime)
        let geometry = try FecGeometry(
            dataShards: k, parityShards: m, groupByteCount: frame.count
        )
        return try FecEncoder.encode(group: frame, geometry: geometry)
            .enumerated().map { index, payload in
                VideoShardPayload(
                    fec: try FecField.reedSolomonShard(index, of: geometry).encoded,
                    payload: payload
                )
            }
    }

    func testBudgetedShardsMatchAnIndependentReference() throws {
        let budgets = [
            WireBudget.maxPlaintextShardByteCount,
            WireBudget.maxConnectionIdTaggedPlaintextByteCount,
            WireBudget.maxConnectionIdTaggedPlaintextByteCount - 12,
            600,
        ]
        let sizes = [7, 600, 601, 1_101, 1_102, 1_112, 1_113, 5_000, 33_000, 120_000]
        for budget in budgets {
            for size in sizes {
                for regime in FecRegime.allCases {
                    for keyframe in [true, false] {
                        let frame = keyframe
                            ? idrFrame(totalByteCount: size)
                            : pFrame(totalByteCount: size)
                        let label = "budget \(budget) size \(size) \(regime)"
                        let reference = Result {
                            try budgetedReference(
                                frame, isKeyframe: keyframe,
                                regime: regime, budget: budget
                            )
                        }
                        let wire = Result {
                            try VideoPacketizer.shardPayloads(
                                frame: frame, isIDR: keyframe, regime: regime,
                                shardBudgetByteCount: budget
                            )
                        }
                        switch (reference, wire) {
                        case (.success(let a), .success(let b)):
                            XCTAssertEqual(a, b, label)
                            XCTAssertTrue(
                                b.allSatisfy { $0.payload.count <= budget }, label
                            )
                        case (.failure(let a), .failure(let b)):
                            XCTAssertEqual("\(a)", "\(b)", label)
                        default:
                            XCTFail("\(label): \(reference) vs \(wire)")
                        }
                    }
                }
            }
        }
        // Wrong IDR claims are refused identically.
        XCTAssertThrowsError(try VideoPacketizer.shardPayloads(
            frame: pFrame(totalByteCount: 50), isIDR: true, regime: .clean
        )) {
            XCTAssertEqual(
                $0 as? VideoError, .idrFlagMismatch(claimed: true, derived: false)
            )
        }
    }

    func testPacketizerAppliesItsShardBudget() throws {
        var packetizer = VideoPacketizer(shardBudgetByteCount: 1_000)
        let shards = try packetizer.packetize(
            frame: idrFrame(totalByteCount: 1_050),
            frameNumber: FrameNumber(rawValue: 1),
            captureTimestamp: HostTimestamp(microseconds: 0),
            isIDR: true, regime: .clean
        )
        // 1050 B at a 1000 B budget needs k = 2 (at 1112 B it was k = 1).
        let field = try FecField.decode(shards[0].envelope.fec)
        guard case .reedSolomon(_, let geometry) = field else {
            return XCTFail("expected an RS field")
        }
        XCTAssertEqual(geometry.dataShards, 2)
        XCTAssertThrowsError(try FecGeometryTable.geometry(
            forGroupByteCount: 10, regime: .clean, shardBudgetByteCount: 0
        )) {
            XCTAssertEqual($0 as? FecError, .shardBudgetOutOfRange(0))
        }
    }
}
