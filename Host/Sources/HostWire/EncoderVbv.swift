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
// wrapper's source): that reconfigure is NOT free — nvenc.c sets
// `resetEncoder = 1, forceIDR = 1` for every rate/VBV move, so each
// directive costs an encoder reset and a full forced IDR at the newly
// capped budget. HS-20 believed pure rate moves were IDR-less; they are
// not. Every directive this policy withholds is a quality pulse the
// session never pays — which is why the clean path below must be
// SILENT, not merely deadbanded.
//
// THE CLEAN-PATH RULE (HS-22 — the owner's "moderate quality on a clean
// path" regression). HS-20 imposed its caps unconditionally: capped-CQ
// got a single-frame VBV at the very first look even when the wire
// outran the encoder's own recipe, so every IDR/scene change was
// quantized down to the ceiling on paths with headroom to spare — a
// squeeze tool applied as steady-state posture. Now the ceiling-derived
// rate (8×C/B) is judged against the opening recipe's own cap first:
//   • ceilingRate ≥ (1 − deadband) × baselineMax  ⇒  CLEAN. The wire
//     delivers at least the recipe's own rate (within the noise the
//     deadband already declares immaterial): zero directives, the
//     opening recipe rides. Returning from a squeeze, ONE restore
//     directive (rise-hold gated) puts the recipe back, then silence.
//     The threshold is the policy's own deadband — a ceiling within
//     10% of the recipe is measurement wiggle, not a squeeze, and any
//     genuine engage is a ≥10% move (material by construction).
//   • ceilingRate below that                      ⇒  SQUEEZED. The
//     HS-20 mapping engages (below).
//
// MAPPING under a squeeze. The estimator's ceiling C (bytes) is the
// whole contract: C = R×B/8 − reserves, B = min(2/fps, 25 ms) (HS-6;
// the overview pins that the pacer's burst budget is "guaranteed
// upstream by frameByteCeiling" — this policy is that guarantee,
// enforced at the encoder). The encoder-facing params derive from C:
//   rate    = 8×C / B   — the VBV refills exactly one ceiling per budget
//                         window (the video class's share of R, with the
//                         audio/control reserves already subtracted);
//   vbvBits = k × 8×C   — k budget windows of borrowing, and k scales
//                         TOWARD the squeeze (HS-22): a deep squeeze
//                         (ceilingRate < 50% of the recipe) keeps k = 1,
//                         the per-frame conformance tool that retired
//                         B2 — byte-identical to HS-20's pinned legs; a
//                         mild squeeze mostly needs the AVERAGE held, so
//                         k steps 2/3/4 as the squeeze lightens
//                         (50/65/80% of the recipe rate), letting an IDR
//                         borrow adjacent windows the pacer absorbs
//                         instead of quantizing it into mud. k tops out
//                         at 4 (~100 ms of budget) — deeper borrowing
//                         would outlive the client's completion
//                         presumption.
// All params stay CAPS against the encoder's opening posture, never
// pushes above it: effective = min(baseline, ceiling-derived). Capped-CQ
// keeps its nil average bitrate: pushing one would flip nvenc out of
// constant-quality mode.
//
// RESTORE. Recovery returns the opening recipe exactly (CBR: bit-for-bit
// — pinned since HS-20). Capped-CQ opened with NO VBV at all, and that
// is inexpressible on the way back: the wrapper's reconfigure only reads
// `rc_buffer_size > 0`, so once a VBV exists it can only be resized,
// never removed. The restore therefore carries the nearest expressible
// recipe: one full second at the baseline cap (`baselineMax` bits) —
// far above any real frame, effectively the recipe again.
//
// HYSTERESIS (the least-thrash ruling, written down — each avoided
// directive is now a known avoided IDR). The estimator moves the rate on
// nearly every feedback beat (the evidence climb is ≤10%/s at a 25–50 ms
// report cadence); reconfiguring NVENC on each tick would thrash rate
// control for moves the pacer absorbs anyway. Policy:
//   • deadband — nothing is pushed while every effective param sits
//     within `deadbandFraction` (10%) of what was last applied;
//   • falls apply IMMEDIATELY once past the deadband: an oversized frame
//     at a squeezed pacer is the exact harm this exists to stop, and the
//     estimator's own downshift limiter (≥15% falls, ≤1 per 500 ms)
//     already bounds how often they can fire;
//   • rises — the squeeze→clean restore included — additionally wait
//     `riseHoldNS` (500 ms) after the last apply: a deferred loosening
//     costs one frame of quality, never a queue — asymmetry in the safe
//     direction. Flap-proofing at the clean boundary is structural:
//     estimator falls are ≥15% steps and rises are ≤10%/s climbs, so
//     the ceiling cannot oscillate ±2% across the threshold.

