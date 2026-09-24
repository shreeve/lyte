// EncoderVbv: turns the estimator's live `frameByteCeiling` into encoder
// rate-control directives, so frames shrink with the pacer's rate instead
// of overstaying the client's completion presumption. Sans-IO: `note`
// returns a directive the shell applies before the next frame (on the
// native VAAPI seat, RC/HRD misc buffers: no encoder reset, no IDR).
//
// CLEAN PATH: while ceilingRate (8×C/B) ≥ (1 − deadband) × baselineMax the
// opening recipe rides with no directives; leaving a squeeze, one
// sustain-gated RESTORE puts it back. Below that the rung ladder engages.
//
// RUNG LADDER: rung_i = baselineMax × 2^(−i/rungsPerOctave); the posture
// takes the smallest rung ≥ the ceiling rate (never below what the wire
// delivers; the pacer enforces the exact rate). Moves inside the applied
// band are absorbed. At rung rate R:
//   max = min(baselineMax, R); avg = min(baselineAvg, R) (CBR only)
//   C'  = R×B/8, B = min(2/fps, 25 ms)
//   vbv = min(baselineVbv, k × 8×C'), k by R/baselineMax (≥80% ⇒ 4,
//         ≥65% ⇒ 3, ≥50% ⇒ 2, deeper ⇒ 1).
// Nothing exceeds the opening posture; live baselines carry the one-FEC-
// group guard as their VBV, so rung 0 and the restore land on it exactly.
//
// HYSTERESIS: TIGHTEN is immediate but only when the ceiling is materially
// inside a lower band (ceilingRate × (1 + deadband)). LOOSEN fires only
// after the ceiling wanted it continuously for `riseSustainNS` and the
// rise hold passed, then jumps to the rung of the window's MINIMUM
// ceiling, so a saw-tooth hunt parks. A short sustain chases every probe
// climb into a floor limit cycle.

/// What the shell pushes into the encoder when the policy says the
/// rate-control posture must move.
public struct EncoderRateDirective: Equatable, Sendable {
    /// Why the posture moved (the logs' cause tag).
    public enum Kind: String, Sendable {
        /// The posture stepped down (engage or a deeper rung).
        case tighten
        /// A within-squeeze rung climb (the sustained loosening).
        case loosen
        /// The squeeze→clean return to the opening recipe.
        case restore
    }
    /// New average bitrate, bits/s. Nil = leave the average untouched —
    /// a capped (VBR) posture has none; setting one would change the
    /// rate-control mode, not just its numbers.
    public var averageBitsPerSecond: Int?
    /// New hard cap, bits/s (the encoder's VBR envelope).
    public var maxBitsPerSecond: Int
    /// New VBV budget, bits: the encoder's HRD buffer is bounded by it
    /// (EncoderHrd), so no frame outgrows the protectable ceiling.
    public var vbvBits: Int
    /// The live frameByteCeiling that produced this directive (evidence
    /// for the logs; the live gate reads frame sizes against it).
    public var frameByteCeiling: Int
    public var kind: Kind

    public init(
        averageBitsPerSecond: Int?, maxBitsPerSecond: Int, vbvBits: Int,
        frameByteCeiling: Int, kind: Kind
    ) {
        self.averageBitsPerSecond = averageBitsPerSecond
        self.maxBitsPerSecond = maxBitsPerSecond
        self.vbvBits = vbvBits
        self.frameByteCeiling = frameByteCeiling
        self.kind = kind
    }
}

public struct EncoderVbvConfig: Sendable {
    public var fps: Int
    /// The opening rate-control posture; directives never exceed it. CBR
    /// opens with avg = max = the bitrate and a single-frame VBV;
    /// capped-CQ opens with only the max cap. Live configs carry the
    /// one-FEC-group guard ceiling as the baseline VBV.
    public var baselineAverageBitsPerSecond: Int?
    public var baselineMaxBitsPerSecond: Int
    public var baselineVbvBits: Int?
    /// The clean boundary is (1 − deadband) × baselineMax, and a tighten
    /// fires only when the ceiling is this fraction INSIDE a lower band.
    public var deadbandFraction: Double
    /// A loosening also waits this long after the last apply; a
    /// tightening never waits.
    public var riseHoldNS: UInt64
    /// A loosening fires only after the ceiling wanted it CONTINUOUSLY
    /// this long, so a saw-tooth hunt parks instead of cycling.
    public var riseSustainNS: UInt64
    /// Rungs per halving of the recipe cap: 1 = rung_i = cap/2^i (slack
    /// ≤ 2×); 2 = cap × 2^(−i/2) (slack ≤ √2, via stdlib square root, no
    /// libm). Only 1 and 2 are defined.
    public var rungsPerOctave: Int
    /// Land every TIGHTEN exactly on the ceiling rate instead of the rung
    /// above, and retune on material within-band falls. Only sound when a
    /// directive costs no IDR (the native seat); the estimator's 500 ms
    /// fall limiter bounds extra directives to ~2/s. Both edges are then
    /// judged by rate: a material within-band RISE arms the loosen want,
    /// and the sustained climb lands on the held-minimum ceiling, else a
    /// mid-band exact posture would ratchet down.
    public var exactTighten: Bool

