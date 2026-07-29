// EncoderVbv: the HS-20 policy that makes the encoder finally consume
// `frameByteCeiling` — the H3 plan's D-1 rung. The named harm (the H2
// gate's run B2): under a sustained squeeze the estimator walks the pacer
// down, but the NVENC encoder never hears about it and keeps emitting
// frames sized for the old rate; oversized frames overstay the client's
// completion presumption at the squeezed pacer, the NACKs sustain rung-3
// verdicts, and the post-release tail sits floor-pinned instead of
// re-converging. The fix is a reconfigure path from the estimator's
// ceiling into the encoder's rate control.
//
// Sans-IO in the house style: no clock, no encoder handle — `note` takes
// the live ceiling and `now`, and returns a directive when the encoder's
// rate-control params should move. The shell (lyte-host's Sink) applies
// it through the CHevcEncode leaf before the next encode; FFmpeg's nvenc
// wrapper turns changed AVCodecContext rate fields into one
// NvEncReconfigureEncoder call. CORRECTION (HS-22, read from the
// wrapper's source; re-verified against pup's exact build for HS-27,
// FFmpeg 8.0.1 nvenc.c reconfig_encoder): that reconfigure is NOT free —
// nvenc.c sets `resetEncoder = 1, forceIDR = 1` for EVERY avg/max/VBV
// delta, unconditionally, and no wrapper option avoids it. NVENC's own
// NvEncReconfigureEncoder supports resetEncoder=0/forceIDR=0 rate moves,
// but the wrapper never issues them and the session handle is private
// wrapper state — there is no honest path to a non-IDR reconfigure
// through this libavcodec. Every directive this policy emits costs a
// full forced IDR; every directive it withholds is an IDR the session
// never pays.
//
// THE CLEAN-PATH RULE (HS-22 — the owner's "moderate quality on a clean
// path" regression). The ceiling-derived rate (8×C/B) is judged against
// the opening recipe's own cap first:
//   • ceilingRate ≥ (1 − deadband) × baselineMax  ⇒  CLEAN. The wire
//     delivers at least the recipe's own rate (within the noise the
//     deadband already declares immaterial): zero directives, the
//     opening recipe rides. Returning from a squeeze, ONE restore
//     directive (sustain-gated, below) puts the recipe back, then
//     silence.
//   • ceilingRate below that                      ⇒  SQUEEZED. The
//     rung ladder engages (below).
//
// THE RUNG LADDER (HS-27 — rate moves must stop minting IDRs). The
// beauty-bar's re-measured red (15.2 IDR/min at 932a4c3, books: 17
// vbv-rung + 13 vbv-tighten + 1 vbv-restore in 150 s) is the estimator
// hunting a saw-tooth across a saturated path while the old policy
// tracked every material move EXACTLY — each track a hidden NVENC reset
// + forced IDR. The truth-probe confirmed the hunt itself is largely the
// estimator's own artifact (slice (b), pending) — but the MULTIPLIER
// (IDRs per rate move) is this policy's to kill, in both worlds. So the
// encoder posture is now QUANTIZED: it may only sit on halving rungs of
// the recipe cap,
//
//   rung_i = baselineMax / 2^i   (rung_0 = the recipe cap itself),
//
// and the applied rung is the SMALLEST rung ≥ the live ceiling-rate
// (round UP: the posture never sits below what the wire delivers, so
// mid-band quality is never squeezed — the PACER enforces the exact
// fine-grained rate, at zero encoder cost, and the backpressure gate
// bounds what a ≤2× posture/pacer mismatch can queue). Every estimator
// move that lands inside the applied rung's band touches nothing: no
// directive, no reset, no IDR — the move is ABSORBED (counted in
// `rateMovesAbsorbed`, the books' proof the new path is riding).
//
// The rung mapping reuses the HS-20/HS-22 derivation at the RUNG rate R:
//   max     = min(baselineMax, R);  avg = min(baselineAvg, R) (CBR only)
//   C'      = R×B/8 (the rung's budget-window ceiling, B = min(2/fps,
//             25 ms) — HS-6)
//   vbvBits = min(baselineVbv, k × 8×C'), k the HS-22 window ladder at
//             R/baselineMax (≥80% ⇒ 4, ≥65% ⇒ 3, ≥50% ⇒ 2, deeper ⇒ 1).
// All params stay CAPS against the opening posture, never pushes above
// it. Note the corollary: rung_0's posture mins back to the baseline
// exactly (live configs always carry a baseline VBV — the HS-25 guard),
// so flapping across the clean boundary is structurally FREE.
//
// ASYMMETRIC HYSTERESIS (the HS-27 core):
//   • TIGHTEN — immediate, as ever (an oversized frame at a squeezed
//     pacer is the harm this policy exists to stop; the estimator's own
//     fall limiter bounds the cadence). A tighten fires only when the
//     ceiling is materially INSIDE a lower band — required rung judged
//     at ceilingRate × (1 + deadband) — so a fall that lands in the
//     applied band, or dithers at a boundary, changes nothing.
//   • LOOSEN — a loosening (mid-squeeze rung climb OR the squeeze→clean
//     restore) fires only after the ceiling has WANTED it continuously
//     for `riseSustainNS` (default 10 s) AND the rise hold has passed,
//     and then jumps to the rung of the MINIMUM ceiling seen across the
//     sustain window (the level the wire actually held, not the
//     freshest optimism). A saw-tooth hunt whose falls recur inside the
//     sustain window can therefore never loosen — the posture PARKS at
//     the hunt's band and the whole hunt costs zero encoder touches —
//     while a genuine recovery climbs rung by rung, one IDR per ~2×,
//     and closes with the one restore once the sustained minimum is
//     clean. Under-posture during the wait is the safe direction
//     (HS-22c's ruling), and the restore path keeps quality loss
//     bounded: the wait rides a rung ABOVE the delivered rate, never
//     below it.
//
// RESTORE. Recovery returns the opening recipe exactly (CBR:
// bit-for-bit — pinned since HS-20; capped-CQ without a baseline VBV
// restores the nearest expressible recipe, one second at the cap —
// the wrapper's reconfigure only reads rc_buffer_size > 0, so a VBV can
// be resized but never removed). Since HS-25 the live baselines carry
// the unprotectable-frame guard's VBV, so the restore returns to the
// guarded posture and can never re-open the >255-shard hole.

