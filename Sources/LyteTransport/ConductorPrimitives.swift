// THE CONDUCTOR's shared primitives (tier 2 of the standardization,
// docs/20260803-050422-metronome-playout-design.md): the law-machinery
// that is LITERALLY IDENTICAL across instruments lives here, spelled
// once. Instruments keep their own verbs and constants — and their
// doctrine: audio's clock of record is the DAC (never HostClockModel;
// the ear forgives slow drift, never a click) and audio sizes its
// cushion from the detrended window SPREAD, not a percentile (the
// former p99 discarded exactly the late/PLC events — a measured fix,
// not drift). Those asymmetries are decisions of record; nothing in
// this file may flatten them.
//
//   BeatTailRing     — bounded ring of recent delays + nearest-rank
//                      tail: the cue's evidence (video's path-delay
//                      p99; any future instrument's tail).
//   ProofCounter     — the proof-before-shed law: cushion is easy to
//                      raise and slow to hand back; evidence must
//                      accumulate before one scheduled give-back
//                      (video's slip proof, audio's decay hold/step,
//                      audio's retarget cadence).
//   LatencyHistogram — the books' exact-percentile aggregator (moved
//                      from InputSender.swift, its accidental home;
//                      byte-for-byte the shape of HostCore.Histogram,
//                      which the root package cannot import).

/// Bounded ring of the most recent samples with a nearest-rank tail —
/// the Conductor's tail estimator. Rolling: once full, new samples
/// evict the oldest; the tail always describes the newest window.
public struct BeatTailRing: Sendable {
    private var samples: [UInt64] = []
    private var next = 0
    private let capacity: Int

    public init(capacity: Int = 600) {
        precondition(capacity > 0)
        self.capacity = capacity
        samples.reserveCapacity(capacity)
    }

    public var isEmpty: Bool { samples.isEmpty }

    public mutating func note(_ value: UInt64) {
        if samples.count < capacity {
            samples.append(value)
        } else {
            samples[next] = value
            next = (next + 1) % capacity
        }
    }

    public mutating func removeAll() {
        samples.removeAll(keepingCapacity: true)
        next = 0
    }

    /// Nearest-rank upper tail over the retained window; 0 when empty
    /// (no evidence claims no delay).
    public func tail(percentile: Int = 99) -> UInt64 {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = min(
            sorted.count - 1,
            (sorted.count * percentile + 99) / 100 - 1)
        return sorted[max(index, 0)]
    }
}

/// The proof-before-shed law's counter: evidence accumulates one
/// sample at a time, any contrary event resets it, and the shed may
/// fire only once the threshold is reached. Cushion rises free and
/// is handed back only against sustained proof — one scheduled move
/// per proof, never a smear.
public struct ProofCounter: Sendable, Equatable {
    public private(set) var count = 0

    public init() {}

    public mutating func advance() { count += 1 }

    public mutating func reset() { count = 0 }

    public func reached(_ threshold: Int) -> Bool {
        count >= threshold
    }
}

/// Exact-percentile latency aggregator — the byte-for-byte shape of
/// HostCore.Histogram (HS-13's edge instrumentation; the root package
/// cannot import HostCore, and the aggregator is ~40 lines of pure
/// Swift). Capped so a runaway producer cannot grow memory without
/// bound: samples past the cap still count and still update min/max,
/// `saturated` says the percentile pool is a prefix.
public struct LatencyHistogram: Sendable {
    public private(set) var count = 0
    public private(set) var minValue: UInt64?
    public private(set) var maxValue: UInt64?
    /// True once the ring has wrapped: percentiles now describe the
    /// most RECENT `capacity` samples, not the whole session.
    public private(set) var saturated = false

    private var samples: [UInt64] = []
    private var writeIndex = 0
    private let capacity: Int

    /// A ROLLING window (owner ruling 2026-07-30): the pre-ring shape
    /// kept the session's FIRST `capacity` samples and froze — an
    /// overlay gauge that described the opening minute forever. The
    /// ring keeps the newest; `count`/`minValue`/`maxValue` stay
    /// session-cumulative (they are odometers, not gauges).
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
            samples[writeIndex] = value
            saturated = true
        }
        writeIndex = (writeIndex + 1) % capacity
    }

    /// The exact q-quantile (0...1) over the retained samples by the
    /// nearest-rank method; nil when nothing was recorded.
    public func percentile(_ q: Double) -> UInt64? {
        percentiles([q])[0]
    }

    /// Every requested quantile from ONE sort of the retained ring —
    /// the overlay asks for p50 and p99 together, and each bare
    /// `percentile` call re-sorted the whole ring (up to 65,536
    /// elements, twice per overlay tick).
    public func percentiles(_ qs: [Double]) -> [UInt64?] {
        guard !samples.isEmpty else { return qs.map { _ in nil } }
        let sorted = samples.sorted()
        return qs.map { q in
            let clamped = Swift.min(Swift.max(q, 0), 1)
            let rank = Int((clamped * Double(sorted.count)).rounded(.up))
            return sorted[Swift.max(rank, 1) - 1]
        }
    }

    public var p50: UInt64? { percentile(0.50) }
    public var p95: UInt64? { percentile(0.95) }
    public var p99: UInt64? { percentile(0.99) }
}
