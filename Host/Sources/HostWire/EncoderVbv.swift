// EncoderVbv: turns the estimator's live `frameByteCeiling` into encoder
// rate-control directives, so frames shrink with the pacer's rate instead
// of overstaying the client's completion presumption. Sans-IO: `note`
// returns a directive the shell applies before the next frame (on the
// native VAAPI seat, RC/HRD misc buffers: no encoder reset, no IDR).
//
// CLEAN PATH: while ceilingRate R = 8×C/B ≥ (1 − deadband) × baselineMax
// the opening posture rides with no directives; leaving a squeeze, one
// sustain-gated RESTORE puts it back exactly.
//
// SQUEEZE: below that, the posture lands on R itself:
//   max = R;  C' = R×B/8, B = min(2/fps, 25 ms)
//   vbv = min(baselineVbv, k × 8×C'), k by R/baselineMax (≥80% ⇒ 4,
//         ≥65% ⇒ 3, ≥50% ⇒ 2, deeper ⇒ 1).
// Nothing exceeds the opening posture, whose VBV is the one-FEC-group
// guard.
//
// HYSTERESIS: a TIGHTEN is immediate but only when R × (1 + deadband) is
// still below the applied max. A LOOSEN is wanted only by a clean ceiling
// or R > max × (1 + deadband); it fires after the want held continuously
// for the sustain and the rise hold passed, and lands on the window's
// MINIMUM ceiling, so a saw-tooth hunt parks. A short sustain chases every
// probe climb into a floor limit cycle.

/// What the shell pushes into the encoder when the policy says the
/// rate-control posture must move.
public struct EncoderRateDirective: Equatable, Sendable {
    /// Why the posture moved (the logs' cause tag).
    public enum Kind: String, Sendable {
        /// The posture stepped down (engage or a material fall).
        case tighten
        /// A within-squeeze climb (the sustained loosening).
        case loosen
        /// The squeeze→clean return to the opening posture.
        case restore
    }
    /// Always nil: the posture is a capped VBR with no average.
    public var averageBitsPerSecond: Int? { nil }
    /// New hard cap, bits/s (the encoder's VBR envelope).
    public var maxBitsPerSecond: Int
    /// New VBV budget, bits: the encoder's HRD buffer is bounded by it
    /// (EncoderHrd), so no frame outgrows the protectable ceiling.
    public var vbvBits: Int
    /// The live frameByteCeiling that produced this directive (evidence
    /// for the logs; the live gate reads frame sizes against it).
    public var frameByteCeiling: Int
    public var kind: Kind
}

public struct EncoderVbvConfig: Sendable {
    public var fps: Int
    /// The opening posture; directives never exceed it.
    public var baselineMaxBitsPerSecond: Int
    /// The opening VBV: the one-FEC-group guard ceiling.
    public var baselineVbvBits: Int

    /// `baselineAverageBitsPerSecond`, `rungsPerOctave` and `exactTighten`
    /// name the one posture there is (nil, 2, true); any other value traps.
    public init(
        fps: Int,
        baselineAverageBitsPerSecond: Int? = nil,
        baselineMaxBitsPerSecond: Int,
        baselineVbvBits: Int,
        rungsPerOctave: Int = 2,
        exactTighten: Bool = true
    ) {
        precondition(fps > 0)
        precondition(baselineMaxBitsPerSecond > 0)
        precondition(
            baselineAverageBitsPerSecond == nil && rungsPerOctave == 2
                && exactTighten,
            "only the capped, exact posture exists"
        )
        self.fps = fps
        self.baselineMaxBitsPerSecond = baselineMaxBitsPerSecond
        self.baselineVbvBits = baselineVbvBits
    }
}

public final class EncoderVbvPolicy {
    /// The clean boundary is (1 − deadband) × baselineMax, and a move
    /// inside the applied max's ± deadband parks.
    public static let deadbandFraction = 0.10
    /// A loosening also waits this long after the last apply; a
    /// tightening never waits.
    public static let riseHoldNS: UInt64 = 500_000_000
    /// A loosening fires only after the ceiling wanted it continuously
    /// this long, so a saw-tooth hunt parks instead of cycling.
    public static let riseSustainNS: UInt64 = 10_000_000_000

