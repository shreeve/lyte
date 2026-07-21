// Everything the FEC layer can refuse. Same doctrine as WireError: hostile
// bytes and impossible requests throw — never trap, never return garbage.
// `unrecoverableGroup` in particular is the honest-failure contract of
// resiliency §1.1: when erasures exceed parity the decoder reports exactly
// that, so the client's NACK/IDR decision is immediate.

public enum FecError: Error, Equatable, Sendable {
    /// The fec field's scheme byte names no known scheme.
    case unknownScheme(UInt8)
    /// Scheme `none` with non-zero geometry bytes: the canonical none
    /// field is all-zero (byte 7 excepted; it is reserved everywhere).
    case nonZeroNoneField
    /// Data shard count outside 1…255.
    case dataShardsOutOfRange(Int)
    /// Parity shard count negative, or data + parity over the GF(2⁸)
    /// block limit of 255 total shards.
    case parityShardsOutOfRange(Int)
    /// Group byte count outside 1…(dataShards × 1112).
    case groupByteCountOutOfRange(Int)
    /// More data shards than the group's bytes can fill: the balanced
    /// split would leave the trailing shard empty.
    case overProvisionedDataShards(dataShards: Int, groupByteCount: Int)
    /// Shard index at or beyond dataShards + parityShards.
    case shardIndexOutOfRange(Int)
    /// The geometry table has no ladder ratio for this data shard count
    /// that fits the 255-shard block limit (see FecGeometryTable).
    case unprotectableDataShardCount(Int)
    /// Encoder input length disagrees with the geometry's group size.
    case groupByteCountMismatch(expected: Int, actual: Int)
    /// Decoder input must supply exactly one slot per shard, nil = lost.
    case shardSlotCountMismatch(expected: Int, actual: Int)
    /// A received shard's length disagrees with the geometry's wire
    /// length for that index.
    case shardByteCountMismatch(shardIndex: Int, expected: Int, actual: Int)
    /// Missing data shards exceed available parity shards — reported
    /// before any recovery math runs, never as corrupt output.
    case unrecoverableGroup(missingDataShards: Int, availableParityShards: Int)
    /// The RS backend rejected a call the geometry said was valid; the
    /// code is the C return value (or -1 for an allocation failure).
    case backendFailure(code: Int32)
}
