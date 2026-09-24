// Displacement-bounded reorder: real links reorder by a few packets, not
// whole frames, which is what the assembler's packet-threshold-3 loss
// presumption is calibrated for. Byte-exact recovery tests may still
// shuffle without bound, because recovery is order-blind.

public enum Reorder {
    /// Reorders `items` so no element moves more than `maxDisplacement`
    /// positions from where it started: stable-sort by index plus a
    /// random jitter of at most `maxDisplacement`. A seed yields the
    /// same order on every platform (vector builders freeze it).
    public static func bounded<T>(
        _ items: [T], maxDisplacement: Int, using rng: inout SplitMix64
    ) -> [T] {
        items.enumerated()
            .map { (key: $0.offset + rng.int(in: 0...maxDisplacement),
                    tie: $0.offset, element: $0.element) }
            .sorted { ($0.key, $0.tie) < ($1.key, $1.tie) }
            .map(\.element)
    }
}