    public let config: EncoderVbvConfig
    /// What the encoder is currently running: seeded from the opening
    /// posture, moved by every emitted directive.
    public private(set) var appliedMaxBitsPerSecond: Int
    public private(set) var appliedVbvBits: Int
    public private(set) var directivesIssued = 0
    /// True while a squeeze owns the posture; false on the clean path.
    public private(set) var squeezeEngaged = false
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
        appliedMaxBitsPerSecond = config.baselineMaxBitsPerSecond
        appliedVbvBits = config.baselineVbvBits
    }

    /// The clean/squeezed boundary: a ceiling rate at or above this keeps
    /// up with the opening posture.
    public var cleanPathRateBitsPerSecond: Int {
        Int(Double(config.baselineMaxBitsPerSecond)
            * (1.0 - Self.deadbandFraction))
    }

    /// VBV budget windows by squeeze depth: deep squeezes get a
    /// single-frame VBV; mild ones may borrow across frames while the rate
    /// cap holds the average.
    private static func vbvBudgetWindows(squeezeFraction: Double) -> Int {
        if squeezeFraction >= 0.80 { return 4 }
        if squeezeFraction >= 0.65 { return 3 }
        if squeezeFraction >= 0.50 { return 2 }
        return 1
    }

    private struct Posture: Equatable {
        var max: Int
        var vbv: Int
    }

    private func posture(atRate rate: Int) -> Posture {
        let budgetNS = RateEstimator.frameBudgetNS(fps: config.fps)
        let rateCeiling = Int(UInt64(rate) * budgetNS / (8 * 1_000_000_000))
        let windows = Self.vbvBudgetWindows(
            squeezeFraction: Double(rate)
                / Double(config.baselineMaxBitsPerSecond)
        )
        return Posture(
            max: min(config.baselineMaxBitsPerSecond, rate),
            vbv: min(config.baselineVbvBits, max(windows * rateCeiling * 8, 8))
        )
    }

    /// Applies `posture` and wraps it as a directive, or absorbs it when
    /// the encoder already runs exactly these params.
    private func emit(
        _ posture: Posture, kind: EncoderRateDirective.Kind,
        frameByteCeiling: Int, now: UInt64, ceilingMoved: Bool
    ) -> EncoderRateDirective? {
        guard posture != Posture(
            max: appliedMaxBitsPerSecond, vbv: appliedVbvBits
        ) else {
            if ceilingMoved { rateMovesAbsorbed += 1 }
            return nil
        }
        appliedMaxBitsPerSecond = posture.max
        appliedVbvBits = posture.vbv
        lastAppliedAt = now
        directivesIssued += 1
        return EncoderRateDirective(
            maxBitsPerSecond: posture.max,
            vbvBits: posture.vbv,
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
        func deadband(_ rate: Int) -> Int {
            Int(Double(rate) * Self.deadbandFraction)
        }

        let clean = ceilingRate >= cleanPathRateBitsPerSecond
        if clean, !squeezeEngaged {
            looserWantedSince = nil
            return absorb()
        }

        // TIGHTEN: the first look below the clean boundary engages at
        // once; engaged, only a material fall retunes.
        if !clean, !squeezeEngaged
            || ceilingRate + deadband(ceilingRate) < appliedMaxBitsPerSecond {
            squeezeEngaged = true
            looserWantedSince = nil
            return emit(
                posture(atRate: ceilingRate), kind: .tighten,
                frameByteCeiling: frameByteCeiling, now: now,
                ceilingMoved: ceilingMoved
            )
        }

        // LOOSEN: the want must hold for the sustain window and targets
        // the window's MINIMUM ceiling.
        let wantsLooser = clean || ceilingRate
            > appliedMaxBitsPerSecond + deadband(appliedMaxBitsPerSecond)
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
        guard now &- since >= Self.riseSustainNS else { return absorb() }
        if let last = lastAppliedAt, now &- last < Self.riseHoldNS {
            return absorb()
        }
        looserWantedSince = nil

        if looserMinCeilingRate >= cleanPathRateBitsPerSecond {
            // Sustained clean: the one restore closes the episode.
            squeezeEngaged = false
            return emit(
                Posture(
                    max: config.baselineMaxBitsPerSecond,
                    vbv: config.baselineVbvBits
                ),
                kind: .restore,
                frameByteCeiling: frameByteCeiling, now: now,
                ceilingMoved: ceilingMoved
            )
        }
        return emit(
            posture(atRate: looserMinCeilingRate), kind: .loosen,
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
