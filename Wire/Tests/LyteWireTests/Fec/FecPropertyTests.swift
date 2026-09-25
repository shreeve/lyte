import XCTest
import LyteWire
import LyteWireTestKit

// Seeded, deterministic property coverage for the FEC layer — same
// budget philosophy as RoundTripPropertyTests: every trial reproduces
// from its seed on both platforms, counts sized to keep `swift test`
// fast while walking the boundaries every run.

final class FecPropertyTests: XCTestCase {

    /// A group size that genuinely needs k shards under the balanced
    /// split (trailing shard non-empty, bs within `maxShardByteCount`):
    /// picks the floor quotient q and remainder r directly, so the
    /// validity condition r = 0 ∨ q + r ≥ k holds by construction.
    private func validGroupByteCount(
        dataShards k: Int, maxShardByteCount: Int, using rng: inout SplitMix64
    ) -> Int {
        if k == 1 || Bool.random(using: &rng) {
            return k * rng.int(in: 1...maxShardByteCount)
        }
        let q = rng.int(in: 1...(maxShardByteCount - 1))
        let r = rng.int(in: max(1, k - q)...(k - 1))
        return k * q + r
    }

    func testFieldEncodeDecodeIsIdentity() throws {
        var rng = SplitMix64(seed: 0x57_1D_FE_C0)
        for trial in 0..<20_000 {
            let k = rng.int(in: 1...255)
            let m = rng.int(in: 0...(255 - k))
            let bytes = validGroupByteCount(
                dataShards: k,
                maxShardByteCount: WireBudget.maxPlaintextShardByteCount,
                using: &rng
            )
            let geometry = try FecGeometry(
                dataShards: k, parityShards: m, groupByteCount: bytes
            )
            let index = rng.int(in: 0..<geometry.totalShards)
            let field = try FecField.reedSolomonShard(index, of: geometry)
            XCTAssertEqual(
                try FecField.decode(field.encoded), field, "trial \(trial)"
            )
            // Byte 7 stays clear on encode.
            XCTAssertEqual(field.encoded >> 56, 0, "trial \(trial)")
        }
    }

    func testFieldDecodeNeverTrapsOnArbitraryValues() {
        var rng = SplitMix64(seed: 0x57_1D_FE_C1)
        for _ in 0..<50_000 {
            var raw = UInt64.random(in: .min ... .max, using: &rng)
            // Bias half the trials into the valid-scheme space where
            // the geometry validators do real work.
            if Bool.random(using: &rng) {
                raw = (raw & ~(0xFF << 24)) | (1 << 24)
            }
            // Throws or succeeds; must never crash.
            _ = try? FecField.decode(raw)
        }
    }

    func testRandomGeometriesRecoverUpToParityCount() throws {
        var rng = SplitMix64(seed: 0x57_1D_FE_C2)
        for trial in 0..<300 {
            let k = rng.int(in: 1...12)
            let m = rng.int(in: 1...4)
            let bytes = validGroupByteCount(
                dataShards: k, maxShardByteCount: 200, using: &rng
            )
            let geometry = try FecGeometry(
                dataShards: k, parityShards: m, groupByteCount: bytes
            )
            let group = rng.bytes(bytes)
            let shards = try FecEncoder.encode(group: group, geometry: geometry)

            // Erase a random pattern of up to m shards: must recover.
            let erasureCount = rng.int(in: 0...m)
            var slots: [[UInt8]?] = shards
            for index in rng.shuffled(0..<geometry.totalShards).prefix(erasureCount) {
                slots[index] = nil
            }
            XCTAssertEqual(
                try FecDecoder.decode(shards: slots, geometry: geometry),
                group,
                "trial \(trial) k=\(k) m=\(m) bytes=\(bytes)"
            )

            // Erase more data shards than surviving parity: must throw.
            var lossy: [[UInt8]?] = shards
            for index in rng.shuffled(0..<geometry.totalShards).prefix(m + 1) {
                lossy[index] = nil
            }
            if lossy[..<k].contains(where: { $0 == nil }) {
                XCTAssertThrowsError(
                    try FecDecoder.decode(shards: lossy, geometry: geometry),
                    "trial \(trial)"
                ) { error in
                    guard case .unrecoverableGroup? = error as? FecError else {
                        return XCTFail("trial \(trial): unexpected \(error)")
                    }
                }
            }
        }
    }

    func testLadderGeometriesRoundTripThroughFieldAndCoder() throws {
        // The full pipeline at ladder-chosen geometries: pick a group
        // size, take the table's geometry, encode, carry the geometry
        // through the fec field, decode with it after erasures.
        var rng = SplitMix64(seed: 0x57_1D_FE_C3)
        for trial in 0..<60 {
            let bytes = rng.int(in: 1...(20 * 1112))
            let regime: FecRegime = Bool.random(using: &rng) ? .clean : .lossy
            let geometry = try FecGeometryTable.geometry(
                forGroupByteCount: bytes, regime: regime
            )
            let group = rng.bytes(bytes)
            let shards = try FecEncoder.encode(group: group, geometry: geometry)

            // Every shard fits the plaintext budget with its fec field.
            for (index, shard) in shards.enumerated() {
                XCTAssertLessThanOrEqual(
                    shard.count, WireBudget.maxPlaintextShardByteCount
                )
                let field = try FecField.reedSolomonShard(index, of: geometry)
                guard case .reedSolomon(let decodedIndex, let decodedGeometry) =
                    try FecField.decode(field.encoded)
                else {
                    XCTFail("trial \(trial): field lost its scheme")
                    continue
                }
                XCTAssertEqual(Int(decodedIndex), index)
                XCTAssertEqual(decodedGeometry, geometry)
            }

            var slots: [[UInt8]?] = shards
            for index in rng.shuffled(0..<geometry.totalShards).prefix(geometry.parityShards) {
                slots[index] = nil
            }
            XCTAssertEqual(
                try FecDecoder.decode(shards: slots, geometry: geometry),
                group,
                "trial \(trial) bytes=\(bytes) \(regime)"
            )
        }
    }
}
