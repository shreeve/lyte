// The session's stats rows for both the app overlay and wire-view, from
// the core's books plus the shell-owned facts in `SessionStatsContext`.
//
// Wording rules: nominal states are lowercase so a healthy ledger holds
// no capitals; only alarms (FROZEN, NOT CAPTURED, AWDL LOOSE) shout. Loss
// leads with the deficit. Payload bytes never appear.

import Foundation
import LyteClientSession
import LyteCore
import LyteWire

public struct SessionStatsRow: Hashable, Sendable, Identifiable {
    public var label: String
    public var value: String
    public var id: String { label }

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// What the stats rows need that the session core does not hold.
public struct SessionStatsContext: Sendable {
    /// Whether local keys and mouse go to the host; nil when the shell
    /// has no capture surface (wire-view).
    public var inputCaptured: Bool?
    /// The radio watchdog's alarm: streams are live, awdl0 stayed up
    /// through a re-engage.
    public var radioLoose = false
    /// Frames assembled off the wire per second.
    public var decodedFps: Double?
    /// The renderer-side delivery gauge (out fps and the delivery hop).
    public var delivery: VideoDeliveryGauge.Snapshot?
    /// The flight recorder's summary, for the glass and playout rows.
    public var flight: VideoFlightRecorder.Snapshot?
    /// The running file transfer's completed fraction, 0…1.
    public var bulkProgress: Double?

    public init() {}
}

public enum SessionStatsFormatter {
    /// The rows in reading order: session state, user input, the
    /// network, audio and video adjacent, then conditional rows.
    public static func rows(
        session: LyteUdpSession,
        context: SessionStatsContext = SessionStatsContext()
    ) -> [SessionStatsRow] {
        guard let endpoint = session.endpoint, let core = session.core else {
            return []
        }
        var rows: [SessionStatsRow] = []
        func row(_ label: String, _ value: String) {
            rows.append(SessionStatsRow(label: label, value: value))
        }

        row("session", sessionLine(core: core, context: context))
        row("user", core.input.snapshotStats().overlayLine())
        row("network", networkLine(demux: endpoint.demux, core: core))
        if let audio = audioLine(core.audio.snapshotStats()) {
            row("audio", audio)
        }
        let pipeline = core.pipeline.snapshotStats()
        if let video = videoLine(pipeline, context: context) {
            row("video", video)
        }
        if let flight = context.flight, flight.frames > 0 {
            row("glass", glassLine(flight, pipeline: pipeline))
            row("playout", playoutLine(flight))
        }

        let counters = core.snapshotCounters()
        let clipboardActivity = counters.clipboardSharesSent
            + counters.clipboardAnnouncesReceived
            + counters.clipboardLoopSuppressed
        let control = core.control
        if control.clipboardNegotiated, clipboardActivity > 0 {
            row("clipboard", "\(counters.clipboardSharesSent) sent"
                + " · \(counters.clipboardAnnouncesReceived) recv"
                + " · \(counters.clipboardLoopSuppressed) suppressed")
        }
        let images = control.clipboardImageCounters
        let imageActivity = images.sharesStarted + images.imagesApplied
            + images.sharesSuppressed + images.receivesRefused
        if control.clipboardImagesNegotiated, imageActivity > 0 {
            row("clip images", "\(images.sharesCompleted)"
                + "/\(images.sharesStarted) sent"
                + " · \(images.imagesApplied) applied"
                + " · \(images.sharesSuppressed) suppressed")
        }
        if let idr = idrLine(
            core.idrStats, causes: counters.videoRecoveryEpisodesByCause) {
            row("idr", idr)
        }
        if counters.bulkMessagesSent + counters.bulkMessagesReceived > 0 {
            var line = "\(counters.bulkMessagesSent) sent"
                + " · \(counters.bulkMessagesReceived) recv"
            if let fraction = context.bulkProgress {
                line += String(format: " · %.0f%%", fraction * 100)
            }
            row("bulk", line)
        }
        return rows
    }

