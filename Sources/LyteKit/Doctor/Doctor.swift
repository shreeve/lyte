import Foundation

/// The network doctor (M6, D4): watches session telemetry and names what's
/// happening in plain language — with evidence and fixes, never bare numbers.
/// Signatures calibrated live on 2026-07-15 (Wi-Fi↔Wi-Fi, shared 6 GHz):
/// radio stalls = arrival gaps without packet loss; AWDL ≈ +50 ms buffer
/// pressure; shared-channel floor ≈ sporadic >50 ms gaps that suppression
/// can't remove.
public struct Diagnosis: Sendable, Equatable {
    public enum Level: Int, Sendable, Comparable {
        case good, fair, poor
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    public let level: Level
    public let headline: String
    public let evidence: [String]
    public let fixes: [String]
    /// True when genuine packet loss (FEC exceeded) is the diagnosis — the
    /// signal the policy engine records as a bitrate ceiling for this host.
    public let lossy: Bool

    public init(level: Level, headline: String, evidence: [String], fixes: [String],
                lossy: Bool = false) {
        self.level = level
        self.headline = headline
        self.evidence = evidence
        self.fixes = fixes
        self.lossy = lossy
    }
}

public final class Doctor: @unchecked Sendable {
    private var last: LyteSession.Stats?
    private var lastAtUs: UInt64 = 0
    // Smoothed per-second rates (EMA over ~3 samples)
    private var gap50Rate = 0.0
    private var underrunRate = 0.0
    private var videoLossRate = 0.0

    public init() {}

    /// Feed a stats snapshot (call every few seconds); returns the current read.
    public func sample(_ stats: LyteSession.Stats, helperEngaged: Bool) -> Diagnosis {
        let nowUs = DispatchTime.now().uptimeNanoseconds / 1000
        defer {
            last = stats
            lastAtUs = nowUs
        }
        guard let last, lastAtUs > 0, nowUs > lastAtUs else {
            return Diagnosis(level: .good, headline: "Measuring…", evidence: [], fixes: [])
        }
        let dt = Double(nowUs - lastAtUs) / 1_000_000
        guard dt > 0.5 else {
            return diagnose(stats, helperEngaged: helperEngaged)
        }

        func ema(_ current: Double, _ instant: Double) -> Double {
            current * 0.67 + instant * 0.33
        }
        gap50Rate = ema(gap50Rate, Double(stats.audioGapsOver50ms &- last.audioGapsOver50ms) / dt)
        underrunRate = ema(underrunRate, Double(stats.audioUnderruns &- last.audioUnderruns) / dt)
        let pkts = Double(stats.videoPackets &- last.videoPackets)
        let lost = Double(stats.videoFramesLost &- last.videoFramesLost)
        videoLossRate = ema(videoLossRate, pkts > 0 ? lost / dt : 0)

        return diagnose(stats, helperEngaged: helperEngaged)
    }

    private func diagnose(_ stats: LyteSession.Stats, helperEngaged: Bool) -> Diagnosis {
        var evidence: [String] = []
        var fixes: [String] = []

        // Genuine packet loss is a different disease than jitter
        if videoLossRate > 0.5 {
            evidence.append(String(format: "losing %.1f video frames/s (FEC exceeded)", videoLossRate))
            fixes.append("Congestion or weak signal — check bitrate headroom and signal strength")
            return Diagnosis(level: .poor, headline: "Packet loss — network is dropping data",
                             evidence: evidence, fixes: fixes, lossy: true)
        }

        // Radio weather: arrival stalls without loss
        if gap50Rate > 0.05 {
            evidence.append(String(format: "radio stalls: %.1f/min over 50 ms (max %d ms)",
                                   gap50Rate * 60, stats.audioMaxGapMs))
            evidence.append("no packet loss — frames were delayed, not dropped")
            evidence.append("audio buffer riding at \(stats.audioQueuedMs) ms to absorb it")
        }
        if underrunRate > 0.05 {
            evidence.append(String(format: "stalls exceeding the buffer: %.1f/min audible blips",
                                   underrunRate * 60))
        }

        // The headline must not claim absorption the evidence disproves:
        // "absorbed/covered" only when blips are actually negligible.
        let absorbed = underrunRate * 60 < 1   // < 1 audible blip/min

        if gap50Rate > 1.0 || underrunRate > 0.5 {
            if !helperEngaged {
                fixes.append("Enable the Lyte helper (System Settings → Login Items) to quiet AWDL during streams")
            } else {
                fixes.append("Radio quiet is active; remaining stalls are channel contention — put the host and this Mac on different Wi-Fi bands, or wire one of them")
            }
            return Diagnosis(level: .poor,
                             headline: absorbed
                                 ? "Rough radio weather — buffering is covering for it"
                                 : "Rough radio weather — blips are getting through",
                             evidence: evidence, fixes: fixes)
        }

        if gap50Rate > 0.15 || underrunRate > 0.05 {
            if !helperEngaged {
                fixes.append("Enabling the Lyte helper may reduce stalls (quiets AWDL)")
            }
            return Diagnosis(level: .fair,
                             headline: absorbed
                                 ? "Occasional radio stalls — absorbed by the buffer"
                                 : "Occasional radio stalls — a few blips getting through",
                             evidence: evidence, fixes: fixes)
        }

        return Diagnosis(level: .good,
                         headline: "Network healthy",
                         evidence: ["audio buffer \(stats.audioQueuedMs) ms, no significant stalls"],
                         fixes: [])
    }
}
