import Foundation

/// The delivery path's self-diagnosis — the flight recorder already
/// measures every stage per frame; this folds those numbers into one
/// user-facing verdict so a transit hiccup announces itself instead
/// of being someone's heisenbug (the 2026-08-01 Wi-Fi hunt: ~100 ms
/// radio deaf-windows every ~10 s, invisible in percentiles, obvious
/// in per-frame books).
///
/// Cost model: fed once a second with only the frames recorded since
/// the last feed (ordinal high-water mark); each frame is a handful
/// of comparisons. No new measurement, no timers of its own.
public struct LinkHealthAssessment: Equatable, Sendable {
    public enum Level: String, Sendable {
        case good, degraded, poor
    }
    /// Which stage the recent stalls blame — "network" (transit
    /// stretch: host stamp → client-ready), "host" (capture/encode
    /// cadence), "renderer" (queue/enqueue).
    public var level: Level
    /// Rate and level grade the rolling window — the pill relaxes
    /// when the link recovers. Total and worst are SESSION books —
    /// "43 total, worst 115 ms" quantifies the whole sitting even
    /// after the window forgets.
    public var stallsPerMinute: Double
    public var worstStallMilliseconds: Double
    public var dominantStage: String
    public var sessionStallCount: Int
    public var sessionWorstMilliseconds: Double

    public init(
        level: Level, stallsPerMinute: Double,
        worstStallMilliseconds: Double, dominantStage: String,
        sessionStallCount: Int, sessionWorstMilliseconds: Double
    ) {
        self.level = level
        self.stallsPerMinute = stallsPerMinute
        self.worstStallMilliseconds = worstStallMilliseconds
        self.dominantStage = dominantStage
        self.sessionStallCount = sessionStallCount
        self.sessionWorstMilliseconds = sessionWorstMilliseconds
    }
}

public final class LinkHealthMeter {
    /// One stall episode: consecutive spiking frames coalesce (a
    /// single radio deaf-window smears lateness across several frames
    /// but is ONE event to the user).
    private struct Episode {
        var at: TimeInterval
        var worstMilliseconds: Double
        var stage: String
    }

    /// A frame is an event when its stage exceeds these (ms). The
    /// transit bar is set above dispatch jitter but below anything an
    /// eye can see; host cadence above the idle-floor's own gaps;
    /// renderer far above its measured µs baseline.
    public static let transitStallMilliseconds = 25.0
    public static let hostStallMilliseconds = 45.0
    public static let rendererStallMilliseconds = 8.0
    /// Events closer than this are the same episode.
    public static let coalesceSeconds = 0.5
    /// The grading window; episodes age out past it.
    public static let windowSeconds = 60.0

    private var episodes: [Episode] = []
    private var highWaterOrdinal: UInt64 = 0
    private var sessionStallCount = 0
    private var sessionWorstMilliseconds = 0.0

    public init() {}

    /// Feed one recorded frame (primitives, so tests need no recorder).
    /// `now` is the caller's clock; episodes live on it. Ordinals only
    /// gate re-feeding — a lower ordinal than seen means the recorder
    /// was reset (reconnect), and the meter starts fresh with it.
    public func observe(
        ordinal: UInt64,
        transitStretchMilliseconds: Double?,
        sourceGapMilliseconds: Double?,
        queueWaitMilliseconds: Double,
        enqueueMilliseconds: Double,
        now: TimeInterval
    ) {
        if ordinal < highWaterOrdinal {
            // Ordinals ran backwards: the recorder was reset
            // (reconnect). Old episodes AND the session books belong
            // to the old session.
            episodes.removeAll()
            sessionStallCount = 0
            sessionWorstMilliseconds = 0
        } else if ordinal == highWaterOrdinal {
            return // already folded
        }
        highWaterOrdinal = ordinal

        var worst = 0.0
        var stage = ""
        if let transit = transitStretchMilliseconds,
           transit >= Self.transitStallMilliseconds, transit > worst {
            worst = transit
            stage = "network"
        }
        if let source = sourceGapMilliseconds,
           source >= Self.hostStallMilliseconds, source > worst {
            worst = source
            stage = "host"
        }
        let renderer = queueWaitMilliseconds + enqueueMilliseconds
        if renderer >= Self.rendererStallMilliseconds, renderer > worst {
            worst = renderer
            stage = "renderer"
        }
        guard worst > 0 else { return }

        if var last = episodes.last,
           now - last.at <= Self.coalesceSeconds {
            last.at = now
            if worst > last.worstMilliseconds {
                last.worstMilliseconds = worst
                last.stage = stage
            }
            episodes[episodes.count - 1] = last
        } else {
            episodes.append(Episode(
                at: now, worstMilliseconds: worst, stage: stage))
            sessionStallCount += 1
        }
        sessionWorstMilliseconds = max(sessionWorstMilliseconds, worst)
    }

    /// The rolling verdict. Poor: stalls are frequent (3+ in the
    /// window) or deep (≥100 ms — a full visible freeze). Degraded:
    /// any stall in the window. Good: quiet — and the UI shows
    /// nothing, because a clean link needs no announcement.
    public func assessment(now: TimeInterval) -> LinkHealthAssessment {
        episodes.removeAll { now - $0.at > Self.windowSeconds }
        let count = episodes.count
        let worst = episodes.map(\.worstMilliseconds).max() ?? 0
        let perMinute = Double(count) * 60.0 / Self.windowSeconds
        var stages: [String: Int] = [:]
        for e in episodes { stages[e.stage, default: 0] += 1 }
        let dominant = stages.max { $0.value < $1.value }?.key ?? "none"
        let level: LinkHealthAssessment.Level
        if count >= 3 || worst >= 100 {
            level = .poor
        } else if count >= 1 {
            level = .degraded
        } else {
            level = .good
        }
        return LinkHealthAssessment(
            level: level, stallsPerMinute: perMinute,
            worstStallMilliseconds: worst, dominantStage: dominant,
            sessionStallCount: sessionStallCount,
            sessionWorstMilliseconds: sessionWorstMilliseconds)
    }
}
