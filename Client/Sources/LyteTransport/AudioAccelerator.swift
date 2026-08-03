// AudioAccelerator (CL-17): accelerate-only WSOLA time-scale
// modification — the M7 receiver spec's §5.2 as written
// (docs/20260720-145840-audio-continuity.md): when the playout pipe
// holds more audio than the adaptive target, play slightly fast by
// excising whole waveform periods under a crossfade, pitch preserved,
// until the backlog drains. This replaces the jitter buffer's counted
// content skip for everything short of a blackout — the standard
// WebRTC NetEQ move, at leaf-library weight in pure Swift.
//
// Shape (NetEQ's, mirrored): while the receiver's pull decision says
// accelerate AND the rate bucket holds a full period, the pump's
// decoded packets GATHER here (≤ 4 packets, 20 ms — held transiently,
// counted in the depth the receiver judges) until one operation's
// worth exists; the op finds the best period T in [2.5 ms, 10 ms] by
// normalized autocorrelation on a mono mixdown, then overlap-adds
// x[0..T) into x[T..2T) under a raised-cosine ramp — T frames vanish,
// every sample outside the crossfade passes through untouched, and
// the splice lands on the waveform's own self-similarity (a pure tone
// stays a pure tone; C < threshold defers the cut rather than tearing
// a transient; silence splices freely — cutting nothing is free).
//
// Rate discipline: a token bucket accrues maxRatePercent of every
// input frame and each op spends its T — sustained speedup is bounded
// at ≤5% of realtime (one banked period of instantaneous slack), so a
// 60 ms backlog drains in ~1.2 s with no audible seam. Between ops the
// path is exact passthrough with zero added latency.
//
// Sans-IO, single-threaded by contract: the pump owns it, tests drive
// the identical object in virtual time.

import Foundation
import LyteWire

public struct AudioAccelerateConfig: Sendable {
    public var channels = AudioWire.channels
    /// Waveform-period search bounds, frames: 2.5–10 ms at 48 kHz —
    /// pitch fundamentals ≥ 100 Hz; lower bass rides its harmonics'
    /// self-similarity, exactly as NetEQ's bounded search does.
    public var minPeriodFrames = 120
    public var maxPeriodFrames = 480
    /// Sustained speedup bound, percent of realtime.
    public var maxRatePercent = 5
    /// Minimum normalized cross-correlation to cut. Below it the op
    /// defers (a transient is passing) — drain resumes one gather
    /// later rather than tearing the waveform.
    public var minCorrelation = 0.5

    public init() {}

    /// One operation's working set: search span + crossfade source.
    public var gatherFrames: Int { 2 * maxPeriodFrames }
}

public struct AudioAccelerateStats: Sendable {
    public var inputFrames: UInt64 = 0
    public var outputFrames: UInt64 = 0
    /// Frames excised — the drained backlog, in samples.
    public var framesRemoved: UInt64 = 0
    public var removalOps: UInt64 = 0
    /// Ops that found no self-similar period (transient) and deferred.
    public var opsDeferredLowCorrelation: UInt64 = 0
    /// The counter the books quote: backlog drained, in milliseconds.
    public var millisecondsDrained: UInt64 {
        framesRemoved * 1_000 / UInt64(AudioWire.sampleRate)
    }

    public init() {}
}

public final class AudioAccelerator {
    public let config: AudioAccelerateConfig
    public private(set) var stats = AudioAccelerateStats()

    /// Interleaved gather FIFO; `head` is a float index into it.
    private var fifo: [Float] = []
    private var head = 0
    /// The rate bucket, frames. Starts full so the first engage acts
    /// immediately; capped at one period so idle time can never bank
    /// a burst beyond one instantaneous cut.
    private var budgetFrames: Double

    public init(config: AudioAccelerateConfig = AudioAccelerateConfig()) {
        self.config = config
        self.budgetFrames = Double(config.maxPeriodFrames)
    }

    /// Frames currently gathered (transient, ≤ gatherFrames) — the
    /// pump counts these into the depth the receiver judges.
    public var pendingFrames: Int { (fifo.count - head) / config.channels }

