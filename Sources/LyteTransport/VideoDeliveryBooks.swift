import Foundation

/// THE GAUGE WINDOW (owner ruling 2026-07-30): every overlay gauge
/// describes the last ~3 seconds — one mental model, no per-stat
/// cleverness. Two physics-imposed exceptions, both documented at
/// their sites: roundtrip/jitter (1 Hz beacons — 3 s holds 3 samples,
/// too few for an honest p90; rides 10 s) and input latency (bursty
/// event stream — a time window empties between keystrokes; rides a
/// last-events ring).
public let overlayGaugeWindowSeconds = 3.0

/// A trailing-window rate from a monotonically growing counter: feed
/// it the cumulative count each overlay tick and it answers with the
/// rate over the last ~3 s (anchored at the oldest retained sample,
/// refreshed every call). Exists so the video line's in-fps and
/// out-fps ride the SAME window — the slash-pair `in/out 60/60 fps`
/// must compare like with like.
public final class RateMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var history: [(atMicroseconds: UInt64, count: UInt64)] = []
    private let windowMicroseconds: UInt64

    public init(windowSeconds: Double = overlayGaugeWindowSeconds) {
        windowMicroseconds = UInt64(windowSeconds * 1_000_000)
    }

    public func rate(count: UInt64, nowMicroseconds: UInt64) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        history.append((nowMicroseconds, count))
        // Evict entries older than the window, but always keep one
        // anchor at (or just beyond) the window's far edge.
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

    public func reset() {
        lock.lock(); history.removeAll(keepingCapacity: true); lock.unlock()
    }
}

/// Ringside accounting for the video delivery hop (receive thread →
/// delivery queue → renderer): the glass-side fps and the hop latency
/// percentiles. The hop duration is stamped from the receive thread's
/// dispatch to the renderer enqueue's completion, so it INCLUDES queue
/// wait — a resize-storm renderer stall shows up here as a p99 spike
/// (the 2026-07-30 audio-chop finding made this number load-bearing).
public final class VideoDeliveryBooks: @unchecked Sendable {
    private let lock = NSLock()
    private var enqueued: UInt64 = 0
    /// ~3 s of hop durations at 60 fps — the gauge window.
    private var ring = [Double](repeating: 0, count: 180)
    private var ringCount = 0
    private var ringIndex = 0
    private let outMeter = RateMeter()

    public func record(hopMilliseconds: Double) {
        lock.lock()
        enqueued += 1
        ring[ringIndex] = hopMilliseconds
        ringIndex = (ringIndex + 1) % ring.count
        ringCount = min(ringCount + 1, ring.count)
        lock.unlock()
    }

    public init() {}

    public func reset() {
        lock.lock()
        enqueued = 0
        ringCount = 0
        ringIndex = 0
        lock.unlock()
        outMeter.reset()
    }

    /// Out-fps over the gauge window plus hop percentiles.
    public func snapshot(
        nowMicroseconds: UInt64
    ) -> (outFps: Double?, hopP50: Double?, hopP99: Double?) {
        lock.lock()
        let count = enqueued
        let retained = Array(ring.prefix(ringCount))
        lock.unlock()
        let fps = outMeter.rate(
            count: count, nowMicroseconds: nowMicroseconds)
        guard !retained.isEmpty else { return (fps, nil, nil) }
        let sorted = retained.sorted()
        let p50 = sorted[sorted.count / 2]
        let p99 = sorted[min(sorted.count - 1, (sorted.count * 99) / 100)]
        return (fps, p50, p99)
    }
}