    public init(
        fps: Int,
        baselineAverageBitsPerSecond: Int? = nil,
        baselineMaxBitsPerSecond: Int,
        baselineVbvBits: Int? = nil,
        deadbandFraction: Double = 0.10,
        riseHoldNS: UInt64 = 500_000_000,
        riseSustainNS: UInt64 = 10_000_000_000,
        rungsPerOctave: Int = 1,
        exactTighten: Bool = false
    ) {
        precondition(fps > 0)
        precondition(baselineMaxBitsPerSecond > 0)
        precondition(
            rungsPerOctave == 1 || rungsPerOctave == 2,
            "only the halving (1) and half-rung (2) ladders are defined"
        )
        self.fps = fps
        self.baselineAverageBitsPerSecond = baselineAverageBitsPerSecond
        self.baselineMaxBitsPerSecond = baselineMaxBitsPerSecond
        self.baselineVbvBits = baselineVbvBits
        self.deadbandFraction = deadbandFraction
        self.riseHoldNS = riseHoldNS
        self.riseSustainNS = riseSustainNS
        self.rungsPerOctave = rungsPerOctave
        self.exactTighten = exactTighten
    }
}

public final class EncoderVbvPolicy {
    public let config: EncoderVbvConfig
    /// What the encoder is currently running: seeded from the opening
    /// posture, moved by every emitted directive.
    public private(set) var appliedAverageBitsPerSecond: Int?
    public private(set) var appliedMaxBitsPerSecond: Int
    public private(set) var appliedVbvBits: Int?
    public private(set) var directivesIssued = 0
    /// True while the rung ladder owns the posture; false on the clean
    /// path.
    public var squeezeEngaged: Bool { appliedRungIndex != nil }
    /// The rung the ladder currently sits on (nil while clean).
    public private(set) var appliedRungIndex: Int?
    /// Ceiling moves that produced no directive (the pacer carried them
    /// alone).
    public private(set) var rateMovesAbsorbed = 0
    private var lastAppliedAt: UInt64?
    private var lastPolledCeilingRate: Int?
    /// When the ceiling began wanting a looser posture without
    /// interruption, and the smallest ceiling rate seen since.
    private var looserWantedSince: UInt64?
    private var looserMinCeilingRate = Int.max

    public init(config: EncoderVbvConfig) {
        self.config = config
        self.appliedAverageBitsPerSecond = config.baselineAverageBitsPerSecond
        self.appliedMaxBitsPerSecond = config.baselineMaxBitsPerSecond
        self.appliedVbvBits = config.baselineVbvBits
    }

    /// The clean/squeezed boundary: a ceiling rate at or above this keeps
    /// up with the opening recipe.
    public var cleanPathRateBitsPerSecond: Int {
        Int(Double(config.baselineMaxBitsPerSecond)
            * (1.0 - config.deadbandFraction))
    }

    /// VBV budget windows by squeeze depth (`squeezeFraction` = rungRate
    /// / baselineMax): deep squeezes get a single-frame VBV; mild ones
    /// may borrow across frames while the rate cap holds the average.
    public static func vbvBudgetWindows(squeezeFraction: Double) -> Int {
        if squeezeFraction >= 0.80 { return 4 }
        if squeezeFraction >= 0.65 { return 3 }
        if squeezeFraction >= 0.50 { return 2 }
        return 1
    }

    /// The smallest rung of the recipe cap that still covers `rate`
    /// (round UP — the posture never sits below the wire).
    public func rungIndex(for rate: Int) -> Int {
        let floor = max(rate, 1)
        var index = 0
        while index < 40 * config.rungsPerOctave
            && rungRate(atIndex: index + 1) >= floor {
            index += 1
        }
        return index
    }

