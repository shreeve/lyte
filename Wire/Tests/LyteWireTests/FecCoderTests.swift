import XCTest
import LyteWire
import LyteWireTestKit

// The RS block mechanics against the C leaf: sweeps prove every loss
// pattern up to parity count recovers byte-exact and every pattern
// beyond it fails honestly (W-G2's requirement for small k), and the
// k=1,m=1 identity case anchors the parity bytes by eye.

final class FecCoderTests: XCTestCase {

    private func counting(from offset: Int, count: Int) -> [UInt8] {
        (0..<count).map { UInt8((offset + $0) & 0xFF) }
    }

    /// Erases the given indices and decodes.
    private func decodeErasing(
        _ erased: Set<Int>, from shards: [[UInt8]], geometry: FecGeometry
    ) throws -> [UInt8] {
        var slots: [[UInt8]?] = shards
        for index in erased { slots[index] = nil }
        return try FecDecoder.decode(shards: slots, geometry: geometry)
    }

    func testEncodeShapesAndDeterminism() throws {
        let geometry = try FecGeometry(
            dataShards: 5, parityShards: 2, groupByteCount: 53
        )
        let group = counting(from: 0x80, count: 53)
        let shards = try FecEncoder.encode(group: group, geometry: geometry)

        XCTAssertEqual(shards.count, 7)
        XCTAssertEqual(shards.map(\.count), [11, 11, 11, 11, 9, 11, 11])
        // Data shards are the group's bytes, unpadded on the wire.
        XCTAssertEqual(shards[0], Array(group[0..<11]))
        XCTAssertEqual(shards[4], Array(group[44..<53]))
        // Deterministic: same input, same parity bytes.
        XCTAssertEqual(try FecEncoder.encode(group: group, geometry: geometry), shards)
    }

    func testK1M1ParityIsIdentity() throws {
        // nanors' codebook row for k=1, m=1 is the multiplicative
        // identity: the parity shard is a byte-copy of the data shard.
        // This is the hand-checkable anchor behind every parity byte in
        // fec-v1.json.
        let geometry = try FecGeometry(
            dataShards: 1, parityShards: 1, groupByteCount: 5
        )
        let group = Array("lyte!".utf8)
        let shards = try FecEncoder.encode(group: group, geometry: geometry)
        XCTAssertEqual(shards, [group, group])
    }

    func testSingleAndDoubleErasureSweeps() throws {
        // k=4 m=2 over 53 B — bs=14, trailing data shard 11 B, so the
        // sweep also crosses the padding path. Every single and every
        // double erasure among the 6 shards must recover byte-exact.
        let geometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 53
        )
        let group = counting(from: 0x10, count: 53)
        let shards = try FecEncoder.encode(group: group, geometry: geometry)

