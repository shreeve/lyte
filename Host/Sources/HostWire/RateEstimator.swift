// RateEstimator: the host's sans-IO congestion estimator. Every entry
// point takes `now` (monotonic ns, the pacer domain); the caller owns
// scheduling. Inputs are the send ledger and the client's feedback
// reports (every 25–50 ms).
//
//   • SEND LEDGER — (channel, seq) → (send instant, wire bytes, delivery
//     frame, pace at release), recorded as the pacer releases each
//     datagram; dispersion samples name (channel, seq) to match it.
//   • DELIVERY RATE — matched samples split per CHANNEL, then per fresh-
//     video FRAME, then into trains by send spacing. Audio cadence and
//     repairs never bridge video shards into a synthetic low-capacity
//     train and never vote on capacity (they still feed delay). A train
//     of ≥3 packets yields (bytes behind the first arrival) / (arrival
//     span) into a 10 s windowed MAX (BBR's shape); trains shorter than
//     `minTrainPackets` weigh ×0.5. Client decimation only drops interior
//     samples, so the measurement errs low.
//   • QUEUING DELAY — per report and channel, the minimum (arrival µs −
//     send µs); the baseline is a 10 s rolling min per channel and the
//     inflation is the MAX across channels. Per channel because
//     DSCP-aware bottlenecks give audio a fast lane that would mask a
//     growing video queue. The clock offset cancels; skew is < 1 ms per
//     window.
//   • LOSS — cumulative per-channel ledgers differenced report to report
//     over a rolling 1 s window (pre-FEC). POST-FEC LOSS — deduped
//     (frame, shard) NACKs over the same window against video datagrams
//     attempted; > 2% is rung 3.
//   • CONTROL LAW — the verdicts decide WHEN; the CAPACITY BELIEF decides
//     WHERE:
//     - overuse (inflation > threshold on consecutive reports) falls to
//       clamp(min(0.85 × belief, 0.85 × rate)) under the HONESTY LAW in
//       `applyControlLaw`; at most one fall per 500 ms;
//     - pre-FEC loss < 2% is clean, 2–10% HOLDS (FEC parity's band),
//       > 10% falls ×(1 − loss/2);
//     - post-FEC loss > 2% falls ×0.85 (not held: FEC did not absorb it);
//     - rises need fresh delivery evidence, pre-FEC < 2%, post-FEC ≤ 2%,
//       1 s after any fall: ≤10%/s toward the PROBE ceiling
//       min(ceiling, belief × probeHeadroomFactor) — or, while the rate
//       sits under 90% of the rate an overuse fall left behind (for 10 s;
//       any fall after that climb began cancels it),
//       `recoveryUpshiftPerSecond` back toward it. A crash (belief
//       demoted below half the rate) arms no probe cadence: it located
//       no wall. The probe ceiling still bounds every step to what
//       the latest trains proved, so a path that stayed low parks the
//       climb exactly as before. The rate may sit
//       above the delivery max: paced sends self-limit the measurement
//       to ≈ the rate, so a max-derived cap would spiral to the floor.
//       Only post-FEC < 0.5% (the clean column) updates lastGoodRate;
//     - falls also need fresh delivery evidence OR standing pacer backlog;
//       sparse keepalive (neither) freezes rather than ratcheting down,
//       since the host never pads traffic just to probe.
//     Floor 2 Mbps: the smallest posture that pays the protected-traffic
//     reserve and one worst-column 1+2 FEC flight in the 25 ms burst
//     budget. Ceiling: the negotiated session rate.
//   • THE CAPACITY BELIEF — a paced sender never measures more than it
//     sends, so delivery samples are censored from above by our own rate.
//     - Invariant 1: each full train is classified at production against
//       the pace recorded at its release: CENSORED (≈ or above the pace),
//       HONEST (more than `censoredSampleMarginFraction` below it — the
//       path stretched it) or COMPRESSED (≥ `stallBurstRateFactor` × pace,
//       a drain). Any full train may RAISE the belief (capped at its pace);
//       only honest ones vote in a fall anchor.
//     - Invariant 2: the belief never ages; it demotes only at an
//       executing fall, to a fresh honest median below it. Pressure must
//       persist `beliefDemotionSustainNS` (a full fall-limiter window
//       into the next) unless instantly corroborated by loss, so a radio
//       dwell cannot sustain it and a real squeeze does within ~1 s.
//     - NACKs for frames still queued in our own pacer are the client's
//       completion presumption expiring mid-drain, not path evidence:
//       the session passes them as `recusedNackFrames`. Host-side drops
//       never read as path loss: the pacer drops before a chan-2 seq is
//       assigned, and a released datagram the socket seam drops (shed,
//       purged, unsendable) is credited through `noteHostDroppedVideo`
//       against the client's next `missing` counts.
//   • RECOVERY VERDICTS — while the machine is in RECOVERY each report
//     closes windows of ≥25 ms; a window is clean iff it saw no fresh
//     loss and no overuse. Silence is the silence detector's job.
//   • IDR PACING — lastGoodRate = min(btlRate, rate last seen healthy);
//     halfStaleEstimate = max(floor, 0.5 × stale delivery estimate).
//     frameByteCeiling = R×B/8 − higherClassBytes(B), B = min(2/fps,
//     25 ms).
//   • FEC REGIME — clean → lossy with the rung-3 threshold (latched, not
//     gated by the fall limiter: a geometry promise, not a rate move);
//     lossy → clean after post-FEC loss sits < 0.5% for the step-down
//     hold. The session applies each step from the next frame on.
//   • SRTT — beacon-echo RTTs fold into an RFC 6298 EWMA (gain 1/8) for
//     the retransmit gate; min-RTT is kept for telemetry.

import LyteCore
import LyteWire

public struct RateEstimatorConfig: Sendable {
    /// The negotiated session ceiling, bits/s.
    public var ceilingBitsPerSecond: Int
    /// Operational floor: 2 Mbps pays the protected-traffic reserve plus
    /// the lossy ladder's minimum 1-data + 2-parity flight in 25 ms.
    public var floorBitsPerSecond: Int
    /// Where the standing rate starts. Nil = the ceiling.
    public var initialRateBitsPerSecond: Int?

    public init(
        ceilingBitsPerSecond: Int,
        floorBitsPerSecond: Int = 2_000_000,
        initialRateBitsPerSecond: Int? = nil
    ) {
        precondition(ceilingBitsPerSecond > 0)
        precondition(floorBitsPerSecond > 0)
        self.ceilingBitsPerSecond = ceilingBitsPerSecond
        self.floorBitsPerSecond = min(floorBitsPerSecond, ceilingBitsPerSecond)
        self.initialRateBitsPerSecond = initialRateBitsPerSecond
    }
}

/// The control law's constants.
extension RateEstimator {
    /// Delivery-rate samples and delay baselines older than this expire.
    static let sampleWindowNS: UInt64 = 10_000_000_000

    /// The MINIMUM send-spacing gap that splits trains. The effective gap
    /// is at least 3 × one datagram's wire time at the standing rate:
    /// at low rates the pacer itself spaces datagrams beyond a fixed gap,
    /// and no train would ever form to justify a climb.
    static let trainGapNS: UInt64 = 2_000_000

    /// Trains below this packet count weigh ×0.5 in the max filter and
    /// get no anchor vote (short-train dispersion is noisy).
    static let minTrainPackets: Int = 8

    /// How many recent full-train samples the anchor medians span (raw
    /// and honest). 3 with 2 consecutive overuse reports: a genuine drop
    /// fills two slots by fire time, a lone outlier is outvoted.
    static let overuseAnchorSampleCount: Int = 3

    /// Queuing-delay inflation that reads as overuse, µs.
    static let overuseThresholdMicroseconds: Int64 = 15_000

    /// Consecutive inflated reports before the overuse verdict fires.
    static let overuseConsecutiveReports: Int = 2

    /// "Standing backlog" = at least this much wire time of queued bytes
    /// at the standing rate (more than mid-batch residue, far less than
    /// one squeezed IDR's drain).
    static let selfReferenceBacklogWindowNS: UInt64 = 5_000_000

    /// The largest inflation-streak peak still booked as a stall hold
    /// (Wi-Fi scan dwells run 70–100 ms; longer is real degradation).
    static let stallGapCeilingMicroseconds: Int64 = 150_000

    /// A full train at least this multiple of its pace is a COMPRESSED
    /// drain: packets accumulated and were released together (above
    /// pacing noise, far below any real AP drain).
    static let stallBurstRateFactor: Double = 1.25

    /// How fresh drain evidence must be to book a stall hold.
    static let stallEvidenceWindowNS: UInt64 = 500_000_000

