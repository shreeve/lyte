// The client's model of the host clock: the one host↔client mapping the
// session shares, from BeaconEchoResponder's (offset, rtt) samples — a
// min-RTT-gated offset plus a linear-regression skew over a sliding window.
//
// Queuing delay only adds, so only samples within `rttGateMicroseconds` of
// the window's min RTT join the fit. Regression absorbs ~50 ppm consumer
// clock skew. All consumers must read the same instance; divergent
// estimates are an A/V sync error. No clock is read here: time advances
// through the samples' own coordinates, and the model is usable from its
// first sample.

import Foundation
import LyteClientSession
import LyteWire

public final class HostClockModel: @unchecked Sendable {
    public struct Config: Sendable {
        /// Sliding-window length over the samples' client-time coordinates.
        public var windowMicroseconds: Int64
        /// A sample joins the fit iff rtt ≤ (window min RTT) + this gate.
        public var rttGateMicroseconds: Int64
        /// Fewer accepted samples (or zero time spread) leaves skew at 0.
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

    /// One coherent snapshot of the fit, so many mappings use one fit.
    public struct Estimate: Sendable {
        /// client − host µs at `anchor`. Huge values are normal: the
        /// monotonic epochs differ by boot time.
        public var offsetMicroseconds: Int64
        /// The newest accepted sample's client time: the fit's origin.
        public var anchor: ClientTimestamp
        /// d(offset)/d(clientTime) × 10⁶; 0 when the fit is offset-only.
        public var skewPartsPerMillion: Double
        /// RMS deviation of the accepted samples about the fit.
        public var residualRmsMicroseconds: Double
        /// Worst single accepted-sample deviation from the fit.
        public var residualMaxMicroseconds: Double
        /// How many window samples passed the min-RTT gate into the fit.
        public var acceptedSamples: Int
        /// Total samples currently in the window (gated ones included).
        public var windowSamples: Int
        /// The window's min RTT.
        public var minRttMicroseconds: Int64

        /// Host timestamp → predicted client-monotonic instant: solves
        /// tc = th + offset + b·(tc − anchor) exactly for tc.
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
    /// The fit of the current window; ingest invalidates it.
    private var cachedEstimate: Estimate??

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Feeds one raw sample. Eviction keys on the newest coordinate seen,
    /// so mild reordering is harmless.
    public func ingest(_ sample: ClockSample) {
        lock.lock()
        defer { lock.unlock() }
        cachedEstimate = nil
        window.append(sample)
        if sample.measuredAt.microseconds > newestMicroseconds {
            newestMicroseconds = sample.measuredAt.microseconds
        }
        if newestMicroseconds > UInt64(config.windowMicroseconds) {
            let horizon = newestMicroseconds &- UInt64(config.windowMicroseconds)
            window.removeAll { $0.measuredAt.microseconds < horizon }
        }
    }

    /// The newest `limit` samples still in the window, in arrival order.
    public func recentSamples(_ limit: Int) -> [ClockSample] {
        lock.lock()
        defer { lock.unlock() }
        return Array(window.suffix(max(0, limit)))
    }

    /// The current fit, or nil before the first sample; cached per window
    /// change.
    public func estimate() -> Estimate? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedEstimate { return cachedEstimate }
        let fit = Self.fit(window, config: config)
        cachedEstimate = .some(fit)
        return fit
    }

    private static func fit(
        _ samples: [ClockSample], config: Config
    ) -> Estimate? {
        guard !samples.isEmpty else { return nil }

        let minRtt = samples.lazy.map(\.rttMicroseconds).min()!
        let accepted = samples.filter {
            $0.rttMicroseconds <= minRtt &+ config.rttGateMicroseconds
        }
        let anchorSample = accepted.max {
            $0.measuredAt.microseconds < $1.measuredAt.microseconds
        }!
        let anchor = anchorSample.measuredAt

        // Center x and y on the same anchor sample so rounding is
        // ingest-order-independent; offsets are ~10¹¹ µs and centering
        // keeps every Double exact.
        let offset0 = anchorSample.offsetMicroseconds
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