    /// The rate rung `index` carries, bits/s: cap × 2^(−i/n), n =
    /// rungsPerOctave. Whole octaves are exact integer halvings; a
    /// half-rung is rung/√2 rounded to the nearest bit/s.
    public func rungRate(atIndex index: Int) -> Int {
        var rung = config.baselineMaxBitsPerSecond
        for _ in 0..<(index / config.rungsPerOctave) { rung /= 2 }
        if index % config.rungsPerOctave == 0 { return max(rung, 1) }
        let half = Double(rung) * (0.5 as Double).squareRoot()
        return max(Int(half.rounded()), 1)
    }

    private struct Posture: Equatable {
        var average: Int?
        var max: Int
        var vbv: Int?
    }

    private var appliedPosture: Posture {
        Posture(
            average: appliedAverageBitsPerSecond,
            max: appliedMaxBitsPerSecond,
            vbv: appliedVbvBits
        )
    }

    private func posture(atRungIndex index: Int) -> Posture {
        posture(atRate: rungRate(atIndex: index))
    }

    /// The header's rung mapping at an arbitrary rate (exact mode lands
    /// here directly, off the ladder).
    private func posture(atRate rate: Int) -> Posture {
        let budgetNS = RateEstimator.frameBudgetNS(fps: config.fps)
        let rungCeiling = Int(
            UInt64(rate) * budgetNS / (8 * 1_000_000_000)
        )
        let windows = Self.vbvBudgetWindows(
            squeezeFraction: Double(rate)
                / Double(config.baselineMaxBitsPerSecond)
        )
        return Posture(
            average: config.baselineAverageBitsPerSecond
                .map { min($0, rate) },
            max: min(config.baselineMaxBitsPerSecond, rate),
            vbv: min(
                config.baselineVbvBits ?? Int.max,
                max(windows * rungCeiling * 8, 8)
            )
        )
    }

    private var baselinePosture: Posture {
        // Capped-CQ's "no VBV" cannot be pushed back through the
        // wrapper (rc_buffer_size > 0 only): one second at the
        // baseline cap is the nearest expressible recipe.
        Posture(
            average: config.baselineAverageBitsPerSecond,
            max: config.baselineMaxBitsPerSecond,
            vbv: config.baselineVbvBits ?? config.baselineMaxBitsPerSecond
        )
    }

    /// Applies `posture` and wraps it as a directive, or absorbs it when
    /// the encoder already runs exactly these params (rung 0 ≡ baseline).
    private func emit(
        _ posture: Posture, kind: EncoderRateDirective.Kind,
        frameByteCeiling: Int, now: UInt64, ceilingMoved: Bool
    ) -> EncoderRateDirective? {
        guard posture != appliedPosture else {
            if ceilingMoved { rateMovesAbsorbed += 1 }
            return nil
        }
        appliedAverageBitsPerSecond = posture.average
        appliedMaxBitsPerSecond = posture.max
        appliedVbvBits = posture.vbv
        lastAppliedAt = now
        directivesIssued += 1
        return EncoderRateDirective(
            averageBitsPerSecond: posture.average,
            maxBitsPerSecond: posture.max,
            // The wrapper needs a concrete VBV; baselinePosture always
            // carries one, and rung postures min against it.
            vbvBits: posture.vbv ?? config.baselineMaxBitsPerSecond,
            frameByteCeiling: frameByteCeiling,
            kind: kind
        )
    }