    /// Invariant 1: a full train measuring at or above (1 − this) × the
    /// pace recorded at its release is CENSORED — it measures our own
    /// pacing, may raise the belief, and never votes in a fall anchor.
    static let censoredSampleMarginFraction: Double = 0.2

    /// A slow path stretches a train uniformly; a radio hole opens ONE
    /// dominating gap. A train whose largest inter-arrival exceeds this
    /// fraction of its arrival span measured a hole: it keeps its other
    /// roles but gets no honest vote. 0.5 sits far above a uniform
    /// train's share (≈1/(n−1)) and below a stall's (>0.9).
    static let stretchGapDominanceFraction: Double = 0.5

    /// A path-capacity witness must span more than one socket microburst.
    /// Datagrams accepted by one sendmmsg share one timestamp; receiver-side
    /// serialization of that burst is frame geometry, not a sustained-rate
    /// probe. One millisecond requires evidence across pacer quanta.
    static let honestMinSendSpanNS: UInt64 = 1_000_000

    /// Invariant 2: how long overuse pressure must persist before an
    /// uncorroborated fall may execute — a full fall-limiter window, so
    /// the evidence spans ≥2 windows. A dwell cannot sustain it.
    static let beliefDemotionSustainNS: UInt64 = 500_000_000

    /// Honest votes older than this expire, so a healed dip cannot
    /// demote the belief later.
    static let honestVoteWindowNS: UInt64 = 2_000_000_000

    /// Consecutive reports whose inflation sits at or below half the
    /// streak's peak (and at least `overuseThresholdMicroseconds` under
    /// it) before the streak counts as DRAINED. Two, like the overuse
    /// verdict itself: one lucky report minimum is not a trend.
    static let drainCorroborationReports: Int = 2

    /// Pre-FEC loss fraction below which the window reads clean.
    static let lossCleanThreshold: Double = 0.02

    /// Pre-FEC loss fraction above which the rate falls ×(1 − loss/2).
    /// Between the two thresholds the rate HOLDS (FEC absorbs it).
    static let lossDownshiftThreshold: Double = 0.10

    /// The loss accounting window.
    static let lossWindowNS: UInt64 = 1_000_000_000

    /// Post-FEC loss fraction (NACKed shards / video datagrams
    /// attempted, over `lossWindowNS`) above which rung 3 fires: a
    /// downshift plus an FEC regime step up.
    static let postFecDownshiftThreshold: Double = 0.02

    /// Post-FEC loss below which the window reads clean for the regime
    /// ladder and lastGoodRate.
    static let postFecCleanThreshold: Double = 0.005

    /// How long post-FEC loss must sit below `postFecCleanThreshold`
    /// before the regime steps back down to clean.
    static let regimeStepDownHoldNS: UInt64 = 5_000_000_000

    /// Multiplicative downshift factor and its rate limit.
    static let downshiftFactor: Double = 0.85
    static let downshiftMinIntervalNS: UInt64 = 500_000_000

    /// Upshift budget per second toward the ceiling (≤10%/s).
    static let upshiftPerSecond: Double = 0.10

    /// The probe ceiling is min(ceiling, belief × this): the climb may
    /// probe above the belief (how the belief grows) without slamming a
    /// wall it already located. Must exceed 1.0.
    static let probeHeadroomFactor: Double = 1.10

    /// After a fall that fired while probing (rate above the belief it
    /// held, and ≥ demoted belief / probeHeadroomFactor: a failed probe),
    /// rises back into that band wait this long (BBR PROBE_BW's cadence).
    /// Below the band the climb stays continuous.
    static let probeCadenceNS: UInt64 = 10_000_000_000

    /// A fall whose demoted belief is below this fraction of the standing
    /// rate is a CRASH, not a failed probe: the rate was nowhere near a
    /// located wall, so it arms no cadence.
    static let crashDemotionFraction: Double = 0.5

    /// The recovery climb: while the rate sits under
    /// `recoveryTargetFraction` of the rate an overuse fall left behind,
    /// rises run at this per-second budget instead of `upshiftPerSecond`
    /// (1.0 ≈ ×2.7 per second compounded at the report cadence), still
    /// capped per step by the probe ceiling.
    static let recoveryUpshiftPerSecond: Double = 1.0
    static let recoveryTargetFraction: Double = 0.9
    /// How long a fall's pre-fall rate stays a recovery target.
    static let recoveryTargetWindowNS: UInt64 = 10_000_000_000

    /// No upshift this long after a downshift (queue drain time).
    static let upshiftHoldAfterDownshiftNS: UInt64 = 1_000_000_000

    /// Delivery evidence must be at most this old for the rate to rise.
    static let upshiftEvidenceWindowNS: UInt64 = 2_000_000_000

    /// The RECOVERY verdict window.
    static let recoveryWindowNS: UInt64 = 25_000_000

    /// Send-ledger capacity (datagrams). 8192 covers >600 ms at the
    /// 20 Mbps shard rate — far beyond any 25–50 ms report cadence.
    static let sendLedgerCapacity: Int = 8_192

    /// The higher-class reserves frameByteCeiling subtracts: audio's
    /// wire rate (131 B × 300/s ≈ 315 kbps at defaults) and control.
    public static let audioReserveBitsPerSecond: Int = 320_000
    public static let controlReserveBitsPerSecond: Int = 500_000
}

/// What one ingested report did to the estimate — the session applies
/// `newRate` to the pacer and feeds each verdict to the machine.
public struct RateEstimatorVerdict: Equatable, Sendable {
    /// Which control-law branch moved the rate.
    public enum Change: Equatable, Sendable {
        case overuse
        case loss
        /// NACK-evidenced loss FEC could not absorb (rung 3).
        case postFecLoss
        case evidence
    }

    /// Set when the standing rate moved (already floored/ceilinged).
    public var newRateBitsPerSecond: Int?
    /// Why it moved; nil when it did not.
    public var change: Change?
    /// One entry per RECOVERY feedback window this report closed
    /// (empty outside RECOVERY).
    public var recoveryWindows: [Bool]
    /// This report's ingest read as overuse (delay inflation) — the
    /// downshift may still be rate-limited.
    public var overuse: Bool
    /// Post-arrival loss fraction over the rolling window.
    public var lossFraction: Double
    /// Post-FEC (NACK-evidenced) loss fraction over the rolling window.
    public var postFecLossFraction: Double = 0
    /// Set when this report stepped the FEC regime.
    public var fecRegime: FecRegime?
}

/// Running evidence counters, exposed for logs and the live gate.
public struct RateEstimatorStats: Equatable, Sendable {
    public var reportsIngested = 0
    public var dispersionSamplesMatched = 0
    public var dispersionSamplesUnmatched = 0
    /// Matched samples of datagrams sent before the latest path change.
    public var dispersionSamplesFromOldPath = 0
    public var deliverySamples = 0
    public var downshifts = 0
    public var upshifts = 0
    /// Climbs capped at the probe ceiling (below the configured one).
    public var upshiftsDamped = 0
    /// Rises held by the probe cadence.
    public var upshiftsCadenceHeld = 0
    /// Rises taken at the recovery budget toward a pre-fall rate.
    public var recoveryUpshifts = 0
    /// Climbs admitted while post-FEC sat between the clean column and
    /// rung 3.
    public var upshiftsUnderMildPostFec = 0
    /// Falls held for stale delivery evidence and no standing backlog.
    public var sparseEvidenceHolds = 0
    public var overuseVerdicts = 0
    /// Persisted overuse held because its only witnesses were censored
    /// samples under our own standing backlog.
    public var selfReferenceHolds = 0
    /// Unpersisted overuse withheld with fresh drain evidence inside a
    /// bounded hole (the receiver's radio blinked).
    public var stallHolds = 0
    /// Other overuse withheld awaiting invariant 2's persistence; the
    /// fall limiter stays unconsumed.
    public var fallDeferrals = 0
    /// Inflation streaks restarted because the queue drained to half
    /// its peak: the pressure was spent, its honest votes purged.
    public var drainRestarts = 0
    public var lossDownshifts = 0
    /// Full-train samples classified CENSORED (or compressed).
    public var censoredSamples = 0
    /// Full-train samples classified HONEST that voted.
    public var honestSamples = 0
    /// Would-be honest trains whose span was one dominating gap.
    public var stretchedTrainsRecused = 0
    /// Would-be honest trains confined to one socket/pacer microburst.
    public var burstGeometryTrainsRecused = 0
    /// Times a sample raised the capacity belief.
    public var beliefRaises = 0
    /// Times an executing fall demoted the belief to the honest median.
    public var beliefDemotions = 0
    /// NACK shards recused because their frame was still in our pacer.
    public var nackShardsRecused = 0
    /// Rung-3 downshifts (post-FEC loss over threshold).
    public var postFecDownshifts = 0
    /// Distinct (frame, shard) pairs the NACK sections named.
    public var nackShardsCounted = 0
    /// FEC regime steps, both directions.
    public var regimeSteps = 0

