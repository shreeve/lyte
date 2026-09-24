// The envelope's 8-byte `fec` field (offset 16). As the little-endian u64
// the envelope carries, byte n below is bit range [8n, 8n+8):
//
//   byte  field
//   0     shardIndex   position in the FEC group: 0…k−1 data shards in
//                      group byte order, k…k+m−1 parity shards
//   1     dataShards   k, 1…255
//   2     parityShards m, 0…255−k
//   3     scheme       0x00 none, 0x01 Reed-Solomon GF(2⁸) (nanors
//                      codebook, wire v1); others reject
//   4–6   groupByteCount  u24: total payload bytes across the group's k
//                      data shards — every shard advertises the whole
//                      group's extent, so a single arrival sizes the
//                      assembler's buffers and the unrecoverable test
//   7     reserved     MUST be 0 on send, ignored on receive
//
// Scheme `none` is the all-zero field (byte 7 excepted); a `none` field
// with non-zero geometry bytes is rejected as malformed. The group's
// identity is the envelope `frame` field; this field carries only the
// shard's place within it.

public enum FecField: Hashable, Sendable {
    /// No FEC-coded payload; encodes as fec = 0.
    case none
    /// One RS shard: its index within the group, plus the full group
    /// geometry.
    case reedSolomon(shardIndex: UInt8, geometry: FecGeometry)

    public enum Scheme {
        public static let none: UInt8 = 0x00
        public static let reedSolomon: UInt8 = 0x01
    }

    /// The u64 image the envelope carries at offset 16 (little-endian on
    /// the wire; `Envelope` owns the byte order).
    public var encoded: UInt64 {
        switch self {
        case .none:
            return 0
        case .reedSolomon(let shardIndex, let geometry):
            return UInt64(shardIndex)
                | UInt64(geometry.dataShards) << 8
                | UInt64(geometry.parityShards) << 16
                | UInt64(Scheme.reedSolomon) << 24
                | UInt64(geometry.groupByteCount) << 32
        }
    }

    /// Decodes an envelope's fec u64. Throws on unknown schemes, on
    /// non-zero `none` fields, and on any geometry the block math cannot
    /// honor; never traps. Byte 7 is ignored.
    public static func decode(_ raw: UInt64) throws -> FecField {
        let scheme = UInt8(truncatingIfNeeded: raw >> 24)
        switch scheme {
        case Scheme.none:
            guard raw & 0x00FF_FFFF_FFFF_FFFF == 0 else {
                throw FecError.nonZeroNoneField
            }
            return .none
        case Scheme.reedSolomon:
            let shardIndex = UInt8(truncatingIfNeeded: raw)
            let geometry = try FecGeometry(
                dataShards: Int(UInt8(truncatingIfNeeded: raw >> 8)),
                parityShards: Int(UInt8(truncatingIfNeeded: raw >> 16)),
                groupByteCount: Int((raw >> 32) & 0xFF_FFFF)
            )
            guard Int(shardIndex) < geometry.totalShards else {
                throw FecError.shardIndexOutOfRange(Int(shardIndex))
            }
            return .reedSolomon(shardIndex: shardIndex, geometry: geometry)
        default:
            throw FecError.unknownScheme(scheme)
        }
    }

    /// Builds the field for shard `index` of `geometry`, validating the
    /// index — the encoder-side counterpart of `decode`.
    public static func reedSolomonShard(
        _ index: Int, of geometry: FecGeometry
    ) throws -> FecField {
        guard (0..<geometry.totalShards).contains(index) else {
            throw FecError.shardIndexOutOfRange(index)
        }
        return .reedSolomon(shardIndex: UInt8(index), geometry: geometry)
    }
}
