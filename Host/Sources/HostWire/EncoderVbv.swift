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
// NvEncReconfigureEncoder call — no IDR, no encoder reset, for pure
// rate/VBV moves.
//
// MAPPING. The estimator's ceiling C (bytes) is the whole contract:
// C = R×B/8 − reserves, B = min(2/fps, 25 ms) (HS-6; the overview pins
// that the pacer's burst budget is "guaranteed upstream by
// frameByteCeiling" — this policy is that guarantee, finally enforced at
// the encoder instead of hoped for). The encoder-facing params derive
// from C alone:
//   vbvBits = 8×C       — one frame may cost at most the ceiling;
//   rate    = 8×C / B   — the VBV refills exactly one ceiling per budget
//                         window (the video class's share of R, with the
//                         audio/control reserves already subtracted).
// Both are CAPS against the encoder's opening posture, never pushes
// above it: effective = min(baseline, ceiling-derived). A CBR encoder
// whose --bitrate-mbps sits below the wire rate keeps its own (stricter)
// numbers at the session ceiling; capped-CQ mode (--ratchet), which
// opens with a max-rate cap and NO VBV at all, gets the ceiling imposed
// from the first established frame — bounding even the opening IDR, and
// the ratchet exists precisely to refine what a bounded first pass
// under-spent. Capped-CQ keeps its nil average bitrate: pushing one
// would flip nvenc out of constant-quality mode.
//
// HYSTERESIS (the least-thrash ruling, written down). The estimator
// moves the rate on nearly every feedback beat (the evidence climb is
// ≤10%/s at a 25–50 ms report cadence); reconfiguring NVENC on each tick
// would thrash rate control for moves the pacer absorbs anyway. Policy:
//   • deadband — nothing is pushed while every effective param sits
//     within `deadbandFraction` (10%) of what was last applied;
//   • falls apply IMMEDIATELY once past the deadband: an oversized frame
//     at a squeezed pacer is the exact harm this exists to stop, and the
//     estimator's own downshift limiter (≥15% falls, ≤1 per 500 ms)
//     already bounds how often they can fire;
//   • rises additionally wait `riseHoldNS` (500 ms) after the last
//     apply: a deferred loosening costs one frame of quality, never a
//     queue — asymmetry in the safe direction.

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
    private var lastAppliedAt: UInt64?

    public init(config: EncoderVbvConfig) {
        self.config = config
        self.appliedAverageBitsPerSecond = config.baselineAverageBitsPerSecond
        self.appliedMaxBitsPerSecond = config.baselineMaxBitsPerSecond
        self.appliedVbvBits = config.baselineVbvBits
    }

    /// One look at the live ceiling — polled once per encode, where the
    /// estimator's rate is always current. Returns the directive to
    /// apply before this frame, or nil while the deadband/hold says the
    /// encoder should keep what it has.
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
        let effectiveMax = min(config.baselineMaxBitsPerSecond, ceilingRate)
        let effectiveAverage = config.baselineAverageBitsPerSecond
            .map { min($0, ceilingRate) }
        let effectiveVbv = min(config.baselineVbvBits ?? Int.max, ceiling * 8)

        // Material? The first imposition onto a no-VBV opening posture
        // always is; otherwise some param must move past the deadband
        // relative to what was last applied.
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