    public init() {}
}

/// The evidence on the table when an overuse FALL fired (holds are only
/// counted), for post-mortem logs.
public struct OveruseFallForensics: Equatable, Sendable {
    /// The median of recent raw full-train samples (forensic only);
    /// nil when no full train landed inside the sample window.
    public var anchorBitsPerSecond: Int?
    /// The standing rate the instant before the fall.
    public var rateBeforeBitsPerSecond: Int
    /// Worst inflation anywhere in the streak, µs.
    public var streakPeakMicroseconds: Int64?
    /// Queuing delay at the streak's opening report, µs.
    public var streakStartMicroseconds: Int64?
    /// Queuing delay on THIS report, µs.
    public var queuingDelayMicroseconds: Int64?
    /// Pacer backlog at fall time.
    public var pacerBacklogBytes: Int
    /// The freshest full train: its rate and age.
    public var lastFullTrainBitsPerSecond: Int?
    public var lastFullTrainAgeNS: UInt64?
    /// Loss posture on this report.
    public var lossFraction: Double
    public var postFecLossFraction: Double
    /// The (possibly demoted) belief the fall answered to, and the fresh
    /// honest median (nil = none; the fall was bounded multiplicative).
    public var capacityBeliefBitsPerSecond: Int?
    public var honestAnchorBitsPerSecond: Int?
    /// How long the overuse pressure had persisted at fall time.
    public var streakAgeNS: UInt64?
}

public final class RateEstimator {
    public let config: RateEstimatorConfig
    public private(set) var stats = RateEstimatorStats()

    /// The last overuse fall's forensics (nil until one fires).
    public private(set) var lastOveruseFall: OveruseFallForensics?

    /// The standing pace, bits/s — what the pacer should run at.
    public private(set) var rateBitsPerSecond: Int

    /// The windowed-max delivery-rate estimate (nil before evidence).
    public var deliveryRateBitsPerSecond: Int? {
        deliveryWindowMax.map(Int.init)
    }

    /// Reporting-grade measured delivery: the median of the last few
    /// full-train samples. Summaries print this, not the windowed MAX,
    /// which a compressed drain burst can inflate far past the wire.
    public var measuredDeliveryRateBitsPerSecond: Int? {
        overuseAnchorRate.map { Int($0) }
    }

    /// The capacity belief, bits/s. Nil before any full-train evidence.
    public var capacityBeliefBitsPerSecond: Int? {
        beliefBits.map(Int.init)
    }

    /// The current queuing-delay inflation estimate, µs (nil before
    /// two reports establish a baseline).
    public private(set) var queuingDelayMicroseconds: Int64?

    /// min-RTT from beacon echoes, for telemetry; the rate law runs on
    /// the dispersion sensor.
    public private(set) var minRttMicroseconds: Int64?

    /// RFC 6298-shaped smoothed RTT from beacon echoes, the retransmit
    /// gate's SRTT term. Nil before the first echo.
    public private(set) var srttMicroseconds: Int64?

    /// The FEC ladder column in force. Moves only through `ingest`.
    public private(set) var fecRegime: FecRegime = .clean

    // MARK: Send ledger

    private struct SendRecord {
        var key: UInt32
        var sendNS: UInt64
        var bytes: Int
        /// Fresh-video frame flight this datagram belongs to. Nil means
        /// it remains delay evidence but is not a delivery-rate probe
        /// (audio/control/repair traffic is application-limited).
        var deliveryFrame: UInt32?
        /// The pacer's rate when this datagram was released
        /// (invariant 1's classification input).
        var paceBitsPerSecond: Int
    }

    /// (channel << 16 | seq) → ledger slot; slots recycle FIFO.
    private var ledgerIndex: [UInt32: Int] = [:]
    private var ledger: [SendRecord?]
    private var ledgerHead = 0

    // MARK: Delivery / delay / loss state

    private struct DeliverySample {
        var at: UInt64
        var rate: Double
    }
    private var deliveryWindow: [DeliverySample] = []
    /// Maintained with the rolling window so hot telemetry/control reads
    /// do not allocate a mapped array and scan it on every access.
    private var deliveryWindowMax: Double?
    /// The freshest raw (unweighted) delivery measurement — the stale
    /// estimate for RECOVERY's halfStaleEstimate pacing.
    private var lastDeliveryRate: Double?
    private var lastDeliveryAt: UInt64?
    /// The last `overuseAnchorSampleCount` raw full-train measurements,
    /// FIFO, expired past `sampleWindowNS` like every other delivery
    /// sample. Their median is reporting-grade and forensic only; falls
    /// answer to the capacity belief.
    private var recentRawDeliveries = Deque<(at: UInt64, rate: Double)>()

    // MARK: Capacity belief

    /// Raised instantly by any full-train sample above it (capped at the
    /// train's pace); falls only by invariant-2 demotion, never by aging.
    private var beliefBits: Double?
    /// Probe cadence: after a failed probe, rises back INTO the band
    /// wait until this instant. Band floor `.infinity` = no hold armed.
    private var cadenceHoldUntilNS: UInt64 = 0
    private var cadenceBandFloorBits: Double = .infinity
    /// Fresh HONEST full-train votes, the only samples that may pull a
    /// fall below the belief. FIFO of `overuseAnchorSampleCount`, expired
    /// past `honestVoteWindowNS`.
    private var recentHonestDeliveries = Deque<(at: UInt64, rate: Double)>()
    /// When the current overuse streak opened (invariant 2's clock).
    private var inflatedStreakSinceNS: UInt64?
    /// The rate an overuse fall left behind, and until when the climb
    /// may recover toward it at the recovery budget. Cleared on arrival,
    /// on expiry, and by any fall after the recovery climb began (the
    /// path pushed back).
    private var recoveryTargetBits: Double?
    private var recoveryTargetUntilNS: UInt64 = 0
    private var recoveryClimbStarted = false

    private struct DelaySample {
        var at: UInt64
        var minDelayMicros: Int64
    }
    /// Per-channel rolling baselines (see the header).
    private var delayBaselineWindows: [UInt8: [DelaySample]] = [:]
    /// The latest path promotion. A report still in flight describes
    /// datagrams sent on the old path; those samples measure that path
    /// and never seed the new one's baseline, trains or belief.
    private var pathChangedAtNS: UInt64?
    private var consecutiveInflatedReports = 0
    /// The inflation at the current streak's opening report: a real
    /// standing queue grows past it (`queueGrew`).
    private var inflatedStreakStartMicros: Int64?
    /// The worst inflation in the current streak; packets held through
    /// a dwell carry its length as delay, so this bounds the hole.
    private var inflatedStreakPeakMicros: Int64?
    /// Consecutive reports of the current streak drained to half its
    /// peak (see `drainCorroborationReports`).
    private var drainedStreakReports = 0
    /// The freshest full train's raw measurement (drain evidence).
    private var lastFullTrainRate: Double?
    private var lastFullTrainAt: UInt64?

    private struct LossSample {
        var at: UInt64
        var missing: Int
        var received: Int
        /// The video channel's share — the post-FEC denominator.
        var videoAttempted: Int
    }
    private var lossWindow: [LossSample] = []
    /// Previous report's cumulative ledgers, per channel raw value.
    private var previousChannelTotals: [UInt8: (received: UInt32, missing: UInt32)] = [:]
    /// Released chan-2 datagrams the host itself never sent, oldest
    /// first: each cancels one video `missing` in a later report. A credit
    /// the client has not matched within `lossWindowNS` expires, so it can
    /// never mask later path loss.
    private var hostDroppedVideoCredits = Deque<(at: UInt64, count: Int)>()

    // MARK: Post-FEC (NACK) state

    private struct PostFecSample {
        var at: UInt64
        var shardCount: Int
    }
    private var postFecWindow: [PostFecSample] = []
    /// (frame << 8 | shard) → last counted instant: the same shard
    /// re-NACKed across reports inside the window counts once.
    private var recentNackShards: [UInt64: UInt64] = [:]
    /// The last instant post-FEC loss sat at or above the clean
    /// threshold (or a NACK arrived) — the step-down hold's anchor.
    private var lastPostFecEvidenceAt: UInt64?

    // MARK: Control-law state

    private var lastDownshiftAt: UInt64?
    private var lastAdjustAt: UInt64
    /// The rate last in force while the path read healthy (WAKE's
    /// anchor).
    private var lastGoodRate: Int

    // MARK: RECOVERY window state

