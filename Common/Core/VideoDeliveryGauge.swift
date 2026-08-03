/// THE GAUGE WINDOW (owner ruling 2026-07-30): every overlay gauge describes
/// the last ~3 seconds — one mental model, no per-stat cleverness. Two
/// physics-imposed exceptions remain documented at their call sites:
/// roundtrip/jitter rides 10 seconds, and input latency rides an event ring.
public let overlayGaugeWindowSeconds = 3.0

/// A trailing-window rate from a monotonically growing counter. Feed the
/// cumulative count at each overlay tick; the answer is anchored at the oldest
/// retained sample in the shared gauge window.
public struct RateMeter: Sendable {
    private var history: [(atMicroseconds: UInt64, count: UInt64)] = []
    private let windowMicroseconds: UInt64

    public init(windowSeconds: Double = overlayGaugeWindowSeconds) {
        windowMicroseconds = UInt64(windowSeconds * 1_000_000)
    }

    public mutating func rate(
        count: UInt64,
        nowMicroseconds: UInt64
    ) -> Double? {
        history.append((nowMicroseconds, count))
        // Evict entries older than the window, but always keep one anchor at
        // (or just beyond) the window's far edge.
        while history.count > 1,
              nowMicroseconds &- history[1].atMicroseconds
                  >= windowMicroseconds {
            history.removeFirst()
        }
        let anchor = history[0]
        let elapsed = nowMicroseconds &- anchor.atMicroseconds
        guard elapsed >= 500_000 else { return nil }
        return Double(count &- anchor.count) / (Double(elapsed) / 1e6)
    }

    public mutating func reset() {
        history.removeAll(keepingCapacity: true)
    }
}

/// Single-threaded accounting policy for the delivery hop. The platform shell
/// owns synchronization; this value owns the one rate window and one rolling
/// hop histogram used to print the glass-side overlay.
public struct VideoDeliveryGauge: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var outFps: Double?
        public var hopP50: Double?
        public var hopP99: Double?

        public init(
            outFps: Double?,
            hopP50: Double?,
            hopP99: Double?
        ) {
            self.outFps = outFps
            self.hopP50 = hopP50
            self.hopP99 = hopP99
        }
    }

    /// A value snapshot copied while the platform shell holds its lock. The
    /// percentile sort happens after unlock, preserving the delivery path's
    /// short critical section.
    public struct Evidence: Sendable {
        fileprivate var outFps: Double?
        fileprivate var hops: Histogram<Double>

        public func snapshot() -> Snapshot {
            let percentiles = hops.percentiles(
                [0.50, 0.99], rank: .upperBoundary)
            return Snapshot(
                outFps: outFps,
                hopP50: percentiles[0],
                hopP99: percentiles[1])
        }
    }

    private var enqueued: UInt64 = 0
    /// ~3 seconds of hop durations at 60 fps — the gauge window.
    private var hops = Histogram<Double>(capacity: 180, retention: .rolling)
    private var outMeter = RateMeter()

    public init() {}

    public mutating func record(hopMilliseconds: Double) {
        enqueued += 1
        hops.record(hopMilliseconds)
    }

    public mutating func reset() {
        enqueued = 0
        hops.removeAll()
        outMeter.reset()
    }

    public mutating func collectEvidence(
        nowMicroseconds: UInt64
    ) -> Evidence {
        let fps = outMeter.rate(
            count: enqueued, nowMicroseconds: nowMicroseconds)
        return Evidence(outFps: fps, hops: hops)
    }

    public mutating func snapshot(
        nowMicroseconds: UInt64
    ) -> Snapshot {
        collectEvidence(nowMicroseconds: nowMicroseconds).snapshot()
    }
}
