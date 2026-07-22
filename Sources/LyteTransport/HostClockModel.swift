// CL-10: the client's model of the host clock (timing pillar §2, client
// plan CL-10). BeaconEchoResponder retains raw (offset, rtt) samples; this
// model turns them into the one host↔client mapping the session shares:
// a min-RTT-gated offset plus a linear-regression skew term over a sliding
// window of client time.
//
// Why min-gating: queuing delay only ever ADDS, so the min-RTT edge of the
// window tracks the true path. On the reference Wi-Fi path the floor is
// 5–10 ms while power-save spikes run 55–100 ms — and a spiked sample's
// offset is polluted by tens of ms of one-sided queuing. Samples within
// `rttGateMicroseconds` of the window's min RTT are trusted for the fit;
// the rest stay in the window only to keep the min honest.
//
// Why regression: consumer clocks skew ~50 ppm ≈ 3 ms/min (audio doc §1).
// A 30 s window fits that to well under the T gate's 1 ms residual. The
// two consumers — the M7 audio rate-correction term and the CL-12 video
// presentation mapper — must read the SAME instance; divergent estimates
// are an A/V sync error by definition (timing pillar §2).
//
// No clock is read here: time advances only through the samples' own
// client-monotonic coordinates, so tests replay synthetic traces
// deterministically and the model is ready from its very first sample
// (frame 1 after idle must be mappable without a warm-up wait).

import Foundation
import LyteWire

public final class HostClockModel: @unchecked Sendable {
    public struct Config: Sendable {
        /// Sliding-window length over the samples' client-time coordinates.
        public var windowMicroseconds: Int64
        /// A sample joins the fit iff rtt ≤ (window min RTT) + this gate.
        public var rttGateMicroseconds: Int64
        /// Fewer accepted samples than this (or zero time spread) degrades
        /// the fit to offset-only: skew is left at 0 rather than fit to
        /// noise.
        public var minimumSamplesForSkew: Int

        public init(
            windowMicroseconds: Int64 = 30_000_000,
            rttGateMicroseconds: Int64 = 2_000,
            minimumSamplesForSkew: Int = 3
        ) {
            self.windowMicroseconds = windowMicroseconds
            self.rttGateMicroseconds = rttGateMicroseconds
            self.minimumSamplesForSkew = minimumSamplesForSkew
        }
    }

    /// One coherent snapshot of the fit. `map` lives here so a consumer
    /// holding an Estimate maps many timestamps against ONE fit instead of
    /// racing the model's window between calls.
    public struct Estimate: Sendable {
        /// client − host µs at `anchor` (clientTime ≈ hostTime + offset).
        /// Huge-but-stable values are normal: CLOCK_MONOTONIC epochs
        /// differ across ends by boot time.
        public var offsetMicroseconds: Int64
        /// The newest accepted sample's client time — the fit's origin, so
        /// mapping near "now" extrapolates over milliseconds, not the
        /// whole window.
        public var anchor: ClientTimestamp
        /// d(offset)/d(clientTime) × 10⁶; 0 when the fit is offset-only.
        public var skewPartsPerMillion: Double
        /// RMS deviation of the accepted samples about the fit — the
        /// telemetry the T gate reads (< 1 ms after 30 s).
        public var residualRmsMicroseconds: Double
        /// Worst single accepted-sample deviation from the fit.
        public var residualMaxMicroseconds: Double
        /// How many window samples passed the min-RTT gate into the fit.
        public var acceptedSamples: Int
        /// Total samples currently in the window (gated ones included).
        public var windowSamples: Int
        /// The window's min RTT — the gate's edge.
        public var minRttMicroseconds: Int64