    private var recoveryWindowStartNS: UInt64?
    private var recoveryWindowSawLoss = false
    private var recoveryWindowSawOveruse = false

    public init(config: RateEstimatorConfig, now: UInt64) {
        self.config = config
        let initial = min(
            max(config.initialRateBitsPerSecond ?? config.ceilingBitsPerSecond,
                config.floorBitsPerSecond),
            config.ceilingBitsPerSecond
        )
        self.rateBitsPerSecond = initial
        self.lastGoodRate = initial
        self.lastAdjustAt = now
        self.ledger = [SendRecord?](
            repeating: nil, count: Self.sendLedgerCapacity
        )
    }

    // MARK: - Send side

    /// Records one outbound datagram at the instant the pacer released
    /// it. `channel` is the envelope channel the client's dispersion
    /// samples will name; `bytes` is the wire size (delivery rate is
    /// measured in wire bytes, the unit the bottleneck queues in).
    /// `deliveryFrame` is non-nil only for a fresh-video flight; frame
    /// identity is a hard train boundary. The default is one synthetic
    /// frame for direct estimator fixtures.
    public func noteSent(
        channel: ChannelId, seq: ChannelSeq, bytes: Int, now: UInt64,
        deliveryFrame: FrameNumber? = FrameNumber(rawValue: 0),
        paceBitsPerSecond: Int? = nil
    ) {
        let key = UInt32(channel.rawValue) << 16 | UInt32(seq.rawValue)
        if let evicted = ledger[ledgerHead], ledgerIndex[evicted.key] == ledgerHead {
            ledgerIndex.removeValue(forKey: evicted.key)
        }
        ledger[ledgerHead] = SendRecord(
            key: key, sendNS: now, bytes: bytes,
            deliveryFrame: deliveryFrame?.rawValue,
            paceBitsPerSecond: paceBitsPerSecond ?? rateBitsPerSecond
        )
        ledgerIndex[key] = ledgerHead
        ledgerHead = (ledgerHead + 1) % ledger.count
    }

    /// One beacon-echo RTT sample: min-gated for telemetry, EWMA'd
    /// (RFC 6298's 1/8 gain) into the retransmit gate's SRTT. Samples
    /// outside `SessionBeaconClock.plausibleRttMicroseconds` are ignored,
    /// so SRTT and min-RTT always stay inside that range.
    public func noteRtt(microseconds: Int64) {
        guard SessionBeaconClock.plausibleRttMicroseconds
            .contains(microseconds) else { return }
        if minRttMicroseconds.map({ microseconds < $0 }) ?? true {
            minRttMicroseconds = microseconds
        }
        srttMicroseconds = srttMicroseconds.map {
            $0 + (microseconds - $0) / 8
        } ?? microseconds
    }

    /// Chan-2 datagrams that took a seq but never left the host (the
    /// socket seam shed, purged or could not send them). The client counts
    /// their seqs as missing; that is our loss, not the path's.
    public func noteHostDroppedVideo(count: Int, now: UInt64) {
        guard count > 0 else { return }
        hostDroppedVideoCredits.append((at: now, count: count))
    }

    // MARK: - Feedback side

    /// Consumes one parsed chan-3 report. `inRecovery` gates the
    /// recovery window verdicts. `pacerBacklogBytes` is the live
    /// video-class backlog (0 = none standing). `recusedNackFrames` names
    /// frames still queued in our own pacer; their NACKs feed neither the
    /// post-FEC fractions nor the regime ladder.
    public func ingest(
        _ report: FeedbackReport, now: UInt64, inRecovery: Bool,
        pacerBacklogBytes: Int = 0,
        recusedNackFrames: Set<UInt32> = []
    ) -> RateEstimatorVerdict {
        stats.reportsIngested += 1
        expireWindows(now: now)

        let (newMissing, _) = absorbChannelLedgers(report, now: now)
        let newNackShards = absorbNacks(
            report, recusedFrames: recusedNackFrames, now: now
        )
        let matched = matchDispersion(report)
        absorbDeliveryTrains(matched, now: now)
        let inflated = absorbDelay(matched, now: now)
        enforceEvidenceCaps()

        let lossFraction = currentLossFraction()
        let postFecLossFraction = currentPostFecLossFraction()
        let overuse = inflated
            && consecutiveInflatedReports >= Self.overuseConsecutiveReports
        if overuse { stats.overuseVerdicts += 1 }

        let oldRate = rateBitsPerSecond
        let change = applyControlLaw(
            overuse: overuse,
            lossFraction: lossFraction,
            postFecLossFraction: postFecLossFraction,
            pacerBacklogBytes: pacerBacklogBytes,
            now: now
        )
        let steppedRegime = stepRegime(
            postFecLossFraction: postFecLossFraction,
            sawNacks: newNackShards > 0,
            now: now
        )

        var verdict = RateEstimatorVerdict(
            newRateBitsPerSecond:
                rateBitsPerSecond == oldRate ? nil : rateBitsPerSecond,
            change: rateBitsPerSecond == oldRate ? nil : change,
            recoveryWindows: [],
            overuse: overuse,
            lossFraction: lossFraction,
            postFecLossFraction: postFecLossFraction,
            fecRegime: steppedRegime
        )

        if inRecovery {
            verdict.recoveryWindows = closeRecoveryWindows(
                sawLoss: newMissing > 0 || newNackShards > 0,
                sawOveruse: overuse,
                now: now
            )
        } else {
            recoveryWindowStartNS = nil
            recoveryWindowSawLoss = false
            recoveryWindowSawOveruse = false
        }
        return verdict
    }

    // MARK: - Evidence bounds

    /// Every window is keyed by report arrival and a client may send
    /// reports at any rate, so each is capped far above what the wire's
    /// 25–50 ms cadence fills (40 reports per 1 s loss window, 400 per 10 s
    /// delay window, a few trains per report). Past a cap the oldest
    /// evidence goes first; memory and per-report work stay bounded under
    /// a report storm.
    static let lossSampleCap = 256
    static let delaySampleCapPerChannel = 1_024
    static let deliverySampleCap = 2_048
    static let nackShardMemoryCap = 4_096

    /// Evidence entries retained across every window (test seam).
    @_spi(Testing) public var retainedEvidenceCount: Int {
        lossWindow.count + postFecWindow.count + deliveryWindow.count
            + recentNackShards.count
            + delayBaselineWindows.values.reduce(0) { $0 + $1.count }
    }