    /// One pump step: decoded PCM in, ring-ready PCM out. Not
    /// accelerating (and nothing gathered): exact passthrough, zero
    /// copies of latency. Accelerating with a funded bucket: gather,
    /// cut, emit.
    public func process(_ pcm: [Float], accelerate: Bool) -> [Float] {
        let frames = pcm.count / config.channels
        stats.inputFrames += UInt64(frames)
        budgetFrames = min(
            budgetFrames + Double(frames) * Double(config.maxRatePercent) / 100,
            Double(config.maxPeriodFrames))

        // Gather only when an op is actually affordable — an unfunded
        // gather would hold audio for nothing.
        let gathering = accelerate
            && budgetFrames >= Double(config.maxPeriodFrames) - 0.5
        if pendingFrames == 0, !gathering {
            stats.outputFrames += UInt64(frames)
            return pcm
        }

        append(pcm)
        var out: [Float] = []
        if gathering {
            if pendingFrames >= config.gatherFrames {
                cutAndEmitAll(into: &out)
            }
            // else: keep gathering — the ring's cushion covers the
            // ≤20 ms hold, and the pump counts it as depth.
        } else {
            emitAll(into: &out)
        }
        stats.outputFrames += UInt64(out.count / config.channels)
        return out
    }

    /// Hands back everything gathered (disengage, starvation, or the
    /// pump's ring-nearly-dry override) — nothing is ever stranded.
    public func flush() -> [Float] {
        var out: [Float] = []
        emitAll(into: &out)
        stats.outputFrames += UInt64(out.count / config.channels)
        return out
    }

    // MARK: - Interior

    private func append(_ pcm: [Float]) {
        if head == fifo.count {
            fifo.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 32_768 {
            fifo.removeFirst(head)
            head = 0
        }
        fifo.append(contentsOf: pcm)
    }

    private func emitAll(into out: inout [Float]) {
        guard head < fifo.count else { return }
        out.append(contentsOf: fifo[head...])
        fifo.removeAll(keepingCapacity: true)
        head = 0
    }

    /// One WSOLA op at the gather's head, then everything drains: find
    /// the best period T, crossfade x[0..T) into x[T..2T) (T frames
    /// vanish), pass the rest through byte-exact.
    private func cutAndEmitAll(into out: inout [Float]) {
        let channels = config.channels
        let pending = pendingFrames
        let maxT = min(config.maxPeriodFrames, pending / 2)

        guard let best = bestPeriod(upTo: maxT),
              best.correlation >= config.minCorrelation,
              budgetFrames >= Double(best.period) else {
            stats.opsDeferredLowCorrelation += 1
            emitAll(into: &out)
            return
        }

        let period = best.period
        for frame in 0..<period {
            // Raised-cosine ramp, endpoint-free: full-quality
            // crossfade over the whole excised period.
            let w = Float(0.5 * (1 - cos(Double.pi
                * Double(frame + 1) / Double(period + 1))))
            let a = head + frame * channels
            let b = head + (frame + period) * channels
            for channel in 0..<channels {
                out.append(fifo[a + channel] * (1 - w)
                    + fifo[b + channel] * w)
            }
        }
        head += 2 * period * channels
        emitAll(into: &out)
        budgetFrames -= Double(period)
        stats.framesRemoved += UInt64(period)
        stats.removalOps += 1
    }

    /// Normalized autocorrelation on a mono mixdown of the gathered
    /// head: coarse stride-4 sweep, ±3 refine — the classic bounded
    /// pitch search. Silence on both sides of a lag counts as
    /// perfectly self-similar (cutting silence is free); one-sided
    /// silence counts as zero (never splice sound into quiet).
    private func bestPeriod(upTo maxT: Int)
        -> (period: Int, correlation: Double)? {
        guard maxT >= config.minPeriodFrames else { return nil }
        let channels = config.channels
        let span = 2 * maxT
        var mono = [Double](repeating: 0, count: span)
        for frame in 0..<span {
            var acc: Float = 0
            let base = head + frame * channels
            for channel in 0..<channels { acc += fifo[base + channel] }
            mono[frame] = Double(acc) / Double(channels)
        }

        func correlation(_ period: Int) -> Double {
            var num = 0.0, e1 = 0.0, e2 = 0.0
            for i in 0..<period {
                let a = mono[i], b = mono[i + period]
                num += a * b
                e1 += a * a
                e2 += b * b
            }
            let quiet = 1e-9 * Double(period)
            if e1 < quiet, e2 < quiet { return 1 }        // silence
            let denominator = (e1 * e2).squareRoot()
            return denominator > 0 ? num / denominator : 0
        }

        var bestT = 0
        var bestC = -Double.infinity
        var t = config.minPeriodFrames
        while t <= maxT {
            let c = correlation(t)
            if c > bestC { bestC = c; bestT = t }
            t += 4
        }
        let coarse = bestT
        let refineLow = max(config.minPeriodFrames, coarse - 3)
        let refineHigh = min(maxT, coarse + 3)
        for t in refineLow...refineHigh where t != coarse {
            let c = correlation(t)
            if c > bestC { bestC = c; bestT = t }
        }
        return (bestT, bestC)
    }
}
