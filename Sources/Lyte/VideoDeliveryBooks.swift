import Foundation

/// Ringside accounting for the video delivery hop (receive thread →
/// delivery queue → renderer): the glass-side fps and the hop latency
/// percentiles. The hop duration is stamped from the receive thread's
/// dispatch to the renderer enqueue's completion, so it INCLUDES queue
/// wait — a resize-storm renderer stall shows up here as a p99 spike
/// (the 2026-07-30 audio-chop finding made this number load-bearing).
final class VideoDeliveryBooks: @unchecked Sendable {
    private let lock = NSLock()
    private var enqueued: UInt64 = 0
    /// Last ~4 s of hop durations at 60 fps; enough for honest p99.
    private var ring = [Double](repeating: 0, count: 256)
    private var ringCount = 0
    private var ringIndex = 0
    private var lastRateCount: UInt64 = 0
    private var lastRateAtMicroseconds: UInt64 = 0
    private var lastFps: Double?

    func record(hopMilliseconds: Double) {
        lock.lock()
        enqueued += 1
        ring[ringIndex] = hopMilliseconds
        ringIndex = (ringIndex + 1) % ring.count
        ringCount = min(ringCount + 1, ring.count)
        lock.unlock()
    }

    /// Out-fps since the previous snapshot (≥0.5 s apart to stay
    /// honest at the overlay's 1 Hz cadence) plus hop percentiles.
    func snapshot(
        nowMicroseconds: UInt64
    ) -> (outFps: Double?, hopP50: Double?, hopP99: Double?) {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = nowMicroseconds &- lastRateAtMicroseconds
        if lastRateAtMicroseconds == 0 {
            lastRateAtMicroseconds = nowMicroseconds
            lastRateCount = enqueued
        } else if elapsed >= 500_000 {
            lastFps = Double(enqueued &- lastRateCount)
                / (Double(elapsed) / 1_000_000)
            lastRateAtMicroseconds = nowMicroseconds
            lastRateCount = enqueued
        }
        guard ringCount > 0 else { return (lastFps, nil, nil) }
        let sorted = Array(ring.prefix(ringCount)).sorted()
        let p50 = sorted[ringCount / 2]
        let p99 = sorted[min(ringCount - 1, (ringCount * 99) / 100)]
        return (lastFps, p50, p99)
    }
}