    private func enforceEvidenceCaps() {
        if lossWindow.count > Self.lossSampleCap {
            lossWindow.removeFirst(lossWindow.count - Self.lossSampleCap)
        }
        if postFecWindow.count > Self.lossSampleCap {
            postFecWindow.removeFirst(postFecWindow.count - Self.lossSampleCap)
        }
        if deliveryWindow.count > Self.deliverySampleCap {
            deliveryWindow.removeFirst(
                deliveryWindow.count - Self.deliverySampleCap)
            deliveryWindowMax = deliveryWindow.map(\.rate).max()
        }
        var index = delayBaselineWindows.values.startIndex
        while index != delayBaselineWindows.values.endIndex {
            let excess = delayBaselineWindows.values[index].count
                - Self.delaySampleCapPerChannel
            if excess > 0 {
                delayBaselineWindows.values[index].removeFirst(excess)
            }
            index = delayBaselineWindows.values.index(after: index)
        }
        // Dedupe memory only: forgetting it can double-count a re-NACK,
        // never miss a fresh one.
        if recentNackShards.count > Self.nackShardMemoryCap {
            recentNackShards.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - The machine's numbers

    /// The rate a machine-demanded IDR must be paced at. Applying it
    /// also MOVES the standing rate there.
    public func applyIdrPacing(_ pacing: IdrPacing, now: UInt64) -> Int {
        let rate: Int
        switch pacing {
        case .lastGoodRate:
            // WAKE from healthy IDLE: min(btlRate, lastGoodRate).
            let btl = deliveryRateBitsPerSecond ?? lastGoodRate
            rate = clamp(min(btl, lastGoodRate))
        case .halfStaleEstimate:
            // RECOVERY: the path is unknown; the stale estimate may be
            // 10× the new path's capacity.
            let stale = deliveryRateBitsPerSecond
                ?? lastDeliveryRate.map(Int.init)
                ?? rateBitsPerSecond
            rate = clamp(stale / 2)
            // RECOVERY is a path discontinuity: belief = the applied
            // half-stale rate, and no old-path delivery sample, honest
            // vote or probe cadence survives. WAKE resets none of this.
            forgetPathEvidence(belief: rate)
        }
        rateBitsPerSecond = rate
        lastAdjustAt = now
        return rate
    }

    /// The session moved to a new path (a validated migration): its base
    /// delay and capacity are unknown, so the old path's delay baselines,
    /// delivery samples, honest votes and probe cadence are forgotten and
    /// the belief restarts at the standing rate, which is kept. Otherwise
    /// a path with more base delay reads as standing inflation, and the
    /// rate falls every 500 ms until the old baseline ages out.
    public func notePathChanged(now: UInt64) {
        pathChangedAtNS = now
        forgetPathEvidence(belief: rateBitsPerSecond)
        delayBaselineWindows.removeAll(keepingCapacity: true)
        consecutiveInflatedReports = 0
        inflatedStreakStartMicros = nil
        inflatedStreakPeakMicros = nil
        inflatedStreakSinceNS = nil
        queuingDelayMicroseconds = nil
        lastAdjustAt = now
    }

    /// No old-path delivery sample, honest vote or probe cadence survives;
    /// the belief restarts at `belief`.
    private func forgetPathEvidence(belief: Int) {
        beliefBits = Double(belief)
        deliveryWindow.removeAll(keepingCapacity: true)
        deliveryWindowMax = nil
        recentRawDeliveries.removeAll(keepingCapacity: true)
        recentHonestDeliveries.removeAll(keepingCapacity: true)
        lastDeliveryRate = nil
        lastDeliveryAt = nil
        lastFullTrainRate = nil
        lastFullTrainAt = nil
        cadenceHoldUntilNS = 0
        cadenceBandFloorBits = .infinity
        recoveryTargetBits = nil
        recoveryClimbStarted = false
    }

    /// The burst-budget window B = min(2/fps, 25 ms) in ns, shared with
    /// EncoderVbvPolicy (which inverts ceiling / B back to a rate).
    public static func frameBudgetNS(fps: Int) -> UInt64 {
        min(UInt64(2_000_000_000) / UInt64(max(fps, 1)), 25_000_000)
    }

    /// The frame ceiling at the LIVE estimate: R×B/8 −
    /// higherClassBytes(B), converted from wire bytes to encoded bytes
    /// through the CURRENT FEC ladder — the encoder controls source
    /// bytes, but the pacer drains data + parity datagrams.
    public func frameByteCeiling(fps: Int) -> Int {
        let budgetNS = Self.frameBudgetNS(fps: fps)
        let budgetSeconds = Double(budgetNS) / 1e9
        let gross = Double(rateBitsPerSecond) * budgetSeconds / 8
        let reserves = Double(
            Self.audioReserveBitsPerSecond
                + Self.controlReserveBitsPerSecond
        ) * budgetSeconds / 8
        let availableWireBytes = max(Int(gross - reserves), 0)
        let totalShardBudget = availableWireBytes
            / WireBudget.maxDatagramByteCount

        // Production video always carries the connection-id TLV, and may
        // carry lastInputSeq. Budget for both so a frame admitted at this
        // ceiling cannot gain a surprise data shard at packetization.
        let extensionBytes = 1 + 2 + ConnectionId.byteCount
            + LastInputSeqTlv.encodedByteCount
        let payloadPerDataShard = WireBudget.maxWirePayloadByteCount
            - WireBudget.aeadTagByteCount - extensionBytes

        for dataShards in stride(
            from: FecGeometryTable.maxDataShards(fecRegime),
            through: 1,
            by: -1
        ) {
            guard let parity = try? FecGeometryTable.parityShards(
                forDataShards: dataShards, regime: fecRegime
            ) else { continue }
            if dataShards + parity <= totalShardBudget {
                return dataShards * payloadPerDataShard
            }
        }

        // Explicit custom floors below the production default remain
        // representable for deterministic estimator tests. Production's
        // 2 Mbps floor always fits at least one protected flight.
        return payloadPerDataShard
    }

    // MARK: - Internals

    private func clamp(_ rate: Int) -> Int {
        min(max(rate, config.floorBitsPerSecond), config.ceilingBitsPerSecond)
    }

    /// The median of the last few raw full-train samples: rejects a
    /// lone outlier either way, follows a majority. Nil before evidence.
    private var overuseAnchorRate: Double? {
        guard !recentRawDeliveries.isEmpty else { return nil }
        let sorted = recentRawDeliveries.map(\.rate).sorted()
        return sorted[sorted.count / 2]
    }

    /// The median of the fresh honest votes. Nil when none exist (a fall
    /// is then bounded multiplicative).
    private var honestAnchorRate: Double? {
        guard !recentHonestDeliveries.isEmpty else { return nil }
        let sorted = recentHonestDeliveries.map(\.rate).sorted()
        return sorted[sorted.count / 2]
    }

    private func expireWindows(now: UInt64) {
        let oldDeliveryCount = deliveryWindow.count
        deliveryWindow.removeAll {
            now &- $0.at > Self.sampleWindowNS
        }
        if deliveryWindow.count != oldDeliveryCount {
            var maximum: Double?
            for sample in deliveryWindow {
                if maximum.map({ sample.rate > $0 }) ?? true {
                    maximum = sample.rate
                }
            }
            deliveryWindowMax = maximum
        }
        // Mutated through `values` in place: iterating `keys` while
        // writing would copy the dictionary and every array.
        var index = delayBaselineWindows.values.startIndex
        while index != delayBaselineWindows.values.endIndex {
            delayBaselineWindows.values[index].removeAll {
                now &- $0.at > Self.sampleWindowNS
            }
            index = delayBaselineWindows.values.index(after: index)
        }
        lossWindow.removeAll {
            now &- $0.at > Self.lossWindowNS
        }
        postFecWindow.removeAll {
            now &- $0.at > Self.lossWindowNS
        }
        for (key, at) in recentNackShards where now &- at > Self.lossWindowNS {
            recentNackShards.removeValue(forKey: key)
        }
        recentHonestDeliveries.removeAll {
            now &- $0.at > Self.honestVoteWindowNS
        }
        recentRawDeliveries.removeAll {
            now &- $0.at > Self.sampleWindowNS
        }
        while let credit = hostDroppedVideoCredits.first,
              now > credit.at, now - credit.at > Self.lossWindowNS {
            hostDroppedVideoCredits.removeFirst()
        }
    }

    /// Differences the report's cumulative ledgers against the previous
    /// report's (u32 wrap-tolerant — the codec's documented semantics).
    private func absorbChannelLedgers(
        _ report: FeedbackReport, now: UInt64
    ) -> (missing: Int, received: Int) {
        var newMissing = 0
        var newReceived = 0
        var videoAttempted = 0
        for stats in report.channels {
            let previous = previousChannelTotals[stats.channel.rawValue]
            let dMissing = stats.missing &- (previous?.missing ?? 0)
            let dReceived = stats.received &- (previous?.received ?? 0)
            // A first report (or counter regression from a client
            // restart) contributes nothing this window.
            if previous != nil, dMissing < 1 << 31, dReceived < 1 << 31 {
                var missing = Int(dMissing)
                if stats.channel == .videoActive {
                    missing -= redeemHostDropCredits(upTo: missing)
                    videoAttempted += missing + Int(dReceived)
                }
                newMissing += missing
                newReceived += Int(dReceived)
            }
            previousChannelTotals[stats.channel.rawValue] =
                (stats.received, stats.missing)
        }
        if newMissing > 0 || newReceived > 0 {
            lossWindow.append(LossSample(
                at: now, missing: newMissing, received: newReceived,
                videoAttempted: videoAttempted
            ))
        }
        return (newMissing, newReceived)
    }

    /// Cancels up to `missing` video gaps against host-drop credits,
    /// oldest first; returns how many it cancelled.
    private func redeemHostDropCredits(upTo missing: Int) -> Int {
        var redeemed = 0
        while redeemed < missing, let credit = hostDroppedVideoCredits.first {
            let take = min(credit.count, missing - redeemed)
            redeemed += take
            if take == credit.count {
                hostDroppedVideoCredits.removeFirst()
            } else {
                hostDroppedVideoCredits[0].count -= take
            }
        }
        return redeemed
    }

    /// Counts the report's NACK section into the post-FEC window:
    /// distinct (frame, shard) pairs, deduped across reports inside the
    /// window (a re-NACK is the client insisting, not new loss).
    /// Frames in `recusedFrames` contribute nothing: their NACKs measure
    /// our drain speed, not the path.
    private func absorbNacks(
        _ report: FeedbackReport, recusedFrames: Set<UInt32>, now: UInt64
    ) -> Int {
        var fresh = 0
        for nack in report.nacks {
            if recusedFrames.contains(nack.frame.rawValue) {
                stats.nackShardsRecused += nack.missingShards.count
                continue
            }
            for shard in nack.missingShards {
                let key = UInt64(nack.frame.rawValue) << 8 | UInt64(shard)
                if recentNackShards[key] == nil { fresh += 1 }
                recentNackShards[key] = now
            }
        }
        if fresh > 0 {
            postFecWindow.append(PostFecSample(at: now, shardCount: fresh))
            stats.nackShardsCounted += fresh
        }
        return fresh
    }

    private func currentLossFraction() -> Double {
        var missing = 0
        var received = 0
        for sample in lossWindow {
            missing += sample.missing
            received += sample.received
        }
        let total = missing + received
        guard total > 0 else { return 0 }
        return Double(missing) / Double(total)
    }

    /// NACKed shards over video datagrams attempted, both windowed.
    /// With no attempt evidence the fraction is unknown and reads 0: a
    /// NACK alone is no denominator. It saturates at 1.
    private func currentPostFecLossFraction() -> Double {
        let nacked = postFecWindow.reduce(0) { $0 + $1.shardCount }
        guard nacked > 0 else { return 0 }
        let attempted = lossWindow.reduce(0) { $0 + $1.videoAttempted }
        guard attempted > 0 else { return 0 }
        return min(Double(nacked) / Double(attempted), 1)
    }

    private struct MatchedSample {
        var channel: UInt8
        var sendNS: UInt64
        var bytes: Int
        var arrivalMicros: UInt64
        var deliveryFrame: UInt32?
        /// The pacer rate recorded at this datagram's release.
        var paceBitsPerSecond: Int
    }

    private func matchDispersion(
        _ report: FeedbackReport
    ) -> [MatchedSample] {
        guard let dispersion = report.dispersion else { return [] }
        var matched: [MatchedSample] = []
        matched.reserveCapacity(dispersion.samples.count)
        for sample in dispersion.samples {
            let key = UInt32(sample.channel.rawValue) << 16
                | UInt32(sample.seq.rawValue)
            guard let slot = ledgerIndex[key], let record = ledger[slot],
                  record.key == key else {
                stats.dispersionSamplesUnmatched += 1
                continue
            }
            if let pathChangedAtNS, record.sendNS < pathChangedAtNS {
                stats.dispersionSamplesFromOldPath += 1
                continue
            }
            stats.dispersionSamplesMatched += 1
            matched.append(MatchedSample(
                channel: sample.channel.rawValue,
                sendNS: record.sendNS,
                bytes: record.bytes,
                arrivalMicros: dispersion.base.microseconds
                    &+ UInt64(sample.arrivalDeltaMicroseconds),
                deliveryFrame: record.deliveryFrame,
                paceBitsPerSecond: record.paceBitsPerSecond
            ))
        }
        matched.sort {
            $0.channel == $1.channel
                ? $0.sendNS < $1.sendNS
                : $0.channel < $1.channel
        }
        return matched
    }

    /// Segments matched samples by channel and fresh-video FRAME, then
    /// into trains by send spacing within a frame, so source cadence
    /// never chains into a fake low-capacity sample.
    private func absorbDeliveryTrains(
        _ matched: [MatchedSample], now: UInt64
    ) {
        guard matched.count >= 2 else { return }
        let wirePerDatagramNS = UInt64(
            Double(1_152 * 8) / Double(rateBitsPerSecond) * 1e9
        )
        let gapNS = max(Self.trainGapNS, 3 * wirePerDatagramNS)
        func closeTrain(_ range: Range<Int>) {
            let train = matched[range]
            guard train.first?.deliveryFrame != nil else { return }
            guard train.count >= 3 else { return }
            var firstArrival = UInt64.max
            var lastArrival: UInt64 = 0
            var firstSend = UInt64.max
            var lastSend: UInt64 = 0
            var bytes = 0
            var paceBits = 0
            for (offset, sample) in train.enumerated() {
                firstArrival = min(firstArrival, sample.arrivalMicros)
                lastArrival = max(lastArrival, sample.arrivalMicros)
                firstSend = min(firstSend, sample.sendNS)
                lastSend = max(lastSend, sample.sendNS)
                paceBits = max(paceBits, sample.paceBitsPerSecond)
                if offset > 0 { bytes += sample.bytes }
            }
            guard lastArrival > firstArrival else { return }
            // Classic packet-train accounting: the first packet's bytes
            // opened the measurement window, everything behind it was
            // delivered inside it.
            let spanSeconds = Double(lastArrival - firstArrival) / 1e6
            let rate = Double(bytes) * 8 / spanSeconds
            lastDeliveryRate = rate
            lastDeliveryAt = now
            // Only FULL trains vote or touch the belief: micro-trains
            // measure their own pacing. Short trains still feed the
            // windowed max (×0.5) and evidence freshness.
            if train.count >= Self.minTrainPackets {
                recentRawDeliveries.append((at: now, rate: rate))
                if recentRawDeliveries.count > Self.overuseAnchorSampleCount {
                    recentRawDeliveries.removeFirst()
                }
                // Freshest reading, not a max: a squeeze right after a
                // drain must not inherit the drain's super-rate sample.
                lastFullTrainRate = rate
                lastFullTrainAt = now
                // Invariant 1: judged against the train's MAX recorded
                // pace, the conservative side across a rate move.
                let pace = Double(
                    paceBits > 0 ? paceBits : rateBitsPerSecond
                )
                let honest = rate
                    < pace * (1 - Self.censoredSampleMarginFraction)
                if honest {
                    let sendSpan = lastSend - firstSend
                    // See `stretchGapDominanceFraction`: a hole-
                    // dominated train keeps its other roles, no vote.
                    let arrivals = train.map(\.arrivalMicros).sorted()
                    var maxGap: UInt64 = 0
                    for i in 1..<arrivals.count {
                        maxGap = Swift.max(
                            maxGap, arrivals[i] - arrivals[i - 1])
                    }
                    let span = arrivals.last! - arrivals.first!
                    let holeDominated = Double(maxGap)
                        > Self.stretchGapDominanceFraction * Double(span)
                    if sendSpan < Self.honestMinSendSpanNS {
                        // One sendmmsg/pacer microburst shows receiver
                        // serialization, not sustained capacity.
                        stats.burstGeometryTrainsRecused += 1
                    } else if holeDominated {
                        stats.stretchedTrainsRecused += 1
                    } else {
                        stats.honestSamples += 1
                        recentHonestDeliveries.append((at: now, rate: rate))
                        if recentHonestDeliveries.count
                            > Self.overuseAnchorSampleCount {
                            recentHonestDeliveries.removeFirst()
                        }
                    }
                } else {
                    // Censored (≈ our pace) or compressed (a drain):
                    // either way it can only prove capacity ≥ itself.
                    stats.censoredSamples += 1
                    if rate >= pace * Self.stallBurstRateFactor {
                        // A COMPRESSED drain: a hole just closed, so
                        // every earlier stretched reading measured the
                        // hole, not the path. Purge those votes.
                        recentHonestDeliveries.removeAll()
                    }
                }
                // Any full train may RAISE the belief, capped at its
                // pace: arriving faster than we sent is queue
                // compression, proving only that the path carried our
                // pace.
                let sustainable = min(rate, pace)
                if beliefBits.map({ sustainable > $0 }) ?? true {
                    beliefBits = sustainable
                    stats.beliefRaises += 1
                }
            }
            stats.deliverySamples += 1
            let weighted = train.count >= Self.minTrainPackets
                ? rate : rate * 0.5
            deliveryWindow.append(DeliverySample(at: now, rate: weighted))
            if deliveryWindowMax.map({ weighted > $0 }) ?? true {
                deliveryWindowMax = weighted
            }
        }
        var channelStart = 0
        while channelStart < matched.count {
            let channel = matched[channelStart].channel
            var channelEnd = channelStart + 1
            while channelEnd < matched.count,
                  matched[channelEnd].channel == channel {
                channelEnd += 1
            }
            // Audio's cadence and video repairs are not capacity probes.
            // Keep them in the per-channel delay sensor, but only
            // fresh-video samples carry a delivery-frame identity.
            guard channel == ChannelId.videoActive.rawValue else {
                channelStart = channelEnd
                continue
            }
            var trainStart = channelStart
            if channelEnd - channelStart >= 2 {
                for i in (channelStart + 1)..<channelEnd {
                    if matched[i].deliveryFrame
                            != matched[i - 1].deliveryFrame
                        || matched[i].sendNS &- matched[i - 1].sendNS > gapNS {
                        closeTrain(trainStart..<i)
                        trainStart = i
                    }
                }
                closeTrain(trainStart..<channelEnd)
            }
            channelStart = channelEnd
        }
    }

    /// Returns true when some channel's minimum one-way delay proxy
    /// sits above its rolling baseline by more than the overuse
    /// threshold (per-channel — see the header's DSCP-fast-lane note).
    private func absorbDelay(
        _ matched: [MatchedSample], now: UInt64
    ) -> Bool {
        guard !matched.isEmpty else {
            // No samples: no delay evidence either way. The inflation
            // streak survives (silence must not launder an overloaded
            // path), but nothing new fires.
            return false
        }
        var worstInflation: Int64 = 0
        var haveBaseline = false
        var perChannelMin: [UInt8: Int64] = [:]
        for sample in matched {
            let delay = Int64(bitPattern: sample.arrivalMicros)
                &- Int64(bitPattern: sample.sendNS / 1_000)
            if perChannelMin[sample.channel].map({ delay < $0 }) ?? true {
                perChannelMin[sample.channel] = delay
            }
        }
        for (channel, reportMin) in perChannelMin {
            // The baseline is the lowest CORROBORATED delay: the
            // second-smallest report minimum in the window, so one
            // freak-fast report (receive-wake jitter) cannot pin the
            // floor and read every later report as inflated.
            let baseline = delayBaselineWindows[channel].flatMap {
                window -> Int64? in
                var lowest: Int64?
                var second: Int64?
                for sample in window {
                    let delay = sample.minDelayMicros
                    if lowest.map({ delay < $0 }) ?? true {
                        second = lowest
                        lowest = delay
                    } else if second.map({ delay < $0 }) ?? true {
                        second = delay
                    }
                }
                return second ?? lowest
            }
            delayBaselineWindows[channel, default: []].append(
                DelaySample(at: now, minDelayMicros: reportMin)
            )
            guard let baseline else { continue }
            haveBaseline = true
            let inflation = saturatingDifference(
                reportMin, min(baseline, reportMin))
            worstInflation = max(worstInflation, inflation)
        }
        guard haveBaseline else {
            queuingDelayMicroseconds = 0
            consecutiveInflatedReports = 0
            inflatedStreakSinceNS = nil
            return false
        }
        queuingDelayMicroseconds = worstInflation
        if worstInflation > Self.overuseThresholdMicroseconds {
            if consecutiveInflatedReports == 0 {
                openInflatedStreak(at: worstInflation, now: now)
            } else {
                let peak = inflatedStreakPeakMicros ?? worstInflation
                let drained = worstInflation <= peak / 2
                    && peak - worstInflation
                        >= Self.overuseThresholdMicroseconds
                drainedStreakReports = drained ? drainedStreakReports + 1 : 0
                if drainedStreakReports >= Self.drainCorroborationReports {
                    // The queue fell to half its peak on consecutive
                    // reports: the path is outrunning what we offer, so
                    // the pressure this streak measured is spent. Its
                    // honest votes were taken inside the hole; a real
                    // standing queue must persist again, from here, to
                    // move the rate.
                    recentHonestDeliveries.removeAll()
                    openInflatedStreak(at: worstInflation, now: now)
                    stats.drainRestarts += 1
                } else {
                    inflatedStreakPeakMicros = max(peak, worstInflation)
                }
            }
            consecutiveInflatedReports += 1
            return true
        }
        consecutiveInflatedReports = 0
        drainedStreakReports = 0
        inflatedStreakStartMicros = nil
        inflatedStreakPeakMicros = nil
        inflatedStreakSinceNS = nil
        return false
    }

    /// Starts invariant 2's persistence clock at this report.
    private func openInflatedStreak(at inflation: Int64, now: UInt64) {
        inflatedStreakStartMicros = inflation
        inflatedStreakPeakMicros = inflation
        inflatedStreakSinceNS = now
        drainedStreakReports = 0
    }

    /// Climb needs a delivery train inside `upshiftEvidenceWindowNS`.
    /// Falls share that bar, or standing pacer backlog as proof of
    /// real demand. Sparse keepalive (neither trains nor backlog)
    /// freezes — doctrine forbids inventing probe traffic just to
    /// reverse a one-way ratchet.
    private func hasFreshDeliveryEvidence(now: UInt64) -> Bool {
        lastDeliveryAt.map {
            now &- $0 <= Self.upshiftEvidenceWindowNS
        } ?? false
    }

    private func applyControlLaw(
        overuse: Bool,
        lossFraction: Double,
        postFecLossFraction: Double,
        pacerBacklogBytes: Int,
        now: UInt64
    ) -> RateEstimatorVerdict.Change? {
        let downshiftAllowed = lastDownshiftAt.map {
            now &- $0 >= Self.downshiftMinIntervalNS
        } ?? true
        let deliveryFresh = hasFreshDeliveryEvidence(now: now)
        let backlogFloorBytes = max(1, Int(
            Double(rateBitsPerSecond)
                * Double(Self.selfReferenceBacklogWindowNS) / 8e9
        ))
        let backlogStanding = pacerBacklogBytes >= backlogFloorBytes
        let fallEvidence = deliveryFresh || backlogStanding

        if overuse, downshiftAllowed {
            // THE HONESTY LAW. The verdict decided WHEN; this decides
            // WHETHER and WHERE, from what a censored sender cannot
            // fake. EXECUTE on instant corroboration, or on persisted
            // pressure that is not purely self-explaining: a grown
            // queue, a fresh honest median under the belief, or no
            // standing backlog all testify; standing backlog with only
            // censored samples is us measuring ourselves.
            let anchor = overuseAnchorRate.map(Int.init)
            let queueGrew = inflatedStreakStartMicros.map {
                saturatingDifference(queuingDelayMicroseconds ?? 0, $0)
                    >= Self.overuseThresholdMicroseconds
            } ?? false
            let honestMedian = honestAnchorRate
            let belief = beliefBits ?? Double(rateBitsPerSecond)
            let honestLow = honestMedian.map { $0 < belief } ?? false
            let selfExplaining = backlogStanding && honestMedian == nil
            // Instant corroboration: pre-FEC loss past the clean band,
            // or post-FEC past rung 3. Milder post-FEC waits for
            // persistence: a closed hole echoes a percent or two of
            // NACKs for frames that already drained.
            let instant = lossFraction >= Self.lossCleanThreshold
                || postFecLossFraction > Self.postFecDownshiftThreshold
            let persisted = now &- (inflatedStreakSinceNS ?? now)
                >= Self.beliefDemotionSustainNS
            let wouldFall = instant
                || (persisted && (queueGrew || honestLow || !selfExplaining))

            if wouldFall, !fallEvidence {
                // No recent train and no standing backlog: keepalive
                // cannot move the rate. Overuse still blocks rises.
                stats.sparseEvidenceHolds += 1
                lastAdjustAt = now
                return nil
            } else if wouldFall {
                // The fall executes against the belief. Invariant 2: a
                // fresh honest median below it demotes it, so the fall
                // lands on measured delivery; with no honest evidence
                // the fall is bounded multiplicative.
                let demoted: Double
                if let honestMedian, honestLow {
                    demoted = honestMedian
                    beliefBits = honestMedian
                    stats.beliefDemotions += 1
                } else {
                    demoted = belief
                }
                lastOveruseFall = OveruseFallForensics(
                    anchorBitsPerSecond: anchor,
                    rateBeforeBitsPerSecond: rateBitsPerSecond,
                    streakPeakMicroseconds: inflatedStreakPeakMicros,
                    streakStartMicroseconds: inflatedStreakStartMicros,
                    queuingDelayMicroseconds: queuingDelayMicroseconds,
                    pacerBacklogBytes: pacerBacklogBytes,
                    lastFullTrainBitsPerSecond:
                        lastFullTrainRate.map(Int.init),
                    lastFullTrainAgeNS:
                        lastFullTrainAt.map { now &- $0 },
                    lossFraction: lossFraction,
                    postFecLossFraction: postFecLossFraction,
                    capacityBeliefBitsPerSecond: Int(demoted),
                    honestAnchorBitsPerSecond: honestMedian.map(Int.init),
                    streakAgeNS: inflatedStreakSinceNS.map { now &- $0 }
                )
                // A fall while probing ABOVE the belief it held, inside
                // the demoted belief's headroom band, is a failed probe:
                // arm the cadence. A fall from at or below the belief (the
                // rate was only using capacity it had proven) or a crash
                // located no wall.
                let bandFloor = demoted / Self.probeHeadroomFactor
                let probing = Double(rateBitsPerSecond) > belief
                let crash = demoted
                    < Double(rateBitsPerSecond) * Self.crashDemotionFraction
                if probing, Double(rateBitsPerSecond) >= bandFloor, !crash {
                    cadenceHoldUntilNS = now &+ Self.probeCadenceNS
                    cadenceBandFloorBits = bandFloor
                }
                noteFallForRecovery(from: rateBitsPerSecond, now: now,
                                    armsTarget: true)
                rateBitsPerSecond = clamp(min(
                    Int(demoted * Self.downshiftFactor),
                    Int(Double(rateBitsPerSecond) * Self.downshiftFactor)
                ))
                lastDownshiftAt = now
                lastAdjustAt = now
                stats.downshifts += 1
                return .overuse
            } else if persisted {
                // Self-explaining persisted pressure: held. Overuse
                // still blocks rises; the fall limiter stays free.
                stats.selfReferenceHolds += 1
            } else {
                // Withheld awaiting persistence; booked as a stall hold
                // when fresh drain evidence sits inside a bounded hole.
                let holePeak = inflatedStreakPeakMicros ?? Int64.max
                let drainFresh = lastFullTrainAt.map {
                    now &- $0 <= Self.stallEvidenceWindowNS
                } ?? false
                let drainOutranPace = drainFresh
                    && (lastFullTrainRate ?? 0)
                        >= Double(rateBitsPerSecond)
                        * Self.stallBurstRateFactor
                if drainOutranPace,
                   holePeak <= Self.stallGapCeilingMicroseconds {
                    stats.stallHolds += 1
                } else {
                    stats.fallDeferrals += 1
                }
            }
        }

        if lossFraction > Self.lossDownshiftThreshold, downshiftAllowed {
            guard fallEvidence else {
                stats.sparseEvidenceHolds += 1
                lastAdjustAt = now
                return nil
            }
            noteFallForRecovery(from: rateBitsPerSecond, now: now,
                                armsTarget: false)
            // GCC's loss response: rate × (1 − loss/2) — a 20% loss
            // window falls 10%, a 50% catastrophe falls 25% per beat.
            rateBitsPerSecond = clamp(Int(
                Double(rateBitsPerSecond) * (1 - lossFraction / 2)
            ))
            lastDownshiftAt = now
            lastAdjustAt = now
            stats.downshifts += 1
            stats.lossDownshifts += 1
            return .loss
        }

        if postFecLossFraction > Self.postFecDownshiftThreshold,
           downshiftAllowed {
            guard fallEvidence else {
                stats.sparseEvidenceHolds += 1
                lastAdjustAt = now
                return nil
            }
            noteFallForRecovery(from: rateBitsPerSecond, now: now,
                                armsTarget: false)
            // Rung 3: loss FEC could not absorb, so no hold band.
            rateBitsPerSecond = clamp(Int(
                Double(rateBitsPerSecond) * Self.downshiftFactor
            ))
            lastDownshiftAt = now
            lastAdjustAt = now
            stats.downshifts += 1
            stats.postFecDownshifts += 1
            return .postFecLoss
        }

        // Only the stricter post-FEC clean column updates lastGoodRate;
        // mild NACK echo may still climb below.
        if !overuse, lossFraction < Self.lossCleanThreshold,
           postFecLossFraction <= Self.postFecCleanThreshold {
            lastGoodRate = rateBitsPerSecond
        }

        // Rise only on evidence (see the header), toward the PROBE
        // ceiling.
        let probeCeiling = beliefBits.map {
            min(config.ceilingBitsPerSecond,
                max(config.floorBitsPerSecond,
                    Int($0 * Self.probeHeadroomFactor)))
        } ?? config.ceilingBitsPerSecond
        let mildPostFec = postFecLossFraction > Self.postFecCleanThreshold
            && postFecLossFraction <= Self.postFecDownshiftThreshold
        guard rateBitsPerSecond < probeCeiling,
              !overuse, lossFraction < Self.lossCleanThreshold,
              postFecLossFraction <= Self.postFecDownshiftThreshold,
              let deliveredAt = lastDeliveryAt,
              now &- deliveredAt <= Self.upshiftEvidenceWindowNS,
              lastDownshiftAt.map({
                  now &- $0 >= Self.upshiftHoldAfterDownshiftNS
              }) ?? true
        else {
            lastAdjustAt = now
            return nil
        }
        // Back inside the band where the last probe failed: wait for
        // the cadence.
        if Double(rateBitsPerSecond) >= cadenceBandFloorBits,
           now < cadenceHoldUntilNS {
            stats.upshiftsCadenceHeld += 1
            lastAdjustAt = now
            return nil
        }
        let elapsedSeconds = Double(now &- lastAdjustAt) / 1e9
        guard elapsedSeconds > 0 else { return nil }
        let recoveryTarget = activeRecoveryTarget(now: now)
        let gain = recoveryTarget == nil
            ? Self.upshiftPerSecond : Self.recoveryUpshiftPerSecond
        let factor = 1 + gain * min(elapsedSeconds, 1)
        var wanted = Int(Double(rateBitsPerSecond) * factor)
        if let recoveryTarget {
            // The recovery budget returns to the pre-fall rate, never
            // past it; above it the ordinary probe resumes.
            wanted = min(wanted, Int(recoveryTarget))
            recoveryClimbStarted = true
            stats.recoveryUpshifts += 1
        }
        if wanted > probeCeiling, probeCeiling < config.ceilingBitsPerSecond {
            stats.upshiftsDamped += 1
        }
        rateBitsPerSecond = clamp(min(wanted, probeCeiling))
        lastAdjustAt = now
        stats.upshifts += 1
        if mildPostFec { stats.upshiftsUnderMildPostFec += 1 }
        return .evidence
    }

    /// Every executing fall passes through here. A fall after the
    /// recovery climb began means the path pushed back: the target is
    /// dropped. Otherwise an overuse fall arms (or keeps) the target at
    /// the highest pre-fall rate of the episode.
    private func noteFallForRecovery(
        from rateBefore: Int, now: UInt64, armsTarget: Bool
    ) {
        if recoveryClimbStarted {
            recoveryTargetBits = nil
            recoveryClimbStarted = false
            return
        }
        guard armsTarget else { return }
        let alive = activeRecoveryTarget(now: now) ?? 0
        recoveryTargetBits = max(alive, Double(rateBefore))
        recoveryTargetUntilNS = now &+ Self.recoveryTargetWindowNS
    }

    /// The live recovery target, or nil (none armed, expired, or the
    /// rate is back within `recoveryTargetFraction` of it — which
    /// retires it).
    private func activeRecoveryTarget(now: UInt64) -> Double? {
        guard let target = recoveryTargetBits else { return nil }
        if now >= recoveryTargetUntilNS
            || Double(rateBitsPerSecond) >= target * Self.recoveryTargetFraction {
            recoveryTargetBits = nil
            recoveryClimbStarted = false
            return nil
        }
        return target
    }

    /// The FEC regime step law (see the header). Returns the new regime
    /// when this ingest moved it.
    private func stepRegime(
        postFecLossFraction: Double, sawNacks: Bool, now: UInt64
    ) -> FecRegime? {
        if sawNacks || postFecLossFraction >= Self.postFecCleanThreshold {
            lastPostFecEvidenceAt = now
        }
        switch fecRegime {
        case .clean:
            guard postFecLossFraction > Self.postFecDownshiftThreshold
            else { return nil }
            fecRegime = .lossy
            stats.regimeSteps += 1
            return .lossy
        case .lossy:
            // Every fresh NACK re-anchors the step-down hold.
            guard let lastEvidence = lastPostFecEvidenceAt,
                  now &- lastEvidence >= Self.regimeStepDownHoldNS,
                  postFecLossFraction < Self.postFecCleanThreshold
            else { return nil }
            fecRegime = .clean
            stats.regimeSteps += 1
            return .clean
        }
    }

    private func closeRecoveryWindows(
        sawLoss: Bool, sawOveruse: Bool, now: UInt64
    ) -> [Bool] {
        guard let start = recoveryWindowStartNS else {
            // The first report after entering RECOVERY opens the first
            // window; its own evidence seeds it.
            recoveryWindowStartNS = now
            recoveryWindowSawLoss = sawLoss
            recoveryWindowSawOveruse = sawOveruse
            return []
        }
        recoveryWindowSawLoss = recoveryWindowSawLoss || sawLoss
        recoveryWindowSawOveruse = recoveryWindowSawOveruse || sawOveruse
        guard now &- start >= Self.recoveryWindowNS else { return [] }
        let clean = !recoveryWindowSawLoss && !recoveryWindowSawOveruse
        recoveryWindowStartNS = now
        recoveryWindowSawLoss = false
        recoveryWindowSawOveruse = false
        return [clean]
    }
}

/// a − b pinned to Int64's range instead of trapping. One-way delays mix
/// the host's clock with client-supplied arrival stamps, so their
/// differences can span more than Int64 holds.
private func saturatingDifference(_ a: Int64, _ b: Int64) -> Int64 {
    let (difference, overflow) = a.subtractingReportingOverflow(b)
    guard overflow else { return difference }
    return b < 0 ? .max : .min
}