    /// Polled once per encode. Returns the directive to apply before this
    /// frame, or nil when the encoder should keep its posture.
    public func note(
        frameByteCeiling: Int, now: UInt64
    ) -> EncoderRateDirective? {
        let ceiling = max(frameByteCeiling, 1)
        let budgetNS = RateEstimator.frameBudgetNS(fps: config.fps)
        // rate = 8C / B, exact integer math over ns (C ≤ ~10⁶ at any
        // plausible ceiling, so the product stays far inside UInt64).
        let ceilingRate = Int(
            UInt64(ceiling) * 8 * 1_000_000_000 / budgetNS
        )
        let ceilingMoved = lastPolledCeilingRate != nil
            && lastPolledCeilingRate != ceilingRate
        lastPolledCeilingRate = ceilingRate
        func absorb() -> EncoderRateDirective? {
            if ceilingMoved { rateMovesAbsorbed += 1 }
            return nil
        }

        let clean = ceilingRate >= cleanPathRateBitsPerSecond

        if clean, !squeezeEngaged {
            looserWantedSince = nil
            return absorb()
        }

        // Engage: the first look below the clean boundary lands on the
        // required rung immediately. Rung 0 equals the baseline, so a
        // marginal squeeze engages silently.
        if !clean, !squeezeEngaged {
            let required = rungIndex(for: ceilingRate)
            appliedRungIndex = required
            looserWantedSince = nil
            return emit(
                config.exactTighten
                    ? posture(atRate: ceilingRate)
                    : posture(atRungIndex: required),
                kind: .tighten,
                frameByteCeiling: frameByteCeiling, now: now,
                ceilingMoved: ceilingMoved
            )
        }

        // Engaged: TIGHTEN first, immediate but margin-gated.
        let appliedIndex = appliedRungIndex ?? 0
        if !clean {
            let margined = ceilingRate
                + Int(Double(ceilingRate) * config.deadbandFraction)
            let bandCrossed = rungIndex(for: margined) > appliedIndex
            // Exact mode also retunes a material within-band fall.
            let materialFall = config.exactTighten
                && margined < appliedMaxBitsPerSecond
            if bandCrossed || materialFall {
                let required = rungIndex(for: ceilingRate)
                appliedRungIndex = required
                looserWantedSince = nil
                return emit(
                    config.exactTighten
                        ? posture(atRate: ceilingRate)
                        : posture(atRungIndex: required),
                    kind: .tighten,
                    frameByteCeiling: frameByteCeiling, now: now,
                    ceilingMoved: ceilingMoved
                )
            }
        }

        // LOOSEN: wanted while the ceiling rides above the applied rung
        // (a clean ceiling wants the restore); the want must hold for
        // the sustain window and targets the window's MINIMUM ceiling.
        // In exact mode a ceiling more than a deadband above the applied
        // max also arms it (the mirror of materialFall).
        let materialRise = config.exactTighten
            && ceilingRate > appliedMaxBitsPerSecond
                + Int(Double(appliedMaxBitsPerSecond)
                    * config.deadbandFraction)
        let wantsLooser = clean
            || rungIndex(for: ceilingRate) < appliedIndex
            || materialRise
        guard wantsLooser else {
            looserWantedSince = nil
            return absorb()
        }
        guard let since = looserWantedSince else {
            looserWantedSince = now
            looserMinCeilingRate = ceilingRate
            return absorb()
        }
        looserMinCeilingRate = min(looserMinCeilingRate, ceilingRate)
        guard now &- since >= config.riseSustainNS else { return absorb() }
        if let last = lastAppliedAt, now &- last < config.riseHoldNS {
            return absorb()
        }
        looserWantedSince = nil

        if looserMinCeilingRate >= cleanPathRateBitsPerSecond {
            // Sustained clean: the one restore closes the episode.
            appliedRungIndex = nil
            return emit(
                baselinePosture, kind: .restore,
                frameByteCeiling: frameByteCeiling, now: now,
                ceilingMoved: ceilingMoved
            )
        }
        // Sustained but still squeezed: climb to the held level (its
        // rung, or exactly the held minimum in exact mode).
        let target = rungIndex(for: looserMinCeilingRate)
        appliedRungIndex = target
        return emit(
            config.exactTighten
                ? posture(atRate: looserMinCeilingRate)
                : posture(atRungIndex: target),
            kind: .loosen,
            frameByteCeiling: frameByteCeiling, now: now,
            ceilingMoved: ceilingMoved
        )
    }
}

/// The HRD (VBV) buffer a native encoder runs for a rate cap: four frames
/// of the cap (what iHD's VBR needs for stable quality), capped at the
/// policy's VBV, which carries the one-FEC-group frame ceiling. Under HRD
/// conformance no frame, IDR included, outgrows what FEC can protect.
public enum EncoderHrd {
    public static let framesOfCap = 4

    public static func bufferBits(
        capBitsPerSecond: Int, fps: Int, vbvBits: Int?
    ) -> Int {
        let window = capBitsPerSecond * framesOfCap / max(fps, 1)
        guard let vbvBits, vbvBits > 0 else { return window }
        return min(window, vbvBits)
    }
}
