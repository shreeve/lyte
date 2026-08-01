// FecEncoder/FecDecoder: the per-frame RS block of resiliency §1.1, sans-IO.
// Bytes in, shards out — deterministic (same group + geometry always yields
// the same parity bytes, which is what makes the fec-v1.json matrices a
// cross-platform contract), no clocks, no state. Shards protect payload
// bytes only, never envelope bytes (core plan §2): Sunshine's
// rebuilt-parity-header garbage-patch hack stays deleted.
//
// The C leaf is confined to NanorsBackend and only touched when recovery
// math is genuinely needed: groups whose data shards all arrived — and
// every m = 0 group — concatenate without a C call, so the common
// no-loss frame and the tiny single-shard frame stay cheap.

public enum FecEncoder {
    /// Splits a group's payload into its k + m wire shards: data shards
    /// are balanced slices of the payload (trailing shard unpadded),
    /// parity shards are `shardByteCount` bytes each. `shards[i]` pairs
    /// with the fec field `FecField.reedSolomonShard(i, of: geometry)`.
    public static func encode(
        group: ArraySlice<UInt8>, geometry: FecGeometry
    ) throws -> [[UInt8]] {
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
    /// honest failure, never garbage (resiliency §1.1 rule 2: the
    /// geometry tells us immediately, no timer).
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
