import Foundation

/// The delivery path's user-visible failure verdict. The flight recorder
/// retains every internal disturbance for diagnosis, but this meter is
/// deliberately narrower: a recovered transit or queue delay is success and
/// stays silent. Only a frame that missed its presentation beat or was lost by
/// the renderer enters the warning window.
///
/// Cost model: fed once a second with only the frames recorded since
/// the last feed (ordinal high-water mark); each frame is a handful
/// of comparisons. No new measurement, no timers of its own.
public struct LinkHealthAssessment: Equatable, Sendable {
    public enum Level: String, Sendable {
        case good, degraded, poor
    }

    /// Where the recent failures became conclusive: "late" means the frame
    /// reached renderer handoff after its presentation beat; "renderer" means
    /// it was explicitly dropped or the renderer failed.
    public var level: Level
    /// Exact number of failure episodes in the current second and the
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
        var lateCount = 0
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
        presentationLatenessMilliseconds: Double?,
        rendererDropped: Bool,
        rendererFailed: Bool,
        eventMicroseconds: UInt64
    ) {
        guard ordinal > highWaterOrdinal else { return }
        highWaterOrdinal = ordinal

        let epochStart = epochFirstEventMicroseconds ?? eventMicroseconds
        epochFirstEventMicroseconds = epochStart
        guard eventMicroseconds >= epochStart,
              eventMicroseconds - epochStart >= Self.warmupMicroseconds
        else { return }

        let lateness = max(presentationLatenessMilliseconds ?? 0, 0)
        let stage: String
        if lateness > 0 {
            stage = "late"
        } else if rendererDropped || rendererFailed {
            stage = "renderer"
        } else {
            // Internal jitter, queueing, repair, and re-cue evidence remains
            // in the flight recorder. The mechanism worked, so the UI says
            // nothing.
            return
        }
        let worst = lateness

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
        var lateCount = 0
        var rendererCount = 0
        for bucket in buckets {
            guard let second = bucket.second,
                  second <= nowSecond,
                  nowSecond - second < UInt64(Self.windowBucketCount)
            else { continue }
            count += bucket.count
            worst = max(worst, bucket.worstMilliseconds)
            lateCount += bucket.lateCount
            rendererCount += bucket.rendererCount
        }

        let dominant: String
        if lateCount == 0, rendererCount == 0 {
            dominant = "none"
        } else if rendererCount > lateCount {
            dominant = "renderer"
        } else {
            dominant = "late"
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
            buckets[index].lateCount += 1
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
            buckets[index].lateCount += 1
        } else {
            buckets[index].lateCount -= 1
            buckets[index].rendererCount += 1
        }
    }
}