/// What the shell pushes into the encoder leaf when the policy says the
/// rate-control posture must move.
public struct EncoderRateDirective: Equatable, Sendable {
    /// New average bitrate, bits/s. Nil = leave the average untouched —
    /// capped-CQ mode has none (FFmpeg zeroes it at open; setting one
    /// would change the rate-control mode, not just its numbers).
    public var averageBitsPerSecond: Int?
    /// New hard cap, bits/s (AVCodecContext.rc_max_rate).
    public var maxBitsPerSecond: Int
    /// New VBV budget, bits (AVCodecContext.rc_buffer_size).
    public var vbvBits: Int
    /// The frameByteCeiling that produced this directive (evidence for
    /// the logs; the live gate reads frame sizes against it).
    public var frameByteCeiling: Int

    public init(
        averageBitsPerSecond: Int?, maxBitsPerSecond: Int, vbvBits: Int,
        frameByteCeiling: Int
    ) {
        self.averageBitsPerSecond = averageBitsPerSecond
        self.maxBitsPerSecond = maxBitsPerSecond
        self.vbvBits = vbvBits
        self.frameByteCeiling = frameByteCeiling
    }
}

public struct EncoderVbvConfig: Sendable {
    public var fps: Int
    /// The encoder's opening rate-control posture — the ceiling caps
    /// against it, never pushes above it. CBR opens with avg = max =
    /// the configured bitrate and a single-frame VBV; capped-CQ opens
    /// with only the max-rate cap (average and VBV nil).
    public var baselineAverageBitsPerSecond: Int?
    public var baselineMaxBitsPerSecond: Int
    public var baselineVbvBits: Int?
    /// Relative move below which nothing is pushed (the deadband).
    public var deadbandFraction: Double
    /// A pure loosening waits this long after the last apply; a
    /// tightening never waits.
    public var riseHoldNS: UInt64