        for a in 0..<6 {
            XCTAssertEqual(
                try decodeErasing([a], from: shards, geometry: geometry),
                group,
                "single erasure \(a)"
            )
            for b in (a + 1)..<6 {
                XCTAssertEqual(
                    try decodeErasing([a, b], from: shards, geometry: geometry),
                    group,
                    "double erasure \(a),\(b)"
                )
            }
        }
    }

    func testEveryTripleErasureFailsHonestly() throws {
        // Three erasures leave 3 < k shards: every one of the 20
        // patterns must report unrecoverableGroup — never garbage.
        let geometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 53
        )
        let shards = try FecEncoder.encode(
            group: counting(from: 0x10, count: 53), geometry: geometry
        )
        for a in 0..<6 {
            for b in (a + 1)..<6 {
                for c in (b + 1)..<6 {
                    XCTAssertThrowsError(
                        try decodeErasing([a, b, c], from: shards, geometry: geometry),
                        "triple \(a),\(b),\(c)"
                    ) { error in
                        guard case .unrecoverableGroup(let missing, let parity)?
                            = error as? FecError
                        else {
                            return XCTFail("unexpected \(error)")
                        }
                        XCTAssertGreaterThan(missing, parity)
                    }
                }
            }
        }
    }

    func testSingleShardGroupPassesThroughCheaply() throws {
        // k=1: the group is its own only data shard, decode with it
        // present is a plain copy (no C call on either fast path).
        let geometry = try FecGeometry(
            dataShards: 1, parityShards: 2, groupByteCount: 300
        )
        let group = counting(from: 3, count: 300)
        let shards = try FecEncoder.encode(group: group, geometry: geometry)
        XCTAssertEqual(shards[0], group)
        XCTAssertEqual(
            try decodeErasing([1, 2], from: shards, geometry: geometry), group
        )
        // And both parity shards can each resurrect it alone.
        XCTAssertEqual(
            try decodeErasing([0, 1], from: shards, geometry: geometry), group
        )
        XCTAssertEqual(
            try decodeErasing([0, 2], from: shards, geometry: geometry), group
        )
    }

    func testParityFreeGeometry() throws {
        // m=0 is mechanism-legal: a bare split. All-present decodes;
        // any loss is immediately unrecoverable with zero parity.
        let geometry = try FecGeometry(
            dataShards: 3, parityShards: 0, groupByteCount: 100
        )
        let group = counting(from: 0x40, count: 100)
        let shards = try FecEncoder.encode(group: group, geometry: geometry)
        XCTAssertEqual(shards.count, 3)
        XCTAssertEqual(
            try decodeErasing([], from: shards, geometry: geometry), group
        )
        XCTAssertThrowsError(
            try decodeErasing([1], from: shards, geometry: geometry)
        ) {
            XCTAssertEqual(
                $0 as? FecError,
                .unrecoverableGroup(missingDataShards: 1, availableParityShards: 0)
            )
        }
    }

    func testFullBudgetShards() throws {
        // k shards of exactly 1112 B — the §4.2 budget interaction.
        let geometry = try FecGeometry(
            dataShards: 6, parityShards: 2, groupByteCount: 6 * 1112
        )
        let group = counting(from: 0, count: 6 * 1112)
        let shards = try FecEncoder.encode(group: group, geometry: geometry)
        XCTAssertTrue(shards.allSatisfy { $0.count == 1112 })
        XCTAssertEqual(
            try decodeErasing([0, 5], from: shards, geometry: geometry), group
        )
    }

    func testInputValidation() throws {
        let geometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 48
        )
        let group = counting(from: 0, count: 48)
        let shards = try FecEncoder.encode(group: group, geometry: geometry)

        // Encoder: group length must match the geometry.
        XCTAssertThrowsError(
            try FecEncoder.encode(group: counting(from: 0, count: 47), geometry: geometry)
        ) {
            XCTAssertEqual(
                $0 as? FecError, .groupByteCountMismatch(expected: 48, actual: 47)
            )
        }

        // Decoder: one slot per shard.
        XCTAssertThrowsError(
            try FecDecoder.decode(shards: Array(shards.prefix(5)), geometry: geometry)
        ) {
            XCTAssertEqual(
                $0 as? FecError, .shardSlotCountMismatch(expected: 6, actual: 5)
            )
        }

        // Decoder: wire lengths are contract.
        var wrongLength: [[UInt8]?] = shards
        wrongLength[1] = counting(from: 0, count: 11)
        XCTAssertThrowsError(
            try FecDecoder.decode(shards: wrongLength, geometry: geometry)
        ) {
            XCTAssertEqual(
                $0 as? FecError,
                .shardByteCountMismatch(shardIndex: 1, expected: 12, actual: 11)
            )
        }
    }

    func testRecoveredBytesNeverIncludePadding() throws {
        // Trailing shard is 1 B on the wire (bs=2, len=7, k=4); losing
        // and recovering it must return exactly 7 bytes.
        let geometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 7
        )
        let group: [UInt8] = [1, 2, 3, 4, 5, 6, 7]
        let shards = try FecEncoder.encode(group: group, geometry: geometry)
        XCTAssertEqual(shards[3], [7])
        XCTAssertEqual(
            try decodeErasing([3], from: shards, geometry: geometry), group
        )
        XCTAssertEqual(
            try decodeErasing([2, 3], from: shards, geometry: geometry), group
        )
    }

    func testRecoveredOutputIsExactAndIndependentOfShardStorage() throws {
        let geometry = try FecGeometry(
            dataShards: 7, parityShards: 3, groupByteCount: 7_003
        )
        let group = counting(from: 0xA5, count: geometry.groupByteCount)
        let encoded = try FecEncoder.encode(group: group, geometry: geometry)
        var slots: [[UInt8]?] = encoded
        slots[0] = nil
        slots[3] = nil
        slots[6] = nil

        let recovered = try FecDecoder.decode(shards: slots, geometry: geometry)
        XCTAssertEqual(recovered.count, geometry.groupByteCount)
        XCTAssertEqual(recovered, group)

        // The result owns its logical payload; neither the RS block's
        // padding nor the caller's shard arrays are retained as a slice.
        slots = Array(repeating: nil, count: geometry.totalShards)
        XCTAssertEqual(recovered, group)
    }

    func testBorrowedEncodeOwnsEveryReturnedShard() throws {
        let geometry = try FecGeometry(
            dataShards: 7, parityShards: 3, groupByteCount: 7_003
        )
        let original = counting(from: 0x3C, count: geometry.groupByteCount)
        let pointer = UnsafeMutableBufferPointer<UInt8>.allocate(
            capacity: original.count
        )
        _ = pointer.initialize(from: original)
        let encoded = try FecEncoder.encode(
            group: UnsafeBufferPointer(pointer), geometry: geometry
        )

        pointer.update(repeating: 0xEE)
        pointer.deallocate()

        XCTAssertEqual(
            try FecDecoder.decode(
                shards: encoded.map(Optional.some), geometry: geometry
            ),
            original,
            "encoded shards must not retain the borrowed group"
        )
    }
}
