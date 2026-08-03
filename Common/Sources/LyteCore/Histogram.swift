/// How a bounded histogram retains samples after reaching capacity.
public enum HistogramRetention: Sendable, Equatable {
    /// Keep the first `capacity` samples and drop later samples from the
    /// percentile pool. Count, minimum, and maximum remain cumulative.
    case prefix
    /// Keep the most recent `capacity` samples by replacing the oldest.
    /// Count, minimum, and maximum remain cumulative.
    case rolling
}

/// The rank convention used to select a percentile from sorted samples.
public enum PercentileRank: Sendable {
    /// The conventional nearest-rank index: `ceil(q * count) - 1`.
    case nearest
    /// Promote exact boundaries to the next sample: `floor(q * count)`.
    /// This preserves the delivery gauge's established boundary behavior.
    case upperBoundary
}

/// A bounded, exact-percentile histogram with explicit retention doctrine.
///
/// The sample pool is bounded, while `count`, `minValue`, and `maxValue`
/// describe the whole recording lifetime. `saturated` distinguishes a pool
/// that has reached its retention boundary from one that still contains every
/// sample recorded.
public struct Histogram<Value: Comparable & Sendable>: Sendable {
    public private(set) var count = 0
    public private(set) var minValue: Value?
    public private(set) var maxValue: Value?
    public private(set) var saturated = false

    private var samples: [Value] = []
    private var writeIndex = 0
    private let capacity: Int
    private let retention: HistogramRetention

    public init(
        capacity: Int = 1 << 16,
        retention: HistogramRetention = .prefix
    ) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.retention = retention
        samples.reserveCapacity(capacity)
    }

    public var isEmpty: Bool { samples.isEmpty }

    public mutating func record(_ value: Value) {
        count += 1
        minValue = minValue.map { Swift.min($0, value) } ?? value
        maxValue = maxValue.map { Swift.max($0, value) } ?? value

        if samples.count < capacity {
            samples.append(value)
        } else {
            saturated = true
            if retention == .rolling {
                samples[writeIndex] = value
            }
        }
        writeIndex = (writeIndex + 1) % capacity
    }

    /// Reset both the retained pool and the cumulative books.
    public mutating func removeAll() {
        samples.removeAll(keepingCapacity: true)
        writeIndex = 0
        count = 0
        minValue = nil
        maxValue = nil
        saturated = false
    }

    public func percentile(
        _ q: Double,
        rank: PercentileRank = .nearest
    ) -> Value? {
        Self.percentile(of: samples, q, rank: rank)
    }

    /// Answer several percentiles from one ordering of the retained pool.
    public func percentiles(
        _ qs: [Double],
        rank: PercentileRank = .nearest
    ) -> [Value?] {
        guard !samples.isEmpty else { return qs.map { _ in nil } }
        let sorted = samples.sorted()
        return qs.map { q in
            sorted[Self.index(for: q, count: sorted.count, rank: rank)]
        }
    }

    /// Apply the same percentile contract to an already-owned sample set.
    /// This lets records with several measured fields share the ordering law
    /// without allocating a second persistent histogram for every field.
    public static func percentile(
        of values: [Value],
        _ q: Double,
        rank: PercentileRank = .nearest
    ) -> Value? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[index(for: q, count: sorted.count, rank: rank)]
    }

    public var p50: Value? { percentile(0.50) }
    public var p95: Value? { percentile(0.95) }
    public var p99: Value? { percentile(0.99) }

    private static func index(
        for q: Double,
        count: Int,
        rank: PercentileRank
    ) -> Int {
        let clamped = Swift.min(Swift.max(q, 0), 1)
        switch rank {
        case .nearest:
            let nearest = Int((clamped * Double(count)).rounded(.up)) - 1
            return Swift.min(count - 1, Swift.max(0, nearest))
        case .upperBoundary:
            let upper = Int((clamped * Double(count)).rounded(.down))
            return Swift.min(count - 1, Swift.max(0, upper))
        }
    }
}
