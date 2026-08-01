// Histogram (host plan §5 telemetry): p50/p95/p99 + count/min/max over
// recorded samples. The plan's rule is that instrumentation lands with
// the slice that creates each edge — HS-13 creates the input
// receive→inject edge and its p99 < 2 ms gate, so the aggregator lands
// here and later edges (pacer queue delay, frame wire-drain, audio
// inter-send) reuse it.
//
// Deliberately simple, pure Swift, no clocks: exact percentiles over
// retained samples, capped so a runaway producer cannot grow memory
// without bound (samples past the cap still count and still update
// min/max — the percentile just reports over the retained prefix, and
// `saturated` says so).

public struct Histogram: Sendable {
    public private(set) var count = 0
    public private(set) var minValue: UInt64?
    public private(set) var maxValue: UInt64?
    /// True once samples beyond the retention cap were dropped from the
    /// percentile pool (count/min/max stay exact).
    public private(set) var saturated = false

    private var samples: [UInt64] = []
    private let capacity: Int

    public init(capacity: Int = 1 << 16) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public mutating func record(_ value: UInt64) {
        count += 1
        minValue = minValue.map { Swift.min($0, value) } ?? value
        maxValue = maxValue.map { Swift.max($0, value) } ?? value
        if samples.count < capacity {
            samples.append(value)
        } else {
            saturated = true
        }
    }

    /// The exact q-quantile (0...1) over the retained samples by the
    /// nearest-rank method; nil when nothing was recorded.
    public func percentile(_ q: Double) -> UInt64? {
        guard !samples.isEmpty else { return nil }
        let clamped = Swift.min(Swift.max(q, 0), 1)
        let rank = Int((clamped * Double(samples.count)).rounded(.up))
        let target = Swift.max(rank, 1) - 1
        var work = samples
        var low = 0
        var high = work.count - 1
        while low < high {
            let pivot = work[(low + high) / 2]
            var i = low
            var j = high
            while i <= j {
                while work[i] < pivot { i += 1 }
                while work[j] > pivot { j -= 1 }
                if i <= j {
                    work.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if target <= j {
                high = j
            } else if target >= i {
                low = i
            } else {
                break
            }
        }
        return work[target]
    }

    public var p50: UInt64? { percentile(0.50) }
    public var p95: UInt64? { percentile(0.95) }
    public var p99: UInt64? { percentile(0.99) }
}
