// FecEncoder/FecDecoder: the per-frame RS block, sans-IO and deterministic
// (same group + geometry always yields the same parity bytes — the
// fec-v1.json contract). Shards protect payload bytes only, never envelope
// bytes. Groups whose data shards all arrived, and every m = 0 group,
// concatenate without touching the C backend.

public enum FecEncoder {
    /// Splits a group's payload into its k + m wire shards: data shards
    /// are balanced slices of the payload (trailing shard unpadded),
    /// parity shards are `shardByteCount` bytes each. `shards[i]` pairs
    /// with the fec field `FecField.reedSolomonShard(i, of: geometry)`.
    /// Encodes array slices or a synchronously borrowed contiguous group.
    /// Every returned shard owns its bytes; no input view is retained.
    public static func encode<C>(
        group: C, geometry: FecGeometry
    ) throws -> [[UInt8]]
    where C: RandomAccessCollection, C.Element == UInt8, C.Index == Int {
        guard group.count == geometry.groupByteCount else {
            throw FecError.groupByteCountMismatch(
                expected: geometry.groupByteCount, actual: group.count
            )
        }
        let base = group.startIndex
        var shards: [[UInt8]] = (0..<geometry.dataShards).map { index in
            let range = geometry.byteRange(ofDataShard: index)
            return Array(group[(base + range.lowerBound)..<(base + range.upperBound)])
        }
        if geometry.parityShards > 0 {
            shards += try NanorsBackend.encodeParity(
                group: group,
                dataShards: geometry.dataShards,
                parityShards: geometry.parityShards,
                shardByteCount: geometry.shardByteCount
            )
        }
        return shards
    }

    public static func encode(
        group: [UInt8], geometry: FecGeometry
    ) throws -> [[UInt8]] {
        try encode(group: group[...], geometry: geometry)
    }
}

public enum FecDecoder {
    /// Reassembles a group from its surviving shards. `shards` supplies
    /// exactly one slot per shard index (nil = lost), each present shard
    /// at its wire length. Returns the group's payload byte-exact, or
    /// throws `unrecoverableGroup` the moment erasures exceed parity —
    /// never garbage.
    public static func decode(
        shards: [[UInt8]?], geometry: FecGeometry
    ) throws -> [UInt8] {
        guard shards.count == geometry.totalShards else {
            throw FecError.shardSlotCountMismatch(
                expected: geometry.totalShards, actual: shards.count
            )
        }
        for (index, shard) in shards.enumerated() {
            guard let shard else { continue }
            let expected = geometry.wireByteCount(ofShard: index)
            guard shard.count == expected else {
                throw FecError.shardByteCountMismatch(
                    shardIndex: index, expected: expected, actual: shard.count
                )
            }
        }

        let dataSlots = shards[..<geometry.dataShards]
        if dataSlots.allSatisfy({ $0 != nil }) {
            // Every data shard arrived — concatenation, no recovery math.
            var group = [UInt8]()
            group.reserveCapacity(geometry.groupByteCount)
            for shard in dataSlots {
                group.append(contentsOf: shard!)
            }
            return group
        }

        let missingData = dataSlots.count(where: { $0 == nil })
        let presentParity =
            shards[geometry.dataShards...].count(where: { $0 != nil })
        guard missingData <= presentParity else {
            throw FecError.unrecoverableGroup(
                missingDataShards: missingData,
                availableParityShards: presentParity
            )
        }

        return try NanorsBackend.recoverData(
            presentShards: shards,
            dataShards: geometry.dataShards,
            parityShards: geometry.parityShards,
            shardByteCount: geometry.shardByteCount,
            recoveredByteCount: geometry.groupByteCount
        )
    }
}