/// What the shell pushes into the encoder leaf when the policy says the
/// rate-control posture must move.
public struct EncoderRateDirective: Equatable, Sendable {
    /// Why the posture moved — the IDR books' cause tag, decided by the
    /// policy itself (the sink used to infer it from the numbers).
    public enum Kind: String, Sendable {
        /// The posture stepped down (engage or a deeper rung).
        case tighten
        /// A within-squeeze rung climb (the sustained loosening).
        case loosen
        /// The squeeze→clean return to the opening recipe.
        case restore
    }
    /// New average bitrate, bits/s. Nil = leave the average untouched —
    /// capped-CQ mode has none (FFmpeg zeroes it at open; setting one
    /// would change the rate-control mode, not just its numbers).
    public var averageBitsPerSecond: Int?
    /// New hard cap, bits/s (AVCodecContext.rc_max_rate).
    public var maxBitsPerSecond: Int
    /// New VBV budget, bits (AVCodecContext.rc_buffer_size).
    public var vbvBits: Int
    /// The live frameByteCeiling that produced this directive (evidence
    /// for the logs; the live gate reads frame sizes against it).
    public var frameByteCeiling: Int
    /// The books' cause tag for the IDR this directive will force.
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
    /// The encoder's opening rate-control posture — the ceiling caps
    /// against it, never pushes above it. CBR opens with avg = max =
    /// the configured bitrate and a single-frame VBV; capped-CQ opens
    /// with only the max-rate cap (average and VBV nil). Live configs
    /// carry the HS-25 guard ceiling as the baseline VBV.
    public var baselineAverageBitsPerSecond: Int?
    public var baselineMaxBitsPerSecond: Int
    public var baselineVbvBits: Int?
    /// Relative move below which nothing is judged material: the clean
    /// boundary sits at (1 − deadband) × baselineMax, and a tighten
    /// fires only when the ceiling is this fraction INSIDE a lower
    /// rung's band (boundary dither parks).
    public var deadbandFraction: Double
    /// Every loosening additionally waits this long after the last
    /// apply; a tightening never waits.
    public var riseHoldNS: UInt64
    /// HS-27: a loosening (rung climb or restore) fires only after the
    /// ceiling has wanted it CONTINUOUSLY for this long — a saw-tooth
    /// hunt whose falls recur inside this window can never loosen, so
    /// the posture parks and the hunt costs zero encoder resets.
    public var riseSustainNS: UInt64

