/// Pure helpers for deterministic cadence and recovery assertions. Times are
/// caller-owned virtual microseconds; no wall clock or Foundation machinery
/// enters these calculations.
public enum CadenceSLO {
    /// Nearest-rank percentile (p in 0...1), deterministic for small samples.
    public static func percentile<T: Comparable>(
        _ values: [T], p: Double
    ) -> T? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = max(0, min(p, 1))
        let rank = max(1, Int((clamped * Double(sorted.count)).rounded(.up)))
        return sorted[rank - 1]
    }

    /// Positive inter-arrival gaps in input order. Reordered/equal timestamps
    /// contribute zero rather than underflowing.
    public static func interArrivalGaps(
        _ arrivalMicroseconds: [UInt64]
    ) -> [UInt64] {
        guard arrivalMicroseconds.count > 1 else { return [] }
        return zip(arrivalMicroseconds, arrivalMicroseconds.dropFirst()).map {
            $1 >= $0 ? $1 - $0 : 0
        }
    }

    /// Gaps strictly exceeding the caller's stall threshold.
    public static func stalls(
        _ arrivalMicroseconds: [UInt64],
        exceeding thresholdMicroseconds: UInt64
    ) -> [UInt64] {
        interArrivalGaps(arrivalMicroseconds).filter {
            $0 > thresholdMicroseconds
        }
    }

    /// Delay from an impairment boundary to the first observation at or
    /// after it, or nil when recovery was not observed.
    public static func recoveryDelay(
        after boundaryMicroseconds: UInt64,
        observations: [UInt64]
    ) -> UInt64? {
        observations
            .filter { $0 >= boundaryMicroseconds }
            .min()
            .map { $0 - boundaryMicroseconds }
    }

    public static func queueStayedBounded(
        _ queuedByteCounts: [Int], limit: Int
    ) -> Bool {
        queuedByteCounts.allSatisfy { $0 >= 0 && $0 <= limit }
    }
}
