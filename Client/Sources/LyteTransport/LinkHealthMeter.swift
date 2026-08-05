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

    /// Which stage the recent stalls blame — "network" (transit stretch:
    /// host stamp → client-ready), or "renderer" (queue/enqueue). Source
    /// capture gaps are deliberately not evidence because damage-driven
    /// capture is allowed to be quiet.
    public var level: Level
    /// Exact number of stall episodes in the current second and the
    /// preceding 59 one-second buckets.
    public var stallsLastMinute: Int
    public var worstStallMilliseconds: Double
    public var dominantStage: String
    /// Session books survive the rolling window and roaming reconnects.
    public var sessionStallCount: Int
    public var sessionWorstMilliseconds: Double

    public init(
        level: Level, stallsLastMinute: Int,
        worstStallMilliseconds: Double, dominantStage: String,
        sessionStallCount: Int, sessionWorstMilliseconds: Double
    ) {
        self.level = level
        self.stallsLastMinute = stallsLastMinute
        self.worstStallMilliseconds = worstStallMilliseconds
        self.dominantStage = dominantStage
        self.sessionStallCount = sessionStallCount
        self.sessionWorstMilliseconds = sessionWorstMilliseconds
    }
}

public final class LinkHealthMeter {
    private struct Bucket {
        var second: UInt64?
        var count = 0
        var worstMilliseconds = 0.0
        var networkCount = 0
        var rendererCount = 0
    }

    /// Consecutive spiking frames coalesce into one user-visible episode.
    /// The episode retains its first bucket while its tail moves forward.
    private struct Episode {
        var bucketSecond: UInt64
        var lastEventMicroseconds: UInt64
        var worstMilliseconds: Double
        var stage: String
    }

    public static let transitStallMilliseconds = 25.0
    public static let rendererStallMilliseconds = 8.0
    public static let coalesceMicroseconds: UInt64 = 500_000
    public static let windowBucketCount = 60
    public static let warmupMicroseconds: UInt64 = 10_000_000

    private var buckets = Array(
        repeating: Bucket(), count: LinkHealthMeter.windowBucketCount)
    private var lastEpisode: Episode?
    private var highWaterOrdinal: UInt64 = 0
    private var epochFirstEventMicroseconds: UInt64?
    private var sessionStallCount = 0
    private var sessionWorstMilliseconds = 0.0
    private let debugTrace = ProcessInfo.processInfo
        .environment["LYTE_LINK_HEALTH_DEBUG"] == "1"

    public init() {}

    /// Feed one recorded frame. `eventMicroseconds` is the client's
    /// monotonic ready timestamp, so recorder batches still put an episode
    /// in the second when it actually happened. Ordinals make overlapping
    /// recorder scans idempotent.
    public func observe(
        ordinal: UInt64,
        transitStretchMilliseconds: Double?,
        queueWaitMilliseconds: Double,
        enqueueMilliseconds: Double,
        eventMicroseconds: UInt64
    ) {
        guard ordinal > highWaterOrdinal else { return }
        highWaterOrdinal = ordinal

        let epochStart = epochFirstEventMicroseconds ?? eventMicroseconds
        epochFirstEventMicroseconds = epochStart
        guard eventMicroseconds >= epochStart,
              eventMicroseconds - epochStart >= Self.warmupMicroseconds
        else { return }

        var worst = 0.0
        var stage = ""
        if let transit = transitStretchMilliseconds,
           transit >= Self.transitStallMilliseconds, transit > worst {
            worst = transit
            stage = "network"
        }
        let renderer = queueWaitMilliseconds + enqueueMilliseconds
        if renderer >= Self.rendererStallMilliseconds, renderer > worst {
            worst = renderer
            stage = "renderer"
        }
        guard worst > 0 else { return }

        let eventSecond = eventMicroseconds / 1_000_000
        if var last = lastEpisode,
           eventMicroseconds >= last.lastEventMicroseconds,
           eventMicroseconds - last.lastEventMicroseconds
                <= Self.coalesceMicroseconds {
            last.lastEventMicroseconds = eventMicroseconds
            if worst > last.worstMilliseconds {
                updateEpisodePeak(
                    bucketSecond: last.bucketSecond,
                    oldStage: last.stage,
                    newStage: stage,
                    worstMilliseconds: worst)
                last.worstMilliseconds = worst
                last.stage = stage
            }
            lastEpisode = last
        } else {
            incrementBucket(
                second: eventSecond,
                stage: stage,
                worstMilliseconds: worst)
            lastEpisode = Episode(
                bucketSecond: eventSecond,
                lastEventMicroseconds: eventMicroseconds,
                worstMilliseconds: worst,
                stage: stage)
            sessionStallCount += 1
            if debugTrace {
                print(String(format: "link-health: episode #%d %@ "
                    + "%.0f ms at client-t %.3f (ordinal %d)",
                    sessionStallCount, stage, worst,
                    Double(eventMicroseconds) / 1_000_000,
                    ordinal))
                fflush(stdout)
            }
        }
        sessionWorstMilliseconds = max(sessionWorstMilliseconds, worst)
    }