    public init(
        fps: Int,
        baselineAverageBitsPerSecond: Int? = nil,
        baselineMaxBitsPerSecond: Int,
        baselineVbvBits: Int? = nil,
        deadbandFraction: Double = 0.10,
        riseHoldNS: UInt64 = 500_000_000,
        riseSustainNS: UInt64 = 10_000_000_000
    ) {
        precondition(fps > 0)
        precondition(baselineMaxBitsPerSecond > 0)
        self.fps = fps
        self.baselineAverageBitsPerSecond = baselineAverageBitsPerSecond
        self.baselineMaxBitsPerSecond = baselineMaxBitsPerSecond
        self.baselineVbvBits = baselineVbvBits
        self.deadbandFraction = deadbandFraction
        self.riseHoldNS = riseHoldNS
        self.riseSustainNS = riseSustainNS
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
    /// True while the rung ladder owns the encoder posture; false while
    /// the opening recipe rides (the HS-22 clean path).
    public private(set) var squeezeEngaged = false
    /// The rung the ladder currently sits on (nil while clean).
    public private(set) var appliedRungIndex: Int?
    /// HS-27 books: estimator moves (the polled ceiling changed) that
    /// produced NO directive — rate moves the pacer carried alone, at
    /// zero encoder resets and zero IDRs. The beauty-bar multiplier is
    /// directivesIssued / (directivesIssued + rateMovesAbsorbed).
    public private(set) var rateMovesAbsorbed = 0
    private var lastAppliedAt: UInt64?
    private var lastPolledCeilingRate: Int?
    /// The sustained-loosening tracker: when the ceiling began wanting
    /// a looser posture without interruption, and the smallest ceiling
    /// rate seen since (the level the wire actually held).
    private var looserWantedSince: UInt64?
    private var looserMinCeilingRate = Int.max

    public init(config: EncoderVbvConfig) {
        self.config = config
        self.appliedAverageBitsPerSecond = config.baselineAverageBitsPerSecond
        self.appliedMaxBitsPerSecond = config.baselineMaxBitsPerSecond
        self.appliedVbvBits = config.baselineVbvBits
    }

    /// The clean/squeezed boundary as a rate: a ceiling-derived rate at
    /// or above this is the wire keeping up with the opening recipe
    /// (within the deadband's own definition of noise) — no caps.
    public var cleanPathRateBitsPerSecond: Int {
        Int(Double(config.baselineMaxBitsPerSecond)
            * (1.0 - config.deadbandFraction))
    }

    /// The multi-frame VBV ladder (HS-22): budget windows of borrowing
    /// by squeeze depth. `squeezeFraction` = rungRate / baselineMax.
    /// Deep squeezes keep HS-20's single-frame tool; mild ones loosen
    /// the per-frame bound while the rate cap holds the average.
    public static func vbvBudgetWindows(squeezeFraction: Double) -> Int {
        if squeezeFraction >= 0.80 { return 4 }
        if squeezeFraction >= 0.65 { return 3 }
        if squeezeFraction >= 0.50 { return 2 }
        return 1
    }

    /// The smallest halving rung of the recipe cap that still covers
    /// `rate` (round UP — the posture never sits below the wire).
    public func rungIndex(for rate: Int) -> Int {
        let floor = max(rate, 1)
        var index = 0
        var rung = config.baselineMaxBitsPerSecond
        while rung / 2 >= floor && index < 40 {
            rung /= 2
            index += 1
        }
        return index
    }

    /// The rate rung `index` carries, bits/s.
    public func rungRate(atIndex index: Int) -> Int {
        var rung = config.baselineMaxBitsPerSecond
        for _ in 0..<index { rung /= 2 }
        return max(rung, 1)
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

    /// The HS-20/HS-22 mapping evaluated at a rung's rate: caps against
    /// the baseline, k-window VBV at the rung's own depth.
    private func posture(atRungIndex index: Int) -> Posture {
        let rate = rungRate(atIndex: index)
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

    /// Applies `posture` to the tracked state and wraps it as a
    /// directive — or absorbs it silently when the encoder already
    /// runs these exact params (rung_0 ≡ baseline is the designed
    /// case: the flag may flip, the encoder is never touched).
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

    /// One look at the live ceiling — polled once per encode, where the
    /// estimator's rate is always current. Returns the directive to
    /// apply before this frame, or nil while the clean path / rung
    /// band / sustain says the encoder should keep what it has.
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

        // THE CLEAN PATH, not engaged: the recipe rides, silence.
        if clean, !squeezeEngaged {
            looserWantedSince = nil
            return absorb()
        }

        // THE SQUEEZE ENGAGE: the first look below the clean boundary
        // lands on the required rung immediately (a WAKE-arm tightening
        // never waits). rung_0 mins back to the baseline, so a marginal
        // squeeze under a guarded live posture engages silently.
        if !clean, !squeezeEngaged {
            let required = rungIndex(for: ceilingRate)
            squeezeEngaged = true
            appliedRungIndex = required
            looserWantedSince = nil
            return emit(
                posture(atRungIndex: required), kind: .tighten,
                frameByteCeiling: frameByteCeiling, now: now,
                ceilingMoved: ceilingMoved
            )
        }

        // Engaged. TIGHTEN first — immediate, boundary-margin gated:
        // the ceiling must sit materially INSIDE a lower band (judged
        // at ceilingRate × (1 + deadband)) before the posture steps
        // down; a fall that stays in the applied band changes nothing.
        let appliedIndex = appliedRungIndex ?? 0
        if !clean {
            let margined = ceilingRate
                + Int(Double(ceilingRate) * config.deadbandFraction)
            if rungIndex(for: margined) > appliedIndex {
                let required = rungIndex(for: ceilingRate)
                appliedRungIndex = required
                looserWantedSince = nil
                return emit(
                    posture(atRungIndex: required), kind: .tighten,
                    frameByteCeiling: frameByteCeiling, now: now,
                    ceilingMoved: ceilingMoved
                )
            }
        }

        // LOOSEN — wanted while the ceiling rides ABOVE the applied
        // rung (a clean ceiling always wants the restore). The want
        // must hold continuously for the sustain window; the jump
        // target is the rung of the window's MINIMUM ceiling — the
        // level the wire actually held. A hunt's recurring falls reset
        // the tracker, so the posture parks and the hunt is absorbed.
        let wantsLooser = clean
            || rungIndex(for: ceilingRate) < appliedIndex
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
            squeezeEngaged = false
            appliedRungIndex = nil
            return emit(
                baselinePosture, kind: .restore,
                frameByteCeiling: frameByteCeiling, now: now,
                ceilingMoved: ceilingMoved
            )
        }
        // Sustained but still squeezed: climb to the held level's rung.
        let target = rungIndex(for: looserMinCeilingRate)
        appliedRungIndex = target
        return emit(
            posture(atRungIndex: target), kind: .loosen,
            frameByteCeiling: frameByteCeiling, now: now,
            ceilingMoved: ceilingMoved
        )
    }
}