    public init(
        fps: Int,
        baselineAverageBitsPerSecond: Int? = nil,
        baselineMaxBitsPerSecond: Int,
        baselineVbvBits: Int? = nil,
        deadbandFraction: Double = 0.10,
        riseHoldNS: UInt64 = 500_000_000
    ) {
        precondition(fps > 0)
        precondition(baselineMaxBitsPerSecond > 0)
        self.fps = fps
        self.baselineAverageBitsPerSecond = baselineAverageBitsPerSecond
        self.baselineMaxBitsPerSecond = baselineMaxBitsPerSecond
        self.baselineVbvBits = baselineVbvBits
        self.deadbandFraction = deadbandFraction
        self.riseHoldNS = riseHoldNS
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
    /// True while the squeeze mapping owns the encoder posture; false
    /// while the opening recipe rides (the HS-22 clean path).
    public private(set) var squeezeEngaged = false
    private var lastAppliedAt: UInt64?

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
    /// by squeeze depth. `squeezeFraction` = ceilingRate / baselineMax.
    /// Deep squeezes keep HS-20's single-frame tool byte-identical;
    /// mild ones loosen the per-frame bound while the rate cap holds
    /// the average.
    public static func vbvBudgetWindows(squeezeFraction: Double) -> Int {
        if squeezeFraction >= 0.80 { return 4 }
        if squeezeFraction >= 0.65 { return 3 }
        if squeezeFraction >= 0.50 { return 2 }
        return 1
    }

    /// One look at the live ceiling — polled once per encode, where the
    /// estimator's rate is always current. Returns the directive to
    /// apply before this frame, or nil while the clean path /
    /// deadband / hold says the encoder should keep what it has.
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

        // THE CLEAN PATH: the wire keeps up with the opening recipe —
        // the policy is silent, except for the one restore that puts
        // the recipe back after a squeeze.
        guard ceilingRate < cleanPathRateBitsPerSecond else {
            guard squeezeEngaged else { return nil }
            // The restore is a pure loosening: it waits out the rise
            // hold like any other rise (and bypasses the deadband — a
            // mode crossing is always material).
            if let last = lastAppliedAt, now &- last < config.riseHoldNS {
                return nil
            }
            squeezeEngaged = false
            // Capped-CQ's "no VBV" cannot be pushed back through the
            // wrapper (rc_buffer_size > 0 only): one second at the
            // baseline cap is the nearest expressible recipe.
            let restoreVbv = config.baselineVbvBits
                ?? config.baselineMaxBitsPerSecond
            appliedAverageBitsPerSecond = config.baselineAverageBitsPerSecond
            appliedMaxBitsPerSecond = config.baselineMaxBitsPerSecond
            appliedVbvBits = restoreVbv
            lastAppliedAt = now
            directivesIssued += 1
            return EncoderRateDirective(
                averageBitsPerSecond: config.baselineAverageBitsPerSecond,
                maxBitsPerSecond: config.baselineMaxBitsPerSecond,
                vbvBits: restoreVbv,
                frameByteCeiling: frameByteCeiling
            )
        }

        // THE SQUEEZE: the HS-20 mapping, with the HS-22 multi-window
        // VBV at mild depths.
        let squeezeFraction = Double(ceilingRate)
            / Double(config.baselineMaxBitsPerSecond)
        let windows = Self.vbvBudgetWindows(squeezeFraction: squeezeFraction)
        let effectiveMax = min(config.baselineMaxBitsPerSecond, ceilingRate)
        let effectiveAverage = config.baselineAverageBitsPerSecond
            .map { min($0, ceilingRate) }
        let effectiveVbv = min(
            config.baselineVbvBits ?? Int.max, windows * ceiling * 8
        )

        // Material? The first imposition onto a no-VBV posture always
        // is; otherwise some param must move past the deadband relative
        // to what was last applied.
        func pastDeadband(_ new: Int, from old: Int) -> Bool {
            abs(new - old) >= Int(Double(old) * config.deadbandFraction)
        }
        let material: Bool
        if let appliedVbv = appliedVbvBits {
            material = pastDeadband(effectiveVbv, from: appliedVbv)
                || pastDeadband(effectiveMax, from: appliedMaxBitsPerSecond)
                || (effectiveAverage != nil
                    && appliedAverageBitsPerSecond != nil
                    && pastDeadband(effectiveAverage!,
                                    from: appliedAverageBitsPerSecond!))
        } else {
            material = true
        }
        guard material else { return nil }

        // A pure loosening (nothing tightens) waits out the rise hold;
        // any tightening applies now.
        let tightens = effectiveVbv < (appliedVbvBits ?? Int.max)
            || effectiveMax < appliedMaxBitsPerSecond
            || (effectiveAverage ?? Int.max)
                < (appliedAverageBitsPerSecond ?? Int.max)
        if !tightens, let last = lastAppliedAt,
           now &- last < config.riseHoldNS {
            return nil
        }

        squeezeEngaged = true
        appliedAverageBitsPerSecond = effectiveAverage
        appliedMaxBitsPerSecond = effectiveMax
        appliedVbvBits = effectiveVbv
        lastAppliedAt = now
        directivesIssued += 1
        return EncoderRateDirective(
            averageBitsPerSecond: effectiveAverage,
            maxBitsPerSecond: effectiveMax,
            vbvBits: effectiveVbv,
            frameByteCeiling: frameByteCeiling
        )
    }
}