    /// The network row's loss clause. `lost` is the demux's per-channel
    /// `seqMissing` sum, which is already net of late (reordered) fills.
    public static func lossSummary(lost: UInt64, received: UInt64) -> String {
        let expected = received + lost
        guard lost > 0 else {
            return "lost 0 of \(compactCount(expected)) host packets"
        }
        let percent = String(
            format: "%.3f", 100 * Double(lost) / Double(max(1, expected)))
        return "lost \(lost) of \(compactCount(expected)) host packets (\(percent)%)"
    }

    /// The IDR row: episodes by the cause that opened them (the wire
    /// request carries none), then retries. Nil before any episode.
    public static func idrLine(
        _ stats: ClientIdrRecovery.Stats,
        causes: [VideoRecoveryCause: UInt64]
    ) -> String? {
        guard stats.episodesStarted > 0 else { return nil }
        var parts = ["\(stats.episodesStarted) requested"]
        for cause in VideoRecoveryCause.allCases {
            if let count = causes[cause], count > 0 {
                parts.append("\(cause.shortName) \(count)")
            }
        }
        if stats.retryRequests > 0 {
            parts.append("\(stats.retryRequests) retried")
        }
        if stats.recoveryOutstanding { parts.append("AWAITING IDR") }
        return parts.joined(separator: " · ")
    }

    // MARK: Rows

    private static func sessionLine(
        core: LyteUdpSessionCore, context: SessionStatsContext
    ) -> String {
        let control = core.control
        var mode = control.wireMode == .active ? "active" : "idle"
        if control.state == .frozen { mode += " — FROZEN" }
        // Codec and chroma are fixed at announce (a tier change is a
        // reconnect), so they are session state beside the postures.
        if let chroma = core.streamChromaDescription {
            mode += " · hevc \(chroma)"
        }
        if control.hostAudioRoutingNegotiated {
            switch control.hostAudioRoutingPosture {
            case .hostMuted: mode += " · host audio muted"
            case .hostAudible: mode += " · host audio audible"
            case .streamOff: mode += " · audio stream off"
            case nil: mode += " · host audio pending"
            }
        }
        if control.clipboardNegotiated {
            mode += control.clipboardSharingEnabled
                ? " · clipboard shared" : " · clipboard private"
        }
        // Capture is a session state (who owns the keyboard and mouse),
        // so it lives here, not on the input row.
        if let captured = context.inputCaptured {
            mode += captured
                ? " · keys+mouse captured" : " · keys+mouse NOT CAPTURED"
        }
        if context.radioLoose { mode += " · AWDL LOOSE" }
        return mode
    }

    private static func networkLine(
        demux: ReceiveDemux, core: LyteUdpSessionCore
    ) -> String {
        let totals = demux.snapshotTotals()
        let lost = demux.snapshotChannels()
            .reduce(UInt64(0)) { $0 + $1.stats.seqMissing }
        var line = lossSummary(lost: lost, received: totals.datagrams)
        // Round trip as its floor plus upward spread (p90 − min) over the
        // last 10 beacons (~10 s at 1 Hz): "±" would imply a symmetric
        // spread the path does not have.
        let rtts = core.clockModel.recentSamples(10)
            .map(\.rttMicroseconds).sorted()
        if let minRtt = rtts.first {
            let p90 = rtts[min(rtts.count - 1, (rtts.count * 9) / 10)]
            line += String(
                format: " · roundtrip min %.1f ms · jitter %.1f ms",
                Double(minRtt) / 1000,
                (Double(p90) - Double(minRtt)) / 1000)
        }
        if totals.unsealFailures > 0 {
            line += ", \(totals.unsealFailures) unseal-failed"
        }
        return line
    }

