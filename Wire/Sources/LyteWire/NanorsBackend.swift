// The one file in LyteWire that imports the C leaf. FecEncoder/FecDecoder
// speak only to this surface — two pure functions over byte arrays — so
// the WASM build can swap in a different RS backend without touching
// protocol logic, the same confinement rule Crypto/ will follow at W5.
//
// nanors is the client's battle-tested RS-FEC math (M3: 1,087 packets
// recovered over a 5% drop soak), vendored here as CNanorsWire. The call
// shape mirrors the proven RtpVideoQueue usage: one contiguous zeroed
// backing buffer, one pointer per shard row, marks[] flagging erasures.

import CNanorsWire

enum NanorsBackend {
    /// Computes m parity rows of `shardByteCount` bytes over the group
    /// laid out as k contiguous rows (the trailing row zero-padded —
    /// which is exactly what copying the group bytes into a zeroed
    /// k·bs region produces, since data shards are contiguous slices).
    static func encodeParity(
        group: ArraySlice<UInt8>,
        dataShards: Int,
        parityShards: Int,
        shardByteCount bs: Int
    ) throws -> [[UInt8]] {
        let total = dataShards + parityShards
        let backing = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: total * bs)
        defer { backing.deallocate() }
        backing.initialize(repeating: 0)
        group.withUnsafeBufferPointer { src in
            backing.baseAddress!.update(from: src.baseAddress!, count: src.count)
        }

        try runBlock(
            backing: backing, dataShards: dataShards,
            parityShards: parityShards, shardByteCount: bs, marks: nil
        )
        return (0..<parityShards).map { j in
            let row = backing.baseAddress! + (dataShards + j) * bs
            return Array(UnsafeBufferPointer(start: row, count: bs))
        }
    }

    /// Reconstructs the k data rows from any ≥ k surviving shards.
    /// `presentShards[i]` is shard i's wire bytes (shorter rows are
    /// zero-padded into the block) or nil where lost. Copies exactly
    /// `recoveredByteCount` reconstructed data bytes into the returned
    /// array; no view of the larger RS backing escapes this call.
    static func recoverData(
        presentShards: [[UInt8]?],
        dataShards: Int,
        parityShards: Int,
        shardByteCount bs: Int,
        recoveredByteCount: Int
    ) throws -> [UInt8] {
        let total = dataShards + parityShards
        let backing = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: total * bs)
        defer { backing.deallocate() }
        backing.initialize(repeating: 0)
        for (index, shard) in presentShards.enumerated() {
            guard let shard, !shard.isEmpty else { continue }
            shard.withUnsafeBufferPointer { src in
                (backing.baseAddress! + index * bs)
                    .update(from: src.baseAddress!, count: src.count)
            }
        }

        try runBlock(
            backing: backing, dataShards: dataShards,
            parityShards: parityShards, shardByteCount: bs,
            marks: presentShards.map { $0 == nil ? 1 : 0 }
        )
        return Array(
            UnsafeBufferPointer(
                start: backing.baseAddress!, count: recoveredByteCount
            )
        )
    }

    /// Allocates the RS context, points one row pointer per shard into
    /// the backing, and runs encode (marks == nil) or decode.
    private static func runBlock(
        backing: UnsafeMutableBufferPointer<UInt8>,
        dataShards: Int,
        parityShards: Int,
        shardByteCount bs: Int,
        marks: [UInt8]?
    ) throws {
        let total = dataShards + parityShards
        guard let rs = reed_solomon_new(Int32(dataShards), Int32(parityShards))
        else {
            throw FecError.backendFailure(code: -1)
        }
        defer { reed_solomon_release(rs) }

        var rows: [UnsafeMutablePointer<UInt8>?] = (0..<total).map {
            backing.baseAddress! + $0 * bs
        }
        let code = rows.withUnsafeMutableBufferPointer { rowPtrs in
            if var markBytes = marks {
                return markBytes.withUnsafeMutableBufferPointer { markPtrs in
                    reed_solomon_decode(
                        rs, rowPtrs.baseAddress, markPtrs.baseAddress,
                        Int32(total), Int32(bs)
                    )
                }
            }
            return reed_solomon_encode(rs, rowPtrs.baseAddress, Int32(total), Int32(bs))
        }
        guard code == 0 else {
            throw FecError.backendFailure(code: code)
        }
    }
}
