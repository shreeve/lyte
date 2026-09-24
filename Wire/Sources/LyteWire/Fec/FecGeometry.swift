// The RS block geometry for one FEC group (one video frame, one audio
// interleave group): k data shards + m parity shards, one block per group.
//
// The split is balanced: bs = ceil(groupByteCount / k); data shard i
// carries group bytes [i·bs, min((i+1)·bs, total)), and every shard must be
// non-empty. Encode-side RS buffers zero-pad the trailing shard to bs; the
// pad never travels. Parity shards are always bs bytes, so they shrink
// with the frame instead of costing a full 1112 B each.

public struct FecGeometry: Hashable, Sendable {
    /// k — data shards in the block, 1…255.
    public let dataShards: Int
    /// m — parity shards, 0…(255 − k). The geometry table never yields
    /// 0, but the mechanism admits it: m = 0 is a plain split with no
    /// protection and no C call.
    public let parityShards: Int
    /// Total payload bytes across the group's data shards,
    /// 1…(k × 1112).
    public let groupByteCount: Int

    public init(dataShards: Int, parityShards: Int, groupByteCount: Int) throws {
        guard (1...255).contains(dataShards) else {
            throw FecError.dataShardsOutOfRange(dataShards)
        }
        guard parityShards >= 0, dataShards + parityShards <= 255 else {
            throw FecError.parityShardsOutOfRange(parityShards)
        }
        let ceiling = dataShards * WireBudget.maxPlaintextShardByteCount
        guard (1...ceiling).contains(groupByteCount) else {
            throw FecError.groupByteCountOutOfRange(groupByteCount)
        }
        self.dataShards = dataShards
        self.parityShards = parityShards
        self.groupByteCount = groupByteCount
        // Balanced split leaves no empty trailing shard only when the
        // bytes actually need k shards at this shard size.
        guard (dataShards - 1) * shardByteCount < groupByteCount else {
            throw FecError.overProvisionedDataShards(
                dataShards: dataShards, groupByteCount: groupByteCount
            )
        }
    }

    /// n — total shards in the block.
    public var totalShards: Int {
        dataShards + parityShards
    }

    /// bs — the RS block's uniform shard size: ceil(group / k), ≤ 1112.
    public var shardByteCount: Int {
        (groupByteCount + dataShards - 1) / dataShards
    }

    /// The trailing data shard's true (wire) length, 1…bs.
    public var lastDataShardByteCount: Int {
        groupByteCount - (dataShards - 1) * shardByteCount
    }

    /// Bytes shard `index` occupies on the wire: bs everywhere except
    /// the trailing data shard, which is never padded in flight.
    public func wireByteCount(ofShard index: Int) -> Int {
        index == dataShards - 1 ? lastDataShardByteCount : shardByteCount
    }

    /// The group's data byte range covered by data shard `index`.
    public func byteRange(ofDataShard index: Int) -> Range<Int> {
        let start = index * shardByteCount
        return start..<min(start + shardByteCount, groupByteCount)
    }

    public func isParityShard(_ index: Int) -> Bool {
        index >= dataShards
    }
}

/// The loss regime selecting a geometry-table column. Choosing the regime
/// is host policy; the ratios live here.
public enum FecRegime: String, CaseIterable, Sendable {
    /// Post-FEC loss < 0.5%.
    case clean
    /// Sustained post-FEC loss beyond 0.5%.
    case lossy
}

/// The adaptive parity ladder as data: frame-size bucket (in data shards)
/// → parity rule per regime. Small frames are cheap to overprotect; large
/// frames buy single-loss immunity and lean on NACK.
///
/// One GF(2⁸) block holds at most 255 shards, so the 33…255 bucket is
/// capped: clean protects up to k = 231, lossy up to k = 204. Beyond that
/// `parityShards(forDataShards:regime:)` throws rather than clamps;
/// `frameByteCeiling` (from `maxDataShards(_:)`) keeps frames below it.
public enum FecGeometryTable {
    /// How a bucket computes parity from k.
    public enum ParityRule: Hashable, Sendable {
        /// A fixed shard count.
        case shards(Int)
        /// ceil(k × percent / 100).
        case percentCeil(Int)

        public func parityShards(forDataShards k: Int) -> Int {
            switch self {
            case .shards(let m): return m
            case .percentCeil(let percent): return (k * percent + 99) / 100
            }
        }
    }

    /// One frame-size bucket of the ladder.
    public struct Bucket: Hashable, Sendable {
        public let dataShards: ClosedRange<Int>
        public let clean: ParityRule
        public let lossy: ParityRule

        public func rule(for regime: FecRegime) -> ParityRule {
            regime == .clean ? clean : lossy
        }
    }

    public static let buckets: [Bucket] = [
        Bucket(dataShards: 1...2, clean: .shards(1), lossy: .shards(2)),
        Bucket(dataShards: 3...8, clean: .shards(2), lossy: .percentCeil(50)),
        Bucket(dataShards: 9...32, clean: .percentCeil(15), lossy: .percentCeil(35)),
        Bucket(dataShards: 33...255, clean: .percentCeil(10), lossy: .percentCeil(25)),
    ]

    /// The ladder's parity count for a k-data-shard frame. Throws
    /// `unprotectableDataShardCount` when k is outside 1…255 or the
    /// ladder's ratio would burst the 255-shard block.
    public static func parityShards(
        forDataShards k: Int, regime: FecRegime
    ) throws -> Int {
        guard let bucket = buckets.first(where: { $0.dataShards.contains(k) }) else {
            throw FecError.unprotectableDataShardCount(k)
        }
        let m = bucket.rule(for: regime).parityShards(forDataShards: k)
        guard k + m <= 255 else {
            throw FecError.unprotectableDataShardCount(k)
        }
        return m
    }

    /// The largest data shard count the ladder can protect in one block:
    /// 231 clean, 204 lossy. `frameByteCeiling` derives from this.
    public static func maxDataShards(_ regime: FecRegime) -> Int {
        for k in stride(from: 255, through: 1, by: -1) {
            if (try? parityShards(forDataShards: k, regime: regime)) != nil {
                return k
            }
        }
        return 0 // unreachable: k = 1 always protects
    }

    /// The ladder's geometry for a group of `byteCount` payload bytes at
    /// minimal k: shards filled to `shardBudgetByteCount` (the 1112 B
    /// plaintext ceiling unless the carrier reserves envelope TLV
    /// headroom), balanced split.
    public static func geometry(
        forGroupByteCount byteCount: Int, regime: FecRegime,
        shardBudgetByteCount budget: Int = WireBudget.maxPlaintextShardByteCount
    ) throws -> FecGeometry {
        guard byteCount >= 1 else {
            throw FecError.groupByteCountOutOfRange(byteCount)
        }
        guard (1...WireBudget.maxPlaintextShardByteCount).contains(budget) else {
            throw FecError.shardBudgetOutOfRange(budget)
        }
        let k = (byteCount + budget - 1) / budget
        let m = try parityShards(forDataShards: k, regime: regime)
        return try FecGeometry(
            dataShards: k, parityShards: m, groupByteCount: byteCount
        )
    }
}
