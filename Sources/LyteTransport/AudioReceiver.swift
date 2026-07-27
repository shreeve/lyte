// AudioReceiver (CL-11): the sans-IO audio-path core the session owns —
// depacketizer (HS-15's byte mirror + FEC recovery) feeding the
// adaptive jitter buffer, one lock over both, plus the latency books.
// The production shell's LyteAudioPlayer pulls verdicts from here;
// tests drive the identical object in virtual time.
//
// Clock domains, stated once: `now` is the session's client-monotonic
// µs, used for the buffer's clocks and adaptation. Capture stamps are
// the host's PipeWire GRAPH clock (samples since graph start — never
// wall clock, audio-continuity §4.3), an epoch the client cannot map
// absolutely; the latency books therefore measure ABOVE THE SESSION
// FLOOR (min capture→feed delta), which cancels both unknown epochs —
// see AudioReceiverStats.captureToFeed. The kernel arrival stamp the
// endpoint collects stays with the feedback dispersion path; at 5 ms
// granularity the receive thread's wakeup jitter is noise the
// adaptation window absorbs.

import Foundation
import LyteWire

public struct AudioReceiverStats: Sendable {
    public var depacketizer = AudioDepacketizerStats()
    public var jitter = AudioJitterStats()
    /// Capture stamp → decode-feed, µs ABOVE THE SESSION FLOOR (the
    /// fastest capture→feed packet observed). Epoch-free by
    /// construction: the host stamps audio with the PipeWire GRAPH
    /// clock (samples since graph start — audio-continuity §4.3),
    /// whose offset to the beacon-fed monotonic domain is unknowable
    /// client-side; subtracting the running minimum cancels every
    /// constant offset (graph epoch AND host↔client offset), leaving
    /// exactly the receive pipeline's added delay. Absolute
    /// capture→render = this + the path floor (≲ the beacon min RTT).
    public var captureToFeed = LatencyHistogram()
    /// The same edge extended by the caller-reported render pipeline
    /// (PCM ring depth + device latency at feed time) — the honest
    /// capture→render-above-floor estimate.
    public var captureToRender = LatencyHistogram()
    /// TOTAL buffered audio at each pull, in packets: jitter-buffer
    /// pending + whatever the caller reports still queued toward the
    /// speaker — the gate's "buffer depth" figure.
    public var bufferDepthPackets = LatencyHistogram(capacity: 1 << 14)
    /// CL-17: times the depth-vs-target hysteresis flipped accelerate
    /// ON (engage at target + accelerateEngagePackets, release at
    /// target).
    public var accelerateEngagements: UInt64 = 0
    /// Pulls answered while accelerate was engaged.
    public var pullsAccelerated: UInt64 = 0

    public init() {}
}

/// One pump step's verdict pair (CL-17): what to feed the decoder AND
/// whether its output should ride the WSOLA accelerate path — the
/// NetEQ normal/accelerate/expand triple in CL-11's vocabulary
/// (conceal = expand).
public struct AudioPullDecision: Sendable {
    public let verdict: AudioPullVerdict
    public let accelerate: Bool
}

public final class AudioReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private let depacketizer: AudioDepacketizer
    private let buffer: AudioJitterBuffer

    private var captureToFeed = LatencyHistogram()
    private var captureToRender = LatencyHistogram()
    private var bufferDepthPackets = LatencyHistogram(capacity: 1 << 14)
    /// The floor: the smallest capture→feed delta seen (signed —
    /// graph-clock and client epochs differ arbitrarily).
    private var minFeedDelta: Int64?
    /// CL-17 hysteresis state: accelerate stays engaged from
    /// target + engage down to target, so the drain never flaps.
    private var accelerating = false
    private var accelerateEngagements: UInt64 = 0
    private var pullsAccelerated: UInt64 = 0

    public init(jitterConfig: AudioJitterConfig = AudioJitterConfig()) {
        self.depacketizer = AudioDepacketizer()
        self.buffer = AudioJitterBuffer(config: jitterConfig)
    }

    /// Feeds one accepted chan-1 datagram (the session's ingest hook).
    public func ingest(
        envelope: Envelope, payload: [UInt8], now: ClientTimestamp
    ) {
        lock.lock()
        defer { lock.unlock() }
        for packet in depacketizer.ingest(envelope: envelope, payload: payload) {
            buffer.insert(packet, arrivalMicroseconds: now.microseconds)
        }
    }

    /// One playout decision for the pump. `renderPipelineMicroseconds`
    /// is what still sits between this feed and the speaker (ring
    /// depth + the accelerator's gather + device latency) so the
    /// capture→render estimate AND the accelerate depth judgment stay
    /// honest. The accelerate half (CL-17): total depth = jitter
    /// pending + reported pipeline; engage past target + engage
    /// packets, release at target — the pump feeds decoded PCM through
    /// the WSOLA path exactly while this says so.
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
                let aboveFloor = UInt64(delta - floor)
                captureToFeed.record(aboveFloor)
                captureToRender.record(
                    aboveFloor &+ renderPipelineMicroseconds)
            }
        }
        return AudioPullDecision(verdict: verdict, accelerate: accelerating)
    }

    /// The CL-11 surface, kept verbatim for callers that only want the
    /// verdict (the accelerate judgment still runs — one decision
    /// path, two views of it).
    public func pull(
        now: ClientTimestamp,
        urgent: Bool = false,
        renderPipelineMicroseconds: UInt64 = 0
    ) -> AudioPullVerdict {
        pullDecision(
            now: now, urgent: urgent,
            renderPipelineMicroseconds: renderPipelineMicroseconds
        ).verdict
    }

    /// The adaptive delay target, in packets — what the pump sizes the
    /// PCM ring against.
    public var targetDepthPackets: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.targetPackets
    }

    /// Packets queued in the jitter buffer right now (CL-17: the
    /// upstream half of the depth figure; the caller adds what it
    /// holds ringside).
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