        /// Host media/capture timestamp → predicted client-monotonic
        /// instant (the CL-12 presentation mapper's primitive).
        ///
        /// offset(tc) = offset + b·(tc − anchor) with b = skew, and the
        /// mapping solves tc = th + offset(tc) for tc. b is parts-per-
        /// million, so the division is a formality, but it keeps the
        /// solution exact instead of one-Newton-step approximate.
        public func map(_ host: HostTimestamp) -> ClientTimestamp {
            let approximate = host.microseconds
                &+ UInt64(bitPattern: offsetMicroseconds)
            let b = skewPartsPerMillion / 1_000_000
            let delta = Double(Int64(bitPattern:
                approximate &- anchor.microseconds))
            let correction = (b * delta) / (1 - b)
            return ClientTimestamp(microseconds: approximate
                &+ UInt64(bitPattern: Int64(correction.rounded())))
        }
    }

    private let config: Config
    private let lock = NSLock()
    private var window: [ClockSample] = []
    private var newestMicroseconds: UInt64 = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Feeds one raw sample (BeaconEchoResponder's onClockSample in
    /// production). Samples whose coordinate has fallen out of the window
    /// evict here; mild reordering (the mirror can arrive late) is
    /// harmless because eviction keys on the newest coordinate seen.
    public func ingest(_ sample: ClockSample) {
        lock.lock()
        defer { lock.unlock() }
        window.append(sample)
        if sample.measuredAt.microseconds > newestMicroseconds {
            newestMicroseconds = sample.measuredAt.microseconds
        }
        if newestMicroseconds > UInt64(config.windowMicroseconds) {
            let horizon = newestMicroseconds &- UInt64(config.windowMicroseconds)
            window.removeAll { $0.measuredAt.microseconds < horizon }
        }
    }

    /// The current fit, or nil before the first sample. Cheap at beacon
    /// cadence: the window holds ≤ ~30 samples at 1 Hz.
    public func estimate() -> Estimate? {
        lock.lock()
        let samples = window
        lock.unlock()
        guard !samples.isEmpty else { return nil }

        let minRtt = samples.lazy.map(\.rttMicroseconds).min()!
        let accepted = samples.filter {
            $0.rttMicroseconds <= minRtt &+ config.rttGateMicroseconds
        }
        let anchor = accepted.max {
            $0.measuredAt.microseconds < $1.measuredAt.microseconds
        }!.measuredAt

        // Center the regression at the anchor (x) and the newest accepted
        // offset (y): offsets are ~10¹¹ µs when boot epochs differ, and
        // centering keeps every Double exact.
        let offset0 = accepted.last!.offsetMicroseconds
        let xs = accepted.map { Double($0.measuredAt.microseconds(since: anchor)) }
        let ys = accepted.map { Double($0.offsetMicroseconds &- offset0) }
        let n = Double(accepted.count)
        let xBar = xs.reduce(0, +) / n
        let yBar = ys.reduce(0, +) / n
        var sxx = 0.0
        var sxy = 0.0
        for (x, y) in zip(xs, ys) {
            sxx += (x - xBar) * (x - xBar)
            sxy += (x - xBar) * (y - yBar)
        }
        let slope: Double = (accepted.count >= config.minimumSamplesForSkew
                             && sxx > 0) ? sxy / sxx : 0
        let interceptCentered = yBar - slope * xBar   // offset − offset0 at x = 0

        var sumSquares = 0.0
        var worst = 0.0
        for (x, y) in zip(xs, ys) {
            let r = y - (interceptCentered + slope * x)
            sumSquares += r * r
            worst = max(worst, abs(r))
        }

        return Estimate(
            offsetMicroseconds: offset0 &+ Int64(interceptCentered.rounded()),
            anchor: anchor,
            skewPartsPerMillion: slope * 1_000_000,
            residualRmsMicroseconds: (sumSquares / n).squareRoot(),
            residualMaxMicroseconds: worst,
            acceptedSamples: accepted.count,
            windowSamples: samples.count,
            minRttMicroseconds: minRtt)
    }

    /// One-shot mapping against the current fit; nil before the first
    /// sample. Consumers mapping in a loop should snapshot `estimate()`.
    public func map(_ host: HostTimestamp) -> ClientTimestamp? {
        estimate()?.map(host)
    }
}
