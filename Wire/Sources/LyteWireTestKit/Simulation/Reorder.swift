// Displacement-bounded reorder for network simulation: real links
// reorder by a few packets (the resiliency plan's G4 gate models 2–4),
// not by whole frames, and the assembler's QUIC-shaped loss presumption
// (packet-threshold 3) is calibrated for exactly that. Tests asserting
// presumption precision use this; tests asserting byte-exact recovery
// may still shuffle without bound, because recovery is order-blind.

public enum Reorder {
    /// Reorders `items` so no element moves more than `maxDisplacement`
    /// positions from where it started: stable-sort by index plus a
    /// random jitter of at most `maxDisplacement`.
    public static func bounded<T>(
        _ items: [T], maxDisplacement: Int, using rng: inout SplitMix64
    ) -> [T] {
        items.enumerated()
            .map { (key: $0.offset + Int.random(in: 0...maxDisplacement, using: &rng),
                    tie: $0.offset, element: $0.element) }
            .sorted { ($0.key, $0.tie) < ($1.key, $1.tie) }
            .map(\.element)
    }
}