    public func resetSessionBooks() {
        resetWindow()
        highWaterOrdinal = 0
        sessionStallCount = 0
        sessionWorstMilliseconds = 0
    }

    /// Start a fresh recorder epoch without ending the user's sitting.
    /// Roaming reconnects reset frame ordinals, the rolling warning window,
    /// and its warm-up grace, while session-wide totals remain meaningful.
    public func resetEpochKeepingSessionBooks() {
        resetWindow()
        highWaterOrdinal = 0
    }

    /// Sum the current one-second bucket and the preceding 59 buckets.
    /// The caller supplies its live monotonic tick, so old events age out
    /// even when a damage-driven desktop emits no new frames.
    public func assessment(nowMicroseconds: UInt64) -> LinkHealthAssessment {
        let nowSecond = nowMicroseconds / 1_000_000
        var count = 0
        var worst = 0.0
        var networkCount = 0
        var rendererCount = 0
        for bucket in buckets {
            guard let second = bucket.second,
                  second <= nowSecond,
                  nowSecond - second < UInt64(Self.windowBucketCount)
            else { continue }
            count += bucket.count
            worst = max(worst, bucket.worstMilliseconds)
            networkCount += bucket.networkCount
            rendererCount += bucket.rendererCount
        }

        let dominant: String
        if networkCount == 0, rendererCount == 0 {
            dominant = "none"
        } else if rendererCount > networkCount {
            dominant = "renderer"
        } else {
            dominant = "network"
        }
        let level: LinkHealthAssessment.Level
        if count >= 3 || worst >= 100 {
            level = .poor
        } else if count >= 1 {
            level = .degraded
        } else {
            level = .good
        }
        return LinkHealthAssessment(
            level: level, stallsLastMinute: count,
            worstStallMilliseconds: worst, dominantStage: dominant,
            sessionStallCount: sessionStallCount,
            sessionWorstMilliseconds: sessionWorstMilliseconds)
    }

    private func resetWindow() {
        buckets = Array(repeating: Bucket(), count: Self.windowBucketCount)
        lastEpisode = nil
        epochFirstEventMicroseconds = nil
    }

    private func bucketIndex(for second: UInt64) -> Int {
        Int(second % UInt64(Self.windowBucketCount))
    }

    private func incrementBucket(
        second: UInt64,
        stage: String,
        worstMilliseconds: Double
    ) {
        let index = bucketIndex(for: second)
        if buckets[index].second != second {
            buckets[index] = Bucket(second: second)
        }
        buckets[index].count += 1
        buckets[index].worstMilliseconds = max(
            buckets[index].worstMilliseconds, worstMilliseconds)
        if stage == "renderer" {
            buckets[index].rendererCount += 1
        } else {
            buckets[index].networkCount += 1
        }
    }

    private func updateEpisodePeak(
        bucketSecond: UInt64,
        oldStage: String,
        newStage: String,
        worstMilliseconds: Double
    ) {
        let index = bucketIndex(for: bucketSecond)
        guard buckets[index].second == bucketSecond else { return }
        buckets[index].worstMilliseconds = max(
            buckets[index].worstMilliseconds, worstMilliseconds)
        guard oldStage != newStage else { return }
        if oldStage == "renderer" {
            buckets[index].rendererCount -= 1
            buckets[index].networkCount += 1
        } else {
            buckets[index].networkCount -= 1
            buckets[index].rendererCount += 1
        }
    }
}