    private static func audioLine(_ audio: AudioReceiverStats) -> String? {
        guard audio.depacketizer.datagramsIngested > 0 else { return nil }
        var parts: [String] = []
        // Depth in ms (exact: 5 ms hard-CBR packets).
        let depth = audio.bufferDepthPackets.percentiles([0.50, 0.99])
        if let p50 = depth[0], let p99 = depth[1] {
            parts.append("buffer p50/p99 \(p50 * 5)/\(p99 * 5) ms")
        }
        // Each concealment covered one missing-audio gap.
        parts.append("gaps concealed \(audio.jitter.plcInvocations)")
        if audio.depacketizer.packetsRebuilt > 0 {
            parts.append("repaired \(audio.depacketizer.packetsRebuilt)")
        }
        return parts.joined(separator: " · ")
    }

    /// Receive-side quality over ~5 s: bitrate, in/out cadence (both on
    /// the same 3 s meter window, so a widening split is a glass-side
    /// stall), frame sizes, and the delivery hop.
    private static func videoLine(
        _ pipeline: VideoPipelineStats, context: SessionStatsContext
    ) -> String? {
        guard let quality = pipeline.quality else { return nil }
        var video = String(format: "%.1f Mbps",
                           Double(quality.bitsPerSecond) / 1e6)
        switch (context.decodedFps, context.delivery?.outFps) {
        case (let inRate?, let out?):
            video += String(format: " · in/out %.0f/%.0f fps", inRate, out)
        case (let inRate?, nil):
            video += String(format: " · in %.0f fps", inRate)
        default:
            break
        }
        video += String(
            format: " · size p50/p95 %d/%d B",
            quality.frameBytesP50, quality.frameBytesP95)
        if let p50 = context.delivery?.hopP50,
           let p99 = context.delivery?.hopP99 {
            video += String(
                format: " · deliver p50/p99 %.1f/%.1f ms", p50, p99)
        }
        return video
    }

    private static func glassLine(
        _ flight: VideoFlightRecorder.Snapshot,
        pipeline: VideoPipelineStats
    ) -> String {
        String(
            format: "source/ready p99 %.1f/%.1f ms"
                + " · transit %.1f ms · sample %.1f ms"
                + " · queue/enqueue %.1f/%.1f ms",
            flight.sourceGapP99Milliseconds ?? 0,
            flight.readyGapP99Milliseconds ?? 0,
            flight.transitStretchP99Milliseconds ?? 0,
            Double(pipeline.sampleBuildMicroseconds.p99 ?? 0) / 1_000,
            flight.queueWaitP99Milliseconds ?? 0,
            flight.enqueueP99Milliseconds ?? 0)
    }

    /// The renderer's books and the Conductor's cue on their own row, so
    /// the glass row never wraps into one sentence. The cue is the
    /// score-to-glass offset; the reserve is what this frame's measured
    /// path left of it.
    private static func playoutLine(
        _ flight: VideoFlightRecorder.Snapshot
    ) -> String {
        var playout: [String] = []
        if let renderer = flight.rendererMetrics {
            playout.append("render \(renderer.totalFrames)")
            if let recent = flight.recentRendererMetrics {
                playout.append("drop total/recent "
                    + "\(renderer.droppedFrames)/\(recent.droppedFrames)")
                playout.append("corrupt total/recent "
                    + "\(renderer.corruptedFrames)"
                    + "/\(recent.corruptedFrames)")
            } else {
                playout.append("drop \(renderer.droppedFrames)")
                playout.append("corrupt \(renderer.corruptedFrames)")
            }
            playout.append(String(
                format: "delay %.1f ms",
                renderer.accumulatedDelayMilliseconds))
        }
        if let cue = flight.cueMilliseconds {
            playout.append(String(format: "cue %.0f ms", cue))
        }
        if let reserve = flight.reserveMilliseconds {
            playout.append(String(format: "reserve %.0f ms", reserve))
        }
        playout.append(flight.bottleneck)
        return playout.joined(separator: " · ")
    }

    private static func compactCount(_ n: UInt64) -> String {
        switch n {
        case ..<10_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1e3)
        default: return String(format: "%.2fM", Double(n) / 1e6)
        }
    }
}
