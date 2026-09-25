// AudioReceiver: the session's audio-path policy — depacketizer and FEC
// recovery feeding the adaptive jitter buffer, plus the latency books —
// behind one lock (the receive thread feeds it, the player's pump pulls).
// `now` is client-monotonic µs; capture stamps are the host's audio graph
// clock, so latency is measured above the session floor.

import Foundation
import LyteClientCore
import LyteCore
import LyteWire

public struct AudioReceiverStats: Sendable {
    public var depacketizer = AudioDepacketizerStats()
    public var jitter = AudioJitterStats()
    /// Capture → decode-feed µs above the session floor (the fastest
    /// packet seen). Subtracting the running minimum cancels the unknown
    /// graph-clock and host↔client offsets.
    public var captureToFeed = Histogram<UInt64>(
        capacity: 600, retention: .rolling)
    /// The same edge plus the caller-reported render pipeline.
    public var captureToRender = Histogram<UInt64>(
        capacity: 600, retention: .rolling)
    /// Total buffered audio at each pull, in packets: jitter buffer plus
    /// the caller's reported pipeline.
    public var bufferDepthPackets = Histogram<UInt64>(
        capacity: 600, retention: .rolling)
    /// Times accelerate engaged.
    public var accelerateEngagements: UInt64 = 0
    /// Pulls answered while accelerate was engaged.
    public var pullsAccelerated: UInt64 = 0

    public init() {}
}

/// One pump step: what to feed the decoder, and whether its output
/// rides the WSOLA accelerate path.
public struct AudioPullDecision: Sendable {
    public let verdict: AudioPullVerdict
    public let accelerate: Bool
}

public final class AudioReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var depacketizer: AudioDepacketizer
    private let buffer: AudioJitterBuffer

    private var captureToFeed = Histogram<UInt64>(
        capacity: 600, retention: .rolling)
    private var captureToRender = Histogram<UInt64>(
        capacity: 600, retention: .rolling)
    private var bufferDepthPackets = Histogram<UInt64>(
        capacity: 600, retention: .rolling)
    /// The smallest capture→feed delta seen (signed).
    private var minFeedDelta: Int64?
    /// Accelerate hysteresis: engaged from target + engage down to target.
    private var accelerating = false
    private var accelerateEngagements: UInt64 = 0
    private var pullsAccelerated: UInt64 = 0

    public init(jitterConfig: AudioJitterConfig = AudioJitterConfig()) {
        self.depacketizer = AudioDepacketizer()
        self.buffer = AudioJitterBuffer(config: jitterConfig)
    }

    /// Feeds one accepted chan-1 datagram.
    public func ingest(
        envelope: Envelope, payload: [UInt8], now: ClientTimestamp
    ) {
        lock.lock()
        defer { lock.unlock() }
        for packet in depacketizer.ingest(envelope: envelope, payload: payload) {
            buffer.insert(packet, arrivalMicroseconds: now.microseconds)
        }
    }

    /// The host announced audio-quiet (0x25).
    public func noteAnnouncedQuiet() {
        lock.withLock { buffer.noteAnnouncedQuiet() }
    }

    /// One playout decision for the pump. `renderPipelineMicroseconds` is
    /// what still sits between this feed and the speaker; it counts toward
    /// the latency books and the accelerate depth judgment.
    public func pullDecision(
        now: ClientTimestamp,
        urgent: Bool = false,
        renderPipelineMicroseconds: UInt64 = 0
    ) -> AudioPullDecision {
        lock.lock()
        defer { lock.unlock() }
        let depthPackets = UInt64(buffer.pendingCount)
            &+ renderPipelineMicroseconds
                / AudioWire.packetDurationMicroseconds
        bufferDepthPackets.record(depthPackets)

        let target = buffer.targetPackets
        if accelerating {
            if depthPackets <= UInt64(target) { accelerating = false }
        } else if depthPackets > UInt64(
            target + buffer.config.accelerateEngagePackets) {
            accelerating = true
            accelerateEngagements += 1
        }

        let verdict = buffer.pull(
            nowMicroseconds: now.microseconds, urgent: urgent)
        if case .packet(let packet) = verdict {
            if accelerating { pullsAccelerated += 1 }
            if !packet.recovered {
                let delta = Int64(bitPattern:
                    now.microseconds &- packet.captureMicroseconds)
                let floor = min(minFeedDelta ?? delta, delta)
                minFeedDelta = floor
                // Capture stamps are host-chosen: a span past Int64 is a
                // lie, never a latency, and records nothing.
                let (aboveFloor, overflow) =
                    delta.subtractingReportingOverflow(floor)
                if !overflow {
                    captureToFeed.record(UInt64(aboveFloor))
                    captureToRender.record(
                        UInt64(aboveFloor) &+ renderPipelineMicroseconds)
                }
            }
        }
        return AudioPullDecision(verdict: verdict, accelerate: accelerating)
    }

    /// The adaptive delay target, in packets.
    public var targetDepthPackets: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.targetPackets
    }

    /// Packets queued in the jitter buffer right now.
    public var pendingPackets: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.pendingCount
    }

    public func snapshotStats() -> AudioReceiverStats {
        lock.lock()
        defer { lock.unlock() }
        var out = AudioReceiverStats()
        out.depacketizer = depacketizer.snapshotStats()
        out.jitter = buffer.snapshotStats()
        out.captureToFeed = captureToFeed
        out.captureToRender = captureToRender
        out.bufferDepthPackets = bufferDepthPackets
        out.accelerateEngagements = accelerateEngagements
        out.pullsAccelerated = pullsAccelerated
        return out
    }
}
