// RateEstimator: the HS-16 congestion estimator — the component the
// pacer's setRate seam, W4b's RECOVERY window verdicts, and the IdrPacing
// policies have been waiting for. Sans-IO in the house style: no sockets,
// no threads, no clock — every entry point takes `now` (monotonic ns, the
// pacer domain) and the caller owns scheduling.
//
// The design is resiliency §2.2 made code, sized to what the wire
// actually carries today (CL-3/CL-8's FeedbackSender every 25–50 ms):
//
//   • SEND LEDGER — the session records every outbound datagram's
//     (channel, seq) → (send instant, wire bytes) at pump time. This is
//     the sender half of the packet-train measurement: dispersion
//     samples name (channel, seq), the ledger supplies when it left and
//     how big it was.
//   • DELIVERY RATE — matched dispersion samples are segmented into
//     trains by SEND spacing (a paced frame drains as back-to-back ≤1 ms
//     batches, so a ≤2 ms send gap keeps one frame's shards together);
//     each train ≥3 packets yields one delivery-rate sample:
//     (bytes behind the first arrival) / (arrival span). Samples ride a
//     10 s windowed-MAX filter (BBR's shape) → btlRate. Trains shorter
//     than 8 packets are weighted ×0.5 before the max (resiliency §2.2:
//     Wi-Fi aggregation makes short-train dispersion noisy — they may
//     inform, they rarely win). Client-side decimation only ever drops
//     interior samples, so the measurement errs LOW — measured delivery,
//     never configured hope.
//   • QUEUING DELAY — per matched sample, delay = client arrival µs −
//     host send µs: an unknown constant clock offset plus the real
//     one-way delay. Each report contributes its PER-CHANNEL minimum
//     (the least self-queued packet of that channel's trains); a 10 s
//     rolling min per channel is the baseline; the inflation estimate
//     is the MAX inflation across channels with samples. Per-channel,
//     deliberately: DSCP-aware bottlenecks (Wi-Fi EDCA, any
//     prio qdisc) give audio a fast lane, so a global min would let
//     clean audio samples mask a growing video queue — the exact
//     congestion the estimator exists to catch. The offset cancels in
//     the subtraction and 50 ppm skew moves it < 1 ms per window.
//     This is the timing pillar's min-filter idea pointed at queue
//     growth instead of clock offset. (GCC's trendline slope was
//     considered; the min-baseline inflation detector is the same
//     delay-gradient family with far fewer moving parts in virtual-time
//     tests — revisit if live evidence wants the slope.)
//   • LOSS — the report's cumulative per-channel ledgers, differenced
//     against the previous report (the codec's documented consumption),
//     over a rolling 1 s window: post-arrival loss fraction.
//   • POST-FEC LOSS (HS-17) — the report's NACK section is the wire's
//     post-FEC evidence: every entry names shards of a frame FEC could
//     not recover. Deduped (frame, shard) counts over the same rolling
//     1 s window, against the video channel's attempted datagrams
//     (received + missing ledger deltas), give the rung-3 detector its
//     number: post-FEC loss > 2% over 1 s (resiliency §4 rung 3).
//   • CONTROL LAW — capped CBR with downshift/upshift (§2.2 rule 4):
//     - overuse (inflation > threshold on 2 consecutive reports) →
//       rate = 0.85 × measured delivery rate (GCC's REMB shape: anchor
//       the fall to what the path actually delivered), at most one
//       downshift per 500 ms. The anchor is the MEDIAN of the last few
//       raw delivery samples, not the single freshest one (HS-21):
//       Wi-Fi aggregation coughs up the occasional lone garbage
//       short-train sample, and anchoring a fall to one such sample
//       craters a clean path in a single step (HS-20 live finding: one
//       garbage sample took a 20 Mbps path to 810 kbps). A median over
//       a short count-window rejects a lone outlier in either direction
//       while still tracking a GENUINE sustained drop within a couple
//       of reports — well inside the 500 ms fall limiter — so the
//       fast-fall property the pillar needs on real overuse is intact
//       and only the single-sample vulnerability dies;
//     - loss over the rolling 1 s window, GCC's three-band law on the
//       PRE-FEC missing counts the wire actually carries: < 2% clean
//       (may rise), 2–10% HOLD (FEC's parity absorbs this band —
//       resiliency G1 pins that a 5% uniform path keeps streaming, so
//       crashing the rate on it would be dishonest), > 10% fall
//       ×(1 − loss/2), same 500 ms limiter;
//     - post-FEC loss over the same window > 2% (rung 3, the NACK
//       evidence HS-17 wired in) → multiplicative fall ×0.85, same
//       500 ms limiter — this band is NOT held: loss FEC could not
//       absorb is the pillar's downshift-and-step trigger;
//     - clean + fresh delivery evidence → upshift ≤10%/s toward the
//       negotiated ceiling, held for 1 s after any downshift so the
//       queue can drain. The standing rate is deliberately allowed
//       above btlRate×0.8: paced sends at rate R self-limit the
//       measurement to ≈R, so a standing 0.8×btlRate cap would spiral
//       every clean path to the floor. The 0.8 factor applies where
//       the pillar needs it — at the overuse fall.
//     THE SELF-REFERENCE GATE (HS-22c, finding (ii)): the same
//     self-limitation poisons the overuse ANCHOR. With the pacer
//     holding standing backlog, a multi-quantum frame drains as one
//     ≥8-packet train paced at exactly R — the train measures OUR OWN
//     pacing, not the path — and an overuse verdict then anchors the
//     fall to 0.85 × self; each fall re-squeezes the pacer, the next
//     train measures the new self, and one probe run spiraled a
//     90 Mbps wire to the 500 kbps floor. So: when the caller reports
//     standing backlog (≥ `selfReferenceBacklogWindowNS` of bytes at
//     the standing rate) AND the anchor median sits within
//     `selfReferenceBandFraction` of the standing rate (or above it),
//     the sample is a measurement of us — it may HOLD the rate (the
//     overuse verdict still blocks every rise), it may not anchor a
//     fall. The gate CANNOT mask real degradation, because a fall
//     stays permitted on any of three honest signatures a
//     self-limited pacer can never produce: (1) the anchor median
//     measurably BELOW the band — a slower path stretches every
//     train, so genuine dips read genuinely low (the HS-21/22 fast-
//     fall pins are this case, intact); (2) loss — pre-FEC at or over
//     the clean threshold, or ANY post-FEC evidence (pacing at ≤ the
//     path's rate drops nothing); (3) queue GROWTH — a path whose
//     capacity sits at/just under the standing rate builds delay
//     monotonically at the deficit rate, so inflation grown another
//     `overuseThresholdMicroseconds` past the streak's opening report
//     corroborates within a few 25–50 ms beats (inside one 500 ms
//     fall-limiter window — at most one beat later than today).
//     Self-caused burst bumps drain and reset the streak instead.
//     THE STALL GATE (HS-23) lived here until HS-28 retired it: the
//     Wi-Fi study's scan dwells (the receiver's radio dark 70–100 ms,
//     the AP queuing, then one compressed drain — nothing lost,
//     nothing slow) read host-side as textbook overuse and once pinned
//     a ~100 Mbps-capable path at 13–17 Mbps. The capacity-belief
//     model handles the cycle with no shape classifier: the drain's
//     compressed super-rate train RAISES the belief, the drain report
//     clears the pressure streak, and invariant 2's persistence means
//     a bounded hole can never sustain pressure across a full
//     fall-limiter window — so the fall the gate used to refuse is
//     simply never corroborated. `stallHolds` keeps the vocabulary in
//     the books for withheld beats with fresh drain evidence.
//     Floor 500 kbps (a paced IDR within 2 s even on a terrible path),
//     ceiling = the negotiated session rate (W7 carries no bitrate key
//     in v1, so the session config IS the negotiated ceiling).
//   • THE CAPACITY BELIEF (HS-28 — the estimator-honesty reformulation):
//     a paced sender can never measure more than it sends — every
//     delivery sample is censored from above by our own rate — and the
//     old law treated censored samples as unbiased capacity estimates,
//     so any rate reduction self-confirmed forever (the truth-probe:
//     a session pinned at 0.1–1.6 Mbps while a concurrent flood
//     delivered 30 Mbps at 0% loss through the same air). Measurement
//     is now separated from control:
//     - INVARIANT 1 (app-limited discipline): the send ledger records
//       the pacer's standing rate at each datagram's RELEASE, so every
//       full train is classified mechanically at sample production:
//       CENSORED (measured ≈ or above its own recorded pace — the
//       train measures us, and can only prove capacity ≥ that rate),
//       HONEST (measured below `censoredSampleMarginFraction` under
//       the pace — the path stretched the train, the sample speaks
//       for the path), or COMPRESSED (≥ `stallBurstRateFactor` × pace
//       — accumulated-and-released drain evidence). Censored and
//       compressed samples may RAISE the belief — delivery above
//       expectation is always honest news — they never vote in a
//       fall anchor and never lower the belief.
//     - THE BELIEF `beliefBits` is one number: raised instantly by any
//       full-train sample above it, and it FALLS only by invariant-2
//       demotion — never by aging, because aging-while-censored was
//       exactly the self-confirmation vector (leg B: ten seconds at
//       the floor aged every honest sample out of the max window and
//       the windowed max itself became the trickle).
//     - INVARIANT 2 (sustained corroboration): the belief demotes only
//       on evidence a censored sender cannot manufacture — a fresh
//       honest-sample median below the belief — and the demotion rides
//       the executing fall. `inflatedStreakSinceNS` tracks how long
//       overuse pressure has persisted (`beliefDemotionSustainNS`,
//       ≥ one full 500 ms fall-limiter window into the next — a dwell
//       structurally cannot sustain it; a genuine squeeze does within
//       ~1 s). While the three shape-gates below still stand they
//       decide WHEN a fall executes; the persistence machinery is
//       their staged replacement (retired one commit at a time, each
//       justified by the gate's frozen pins passing without it).
//     - CONTROL is unchanged in role, honest in inputs: verdicts
//       (delay inflation, loss bands) still decide WHEN; the fall
//       anchor answers to the BELIEF — clamp(min(0.85 × demoted
//       belief, 0.85 × standing rate)) — never to the median of raw
//       recent samples. A censored trickle therefore cannot crater
//       the rate in one step: with no honest evidence the fall is
//       bounded multiplicative (0.85 × rate per limiter beat), and
//       with honest evidence it lands exactly on measured delivery
//       as the HS-21 pins always demanded.
//     - SELF-INFLICTED EVIDENCE RECUSES ITSELF: NACK entries naming
//       frames whose shards are still queued in our own pacer are the
//       client's completion presumption expiring mid-drain (the
//       deep-floor starvation seam), not path evidence — the session
//       passes them as `recusedNackFrames` and they feed neither the
//       post-FEC fractions nor the regime ladder. The pre-FEC ledger
//       deltas were audited clean: host-side skips (pre-encode
//       backpressure, unprotectable drops) never consume a seq or a
//       frame number, so they cannot read as client-visible gaps.
//   • RECOVERY VERDICTS — W4b's `.feedbackWindow(clean:)` input, owned
//     here now (the 25 ms stub in Session retires): while the machine
//     is in RECOVERY every parsed report closes windows of ≥25 ms;
//     a window is clean iff it saw no fresh loss and no overuse
//     verdict. Absence of feedback re-freezes via the silence detector
//     regardless — this only judges evidence that returned.
//   • IDR PACING NUMBERS — the machine names the policy (W4b), this
//     owns the numbers: lastGoodRate = min(btlRate, rate last seen
//     healthy); halfStaleEstimate = max(floor, 0.5 × the stale
//     delivery estimate) (resiliency §4 — the old estimate may be 10×
//     the new path). And the HS-6 ceiling math at the LIVE rate:
//     frameByteCeiling = R×B/8 − higherClassBytes(B),
//     B = min(2/fps, 25 ms).
//   • FEC REGIME (HS-17) — the §5.2 ladder's column choice, stepped
//     with the loss regime: clean → lossy when post-FEC loss crosses
//     the rung-3 threshold (fires with the downshift, latched — the
//     step is a geometry promise, not a rate move, so the 500 ms
//     limiter does not gate it); lossy → clean when post-FEC loss has
//     sat below the clean column's own definition (< 0.5%) for the
//     step-down hold. The hold length is host policy where the pillar
//     says only "sustained": long enough that one quiet second cannot
//     flap the ladder. The session applies each step to VideoChannel's
//     packetizing seam — per-frame, next frame onward.
//   • SRTT — beacon-echo RTTs fold into an RFC 6298-shaped EWMA
//     (gain 1/8): the retransmit gate's SRTT term (resiliency §1.1
//     rule 3). min-RTT stays alongside for telemetry.

import LyteWire

public struct RateEstimatorConfig: Sendable {
    /// The negotiated session ceiling, bits/s (the W7-era session rate;
    /// no capability key carries bitrate in v1).
    public var ceilingBitsPerSecond: Int
    /// Resiliency §2.2: 500 kbps — enough for a paced IDR within 2 s.
    public var floorBitsPerSecond: Int
    /// Where the standing rate starts. Nil = the ceiling (the honest
    /// pre-evidence default the pacer has always used).
    public var initialRateBitsPerSecond: Int?
    /// Delivery-rate samples (and delay baselines) older than this fall
    /// out of their windows (~10 s, resiliency §2.2).
    public var sampleWindowNS: UInt64
    /// Send-spacing gap that splits dispersion samples into trains —
    /// the MINIMUM: the effective gap scales with the standing rate
    /// (3 × one datagram's wire time), because at low rates the pacer
    /// itself spaces datagrams beyond any fixed gap and a fixed split
    /// would starve the estimator of delivery samples exactly when it
    /// needs evidence to climb (the floor-deadlock the live gate
    /// caught: paced 18 ms apart at 500 kbps, no train ever formed,
    /// no upshift ever fired).
    public var trainGapNS: UInt64
    /// Trains below this packet count are weighted ×0.5 in the max
    /// filter (short-train dispersion noise, resiliency §2.2).
    public var minTrainPackets: Int
    /// How many of the most recent RAW delivery samples the overuse
    /// fall takes its anchor median over (HS-21). Odd is preferable
    /// (a clean middle). The default 3 is deliberate: overuse fires
    /// on `overuseConsecutiveReports` (2) consecutive inflated reports,
    /// so by fire time TWO recent samples already reflect a genuine
    /// sustained drop and dominate a 3-median — the fall lands on
    /// measured delivery exactly as the one-deep anchor did — while a
    /// lone garbage sample stays outvoted 2-to-1 and cannot move it.
    public var overuseAnchorSampleCount: Int
    /// Queuing-delay inflation that reads as overuse, µs.
    public var overuseThresholdMicroseconds: Int64
    /// Consecutive inflated reports before the overuse verdict fires.
    public var overuseConsecutiveReports: Int
    /// HS-22c: an overuse anchor within this fraction of the standing
    /// rate (or above it) is a measurement of our own pacing while the
    /// pacer holds standing backlog — it may hold the rate, never
    /// anchor a fall (see the header's self-reference gate).
    public var selfReferenceBandFraction: Double
    /// HS-22c: "standing backlog" = at least this much wire time of
    /// queued bytes at the standing rate (5 ms — more than mid-batch
    /// residue, far less than one squeezed IDR's drain).
    public var selfReferenceBacklogWindowNS: UInt64
    /// HS-23: the largest closed-hole cycle the stall gate forgives —
    /// an inflation streak whose PEAK exceeds this is sustained
    /// degradation and falls as ever (the Wi-Fi study's dwells run
    /// 70–100 ms; a real outage runs past 150 and into the freeze
    /// machinery anyway).
    public var stallGapCeilingMicroseconds: Int64
    /// HS-23: the drain evidence bar — a fresh full train must measure
    /// at least this multiple of the standing rate to prove packets
    /// accumulated and were released (1.25: comfortably above
    /// pacing-measurement noise, far below any real AP drain).
    public var stallBurstRateFactor: Double
    /// HS-23: how fresh the drain evidence must be at fall time.
    public var stallEvidenceWindowNS: UInt64
    /// HS-28 (invariant 1): a full train measuring at or above
    /// (1 − this fraction) × the pacer rate recorded at its release is
    /// CENSORED — it measures our own pacing and can only prove
    /// capacity ≥ that rate. It may raise the belief, never lower it,
    /// and never votes in a fall anchor. 0.2: comfortably past
    /// dispersion noise, tight enough that a genuinely stretched train
    /// (a real bottleneck under the pace) still testifies.
    public var censoredSampleMarginFraction: Double
    /// HS-28 (invariant 2): how long overuse pressure must persist
    /// before an uncorroborated fall may execute once the shape-gates
    /// retire — one full 500 ms fall-limiter window into the next, so
    /// the evidence spans ≥2 consecutive windows. A dwell (≤150 ms by
    /// the stall ceiling's own definition) structurally cannot sustain
    /// it; a genuine squeeze does, within ~1 s of onset.
    public var beliefDemotionSustainNS: UInt64
    /// HS-28: honest (path-limited) anchor votes older than this no
    /// longer speak for the path — a stale low reading from a healed
    /// dip must not demote the belief later.
    public var honestVoteWindowNS: UInt64
    /// Pre-FEC loss fraction below which the window reads clean (the
    /// rate may rise). GCC's lower band.
    public var lossCleanThreshold: Double
    /// Pre-FEC loss fraction above which the rate falls ×(1 − loss/2).
    /// Between the two thresholds the rate HOLDS — that band is FEC's
    /// to absorb (see the header).
    public var lossDownshiftThreshold: Double
    /// The loss accounting window (1 s, resiliency §2.2).
    public var lossWindowNS: UInt64
    /// Post-FEC loss fraction (NACKed shards / video datagrams
    /// attempted, rolling `lossWindowNS`) above which rung 3 fires:
    /// downshift + FEC regime step up (resiliency §4 rung 3's "> 2%
    /// over 1 s").
    public var postFecDownshiftThreshold: Double
    /// Post-FEC loss below which the window reads clean for the regime
    /// ladder (the §5.2 clean column's own "< 0.5%" definition).
    public var postFecCleanThreshold: Double
    /// How long post-FEC loss must sit below `postFecCleanThreshold`
    /// before the regime steps back down to clean. Host policy where
    /// the pillar says only "sustained".
    public var regimeStepDownHoldNS: UInt64
    /// Multiplicative downshift factor and its rate limit.
    public var downshiftFactor: Double
    public var downshiftMinIntervalNS: UInt64
    /// Upshift budget per second toward the ceiling (≤10%/s).
    public var upshiftPerSecond: Double
    /// No upshift this long after a downshift (queue drain time).
    public var upshiftHoldAfterDownshiftNS: UInt64
    /// Delivery evidence must be at most this old for the rate to rise
    /// ("rises on evidence").
    public var upshiftEvidenceWindowNS: UInt64
    /// The RECOVERY verdict window (W4b's 25 ms feedback window).
    public var recoveryWindowNS: UInt64
    /// Send-ledger capacity (datagrams). 8192 covers >600 ms at the
    /// 20 Mbps shard rate — far beyond any 25–50 ms report cadence.
    public var sendLedgerCapacity: Int
    /// The higher-class byte reserves the frameByteCeiling subtracts:
    /// audio's wire rate (131 B datagrams × 300/s ≈ 315 kbps at the
    /// HS-15 defaults) and the control reserve (resiliency §2.4).
    public var audioReserveBitsPerSecond: Int
    public var controlReserveBitsPerSecond: Int

    public init(
        ceilingBitsPerSecond: Int,
        floorBitsPerSecond: Int = 500_000,
        initialRateBitsPerSecond: Int? = nil,
        sampleWindowNS: UInt64 = 10_000_000_000,
        trainGapNS: UInt64 = 2_000_000,
        minTrainPackets: Int = 8,
        overuseAnchorSampleCount: Int = 3,
        overuseThresholdMicroseconds: Int64 = 15_000,
        overuseConsecutiveReports: Int = 2,
        selfReferenceBandFraction: Double = 0.15,
        selfReferenceBacklogWindowNS: UInt64 = 5_000_000,
        stallGapCeilingMicroseconds: Int64 = 150_000,
        stallBurstRateFactor: Double = 1.25,
        stallEvidenceWindowNS: UInt64 = 500_000_000,
        censoredSampleMarginFraction: Double = 0.2,
        beliefDemotionSustainNS: UInt64 = 500_000_000,
        honestVoteWindowNS: UInt64 = 2_000_000_000,
        lossCleanThreshold: Double = 0.02,
        lossDownshiftThreshold: Double = 0.10,
        lossWindowNS: UInt64 = 1_000_000_000,
        postFecDownshiftThreshold: Double = 0.02,
        postFecCleanThreshold: Double = 0.005,
        regimeStepDownHoldNS: UInt64 = 5_000_000_000,
        downshiftFactor: Double = 0.85,
        downshiftMinIntervalNS: UInt64 = 500_000_000,
        upshiftPerSecond: Double = 0.10,
        upshiftHoldAfterDownshiftNS: UInt64 = 1_000_000_000,
        upshiftEvidenceWindowNS: UInt64 = 2_000_000_000,
        recoveryWindowNS: UInt64 = 25_000_000,
        sendLedgerCapacity: Int = 8_192,
        audioReserveBitsPerSecond: Int = 320_000,
        controlReserveBitsPerSecond: Int = 500_000
    ) {
        precondition(ceilingBitsPerSecond > 0)
        precondition(floorBitsPerSecond > 0)
        self.ceilingBitsPerSecond = ceilingBitsPerSecond
        self.floorBitsPerSecond = min(floorBitsPerSecond, ceilingBitsPerSecond)
        self.initialRateBitsPerSecond = initialRateBitsPerSecond
        self.sampleWindowNS = sampleWindowNS
        self.trainGapNS = trainGapNS
        self.minTrainPackets = minTrainPackets
        self.overuseAnchorSampleCount = max(overuseAnchorSampleCount, 1)
        self.overuseThresholdMicroseconds = overuseThresholdMicroseconds
        self.overuseConsecutiveReports = max(overuseConsecutiveReports, 1)
        self.selfReferenceBandFraction = selfReferenceBandFraction
        self.selfReferenceBacklogWindowNS = selfReferenceBacklogWindowNS
        self.stallGapCeilingMicroseconds = stallGapCeilingMicroseconds
        self.stallBurstRateFactor = stallBurstRateFactor
        self.stallEvidenceWindowNS = stallEvidenceWindowNS
        self.censoredSampleMarginFraction = censoredSampleMarginFraction
        self.beliefDemotionSustainNS = beliefDemotionSustainNS
        self.honestVoteWindowNS = honestVoteWindowNS
        self.lossCleanThreshold = lossCleanThreshold
        self.lossDownshiftThreshold = max(
            lossDownshiftThreshold, lossCleanThreshold
        )
        self.lossWindowNS = lossWindowNS
        self.postFecDownshiftThreshold = postFecDownshiftThreshold
        self.postFecCleanThreshold = min(
            postFecCleanThreshold, postFecDownshiftThreshold
        )
        self.regimeStepDownHoldNS = regimeStepDownHoldNS
        self.downshiftFactor = downshiftFactor
        self.downshiftMinIntervalNS = downshiftMinIntervalNS
        self.upshiftPerSecond = upshiftPerSecond
        self.upshiftHoldAfterDownshiftNS = upshiftHoldAfterDownshiftNS
        self.upshiftEvidenceWindowNS = upshiftEvidenceWindowNS
        self.recoveryWindowNS = recoveryWindowNS
        self.sendLedgerCapacity = max(sendLedgerCapacity, 64)
        self.audioReserveBitsPerSecond = audioReserveBitsPerSecond
        self.controlReserveBitsPerSecond = controlReserveBitsPerSecond
    }
}

/// What one ingested report did to the estimate — the session applies
/// `newRate` to the pacer and feeds each verdict to the machine.
public struct RateEstimatorVerdict: Equatable, Sendable {
    /// Which control-law branch moved the rate.
    public enum Change: Equatable, Sendable {
        case overuse
        case loss
        /// NACK-evidenced loss FEC could not absorb (rung 3, HS-17).
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
    /// Set when this report stepped the FEC regime (HS-17); the session
    /// applies it to VideoChannel's packetizing seam.
    public var fecRegime: FecRegime?
}

/// Running evidence counters, exposed for logs and the live gate.
public struct RateEstimatorStats: Equatable, Sendable {
    public var reportsIngested = 0
    public var dispersionSamplesMatched = 0
    public var dispersionSamplesUnmatched = 0
    public var deliverySamples = 0
    public var downshifts = 0
    public var upshifts = 0
    public var overuseVerdicts = 0
    /// HS-22c: overuse falls the self-reference gate refused — the
    /// evidence measured our own pacing and nothing corroborated a
    /// real path problem (rate held, rises stayed blocked).
    public var selfReferenceHolds = 0
    /// Overuse falls withheld while fresh super-rate drain evidence
    /// stood inside a bounded hole — the receiver's radio blinked, the
    /// path did not slow (HS-23's stall gate, retired at HS-28: the
    /// persistence machinery decides, this book keeps the vocabulary).
    public var stallHolds = 0
    /// Overuse falls withheld awaiting invariant 2's persistence
    /// (HS-28; the ramp hunt's dwell deferral, retired and
    /// generalized): no instant corroboration yet, and the pressure
    /// streak has not persisted a full fall-limiter window — the
    /// report that finally acts still finds the limiter unconsumed.
    public var fallDeferrals = 0
    public var lossDownshifts = 0
    /// HS-28 (invariant 1): full-train samples classified CENSORED at
    /// production — they measured our own recorded pace, raised the
    /// belief when above it, and got no fall-anchor vote.
    public var censoredSamples = 0
    /// HS-28: full-train samples classified HONEST (path-limited) —
    /// the path measurably stretched them; they vote.
    public var honestSamples = 0
    /// HS-28: times any sample raised the capacity belief.
    public var beliefRaises = 0
    /// HS-28 (invariant 2): times an executing fall demoted the belief
    /// to the fresh honest median.
    public var beliefDemotions = 0
    /// HS-28: NACK shards recused as self-inflicted (their frame's
    /// shards were still queued in our own pacer — the client's
    /// completion presumption expired mid-drain).
    public var nackShardsRecused = 0
    /// Rung-3 downshifts (post-FEC loss over threshold, HS-17).
    public var postFecDownshifts = 0
    /// Distinct (frame, shard) pairs the NACK sections named.
    public var nackShardsCounted = 0
    /// FEC regime steps, both directions.
    public var regimeSteps = 0

    public init() {}
}

/// The evidence on the table the moment an overuse FALL fired (holds
/// are counted, not recorded — they changed nothing). The ramp hunt's
/// forensics: enough to say, post-mortem, why neither the
/// self-reference gate nor the stall gate held this particular fall.
public struct OveruseFallForensics: Equatable, Sendable {
    /// The anchor the fall multiplied (median of raw full-train samples).
    public var anchorBitsPerSecond: Int
    /// The standing rate the instant before the fall.
    public var rateBeforeBitsPerSecond: Int
    /// Worst inflation anywhere in the streak, µs (the stall gate's
    /// hole bound — above `stallGapCeilingMicroseconds` the gate is out).
    public var streakPeakMicroseconds: Int64?
    /// Queuing delay at the streak's opening report, µs.
    public var streakStartMicroseconds: Int64?
    /// Queuing delay on THIS report, µs.
    public var queuingDelayMicroseconds: Int64?
    /// Pacer backlog at fall time (the self-reference gate's floor input).
    public var pacerBacklogBytes: Int
    /// The freshest full-train drain: its rate and how stale it was —
    /// the stall gate's super-rate-drain evidence (or its absence).
    public var lastFullTrainBitsPerSecond: Int?
    public var lastFullTrainAgeNS: UInt64?
    /// Loss posture on this report.
    public var lossFraction: Double
    public var postFecLossFraction: Double
    /// HS-28: the capacity belief the moment the fall fired, and the
    /// fresh honest-vote median (nil = no honest evidence — the fall
    /// was bounded multiplicative, never trickle-anchored).
    public var capacityBeliefBitsPerSecond: Int?
    public var honestAnchorBitsPerSecond: Int?
    /// HS-28: how long the overuse pressure had persisted at fall
    /// time (the invariant-2 persistence clock).
    public var streakAgeNS: UInt64?
}

public final class RateEstimator {
    public let config: RateEstimatorConfig
    public private(set) var stats = RateEstimatorStats()

    /// The last overuse fall's forensics (nil until one fires) — read
    /// by the session logs when a `.overuse` change surfaces.
    public private(set) var lastOveruseFall: OveruseFallForensics?

    /// The standing pace, bits/s — what the pacer should run at.
    public private(set) var rateBitsPerSecond: Int

    /// The windowed-max delivery-rate estimate (nil before evidence).
    public var deliveryRateBitsPerSecond: Int? {
        deliveryWindow.map { Int($0.rate) }.max()
    }

    /// The reporting-grade measured delivery: the median of the last
    /// few FULL-train raw samples — the same evidence the overuse
    /// anchor trusts (HS-21). Deliberately distinct from
    /// `deliveryRateBitsPerSecond`: that one is the control law's
    /// windowed-MAX bottleneck probe (BBR's shape), and a receiver
    /// radio that drains a queued dwell in one compressed burst hands
    /// the max a legitimate super-rate sample — the quality probe's
    /// receipts printed 272–777 Mbps "delivery" on a ~90 Mbps wire
    /// (Q-1). The median outvotes the lone burst; summaries print THIS.
    public var measuredDeliveryRateBitsPerSecond: Int? {
        overuseAnchorRate.map { Int($0) }
    }

    /// HS-28: the capacity belief, bits/s — what the estimator honestly
    /// believes the path can carry. Nil before any full-train evidence.
    public var capacityBeliefBitsPerSecond: Int? {
        beliefBits.map(Int.init)
    }

    /// The current queuing-delay inflation estimate, µs (nil before
    /// two reports establish a baseline).
    public private(set) var queuingDelayMicroseconds: Int64?

    /// min-RTT evidence from beacon echoes — recorded for telemetry
    /// and the HS-17 retransmit gate; the rate law runs on the
    /// dispersion sensor.
    public private(set) var minRttMicroseconds: Int64?

    /// RFC 6298-shaped smoothed RTT from beacon echoes — the SRTT term
    /// of resiliency §1.1 rule 3's retransmit gate. Nil before the
    /// first echo (the gate treats no-evidence as gate-fails-open to
    /// stale: with no RTT the host cannot promise the repair lands in
    /// budget — see Session's NACK consumption).
    public private(set) var srttMicroseconds: Int64?

    /// The §5.2 ladder column currently in force (HS-17's regime
    /// latch). Moves only through `ingest`'s verdicts.
    public private(set) var fecRegime: FecRegime = .clean

    // MARK: Send ledger

    private struct SendRecord {
        var key: UInt32
        var sendNS: UInt64
        var bytes: Int
        /// HS-28 (invariant 1): the pacer's standing rate the instant
        /// this datagram was RELEASED — the mark that lets sample
        /// production decide, mechanically, whether a train measured
        /// the path or measured us.
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
    /// The freshest raw (unweighted) delivery measurement — the stale
    /// estimate for RECOVERY's halfStaleEstimate pacing.
    private var lastDeliveryRate: Double?
    private var lastDeliveryAt: UInt64?
    /// The last `overuseAnchorSampleCount` raw (unweighted) delivery
    /// measurements, FIFO — the overuse fall's anchor takes their
    /// median so a lone garbage short-train sample cannot crater the
    /// rate (HS-21). Raw, deliberately: this is the same measurement
    /// `lastDeliveryRate` records, kept over a short window instead of
    /// one-deep. Since HS-28 this median is REPORTING-grade and gate
    /// input only — the fall anchor answers to the capacity belief.
    private var recentRawDeliveries: [Double] = []

    // MARK: HS-28 — the capacity belief

    /// The one-number capacity belief (header: THE CAPACITY BELIEF).
    /// Raised instantly by any full-train sample above it; falls only
    /// by invariant-2 demotion at an executing fall — never by aging.
    private var beliefBits: Double?
    /// Fresh HONEST (path-limited) full-train votes: the only samples
    /// that may pull a fall anchor below the belief (invariant 1).
    /// FIFO of `overuseAnchorSampleCount`, additionally expired past
    /// `honestVoteWindowNS`.
    private var recentHonestDeliveries: [(at: UInt64, rate: Double)] = []
    /// When the CURRENT overuse-pressure streak opened — invariant 2's
    /// persistence clock. Resets with the streak.
    private var inflatedStreakSinceNS: UInt64?

    private struct DelaySample {
        var at: UInt64
        var minDelayMicros: Int64
    }
    /// Per-channel rolling baselines (see the header: a clean audio
    /// lane must not mask a growing video queue).
    private var delayBaselineWindows: [UInt8: [DelaySample]] = [:]
    private var consecutiveInflatedReports = 0
    /// The worst inflation of the CURRENT inflated streak's opening
    /// report — the self-reference gate's queue-growth baseline
    /// (HS-22c): a real standing queue grows past it, a self-caused
    /// burst bump drains and resets the streak.
    private var inflatedStreakStartMicros: Int64?
    /// The worst inflation seen ANYWHERE in the current streak — the
    /// stall gate's hole-length reading (HS-23): packets held through
    /// a dwell carry its length as delay, so the streak peak bounds
    /// the hole. Resets with the streak.
    private var inflatedStreakPeakMicros: Int64?
    /// The freshest FULL (≥ minTrainPackets) train's raw measurement —
    /// the stall gate's drain evidence (HS-23). Short trains stay
    /// excluded exactly as they are from the anchor votes: Wi-Fi
    /// aggregation compresses small groups innocently.
    private var lastFullTrainRate: Double?
    private var lastFullTrainAt: UInt64?
    // The dwell deferral's `fallDeferredSince` lived here from the
    // ramp hunt until HS-28 retired it: invariant 2's persistence
    // (`inflatedStreakSinceNS` against `beliefDemotionSustainNS`)
    // subsumes the deferral with no shape analysis at all — a dwell
    // cannot sustain pressure across a full fall-limiter window, so
    // the drain always arrives inside the persistence span.

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

    // MARK: Post-FEC (NACK) state — HS-17

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
    /// The rate last in force while the path read healthy — WAKE's
    /// min(btlRate, lastGoodRate) anchor (overview conflict 14).
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
            repeating: nil, count: config.sendLedgerCapacity
        )
    }

    // MARK: - Send side

    /// Records one outbound datagram at the instant the pacer released
    /// it. `channel` is the envelope channel the client's dispersion
    /// samples will name; `bytes` is the wire size (delivery rate is
    /// measured in wire bytes, the unit the bottleneck queues in).
    public func noteSent(
        channel: ChannelId, seq: ChannelSeq, bytes: Int, now: UInt64
    ) {
        let key = UInt32(channel.rawValue) << 16 | UInt32(seq.rawValue)
        if let evicted = ledger[ledgerHead], ledgerIndex[evicted.key] == ledgerHead {
            ledgerIndex.removeValue(forKey: evicted.key)
        }
        ledger[ledgerHead] = SendRecord(
            key: key, sendNS: now, bytes: bytes,
            paceBitsPerSecond: rateBitsPerSecond
        )
        ledgerIndex[key] = ledgerHead
        ledgerHead = (ledgerHead + 1) % ledger.count
    }

    /// One beacon-echo RTT sample: min-gated for telemetry, EWMA'd
    /// (RFC 6298's 1/8 gain) into the retransmit gate's SRTT.
    public func noteRtt(microseconds: Int64) {
        if minRttMicroseconds.map({ microseconds < $0 }) ?? true {
            minRttMicroseconds = microseconds
        }
        srttMicroseconds = srttMicroseconds.map {
            $0 + (microseconds - $0) / 8
        } ?? microseconds
    }

    // MARK: - Feedback side

    /// Consumes one parsed chan-3 report. `inRecovery` gates the W4b
    /// window verdicts (the machine's state is the session's to know).
    /// `pacerBacklogBytes` is the caller's live video-class backlog —
    /// the self-reference gate's "are we the bottleneck right now"
    /// evidence (HS-22c); 0 (the default) means no standing backlog
    /// and the gate never engages. `recusedNackFrames` (HS-28) names
    /// frames whose shards are still queued in the caller's own pacer:
    /// NACKs against them are the client's completion presumption
    /// expiring mid-drain — self-inflicted, not path evidence — and
    /// feed neither the post-FEC fractions nor the regime ladder.
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

        let lossFraction = currentLossFraction()
        let postFecLossFraction = currentPostFecLossFraction()
        let overuse = inflated
            && consecutiveInflatedReports >= config.overuseConsecutiveReports
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

    // MARK: - The machine's numbers

    /// The rate a machine-demanded IDR must be paced at (W4b names the
    /// policy, this owns the numbers). Applying it also MOVES the
    /// standing rate there — the pacing decision is the estimate now.
    public func applyIdrPacing(_ pacing: IdrPacing, now: UInt64) -> Int {
        let rate: Int
        switch pacing {
        case .lastGoodRate:
            // WAKE from healthy IDLE: min(btlRate, lastGoodRate).
            let btl = deliveryRateBitsPerSecond ?? lastGoodRate
            rate = clamp(min(btl, lastGoodRate))
        case .halfStaleEstimate:
            // RECOVERY: the path is unknown; the stale estimate may be
            // 10× the new path's capacity (resiliency §4).
            let stale = deliveryRateBitsPerSecond
                ?? lastDeliveryRate.map(Int.init)
                ?? rateBitsPerSecond
            rate = clamp(stale / 2)
        }
        rateBitsPerSecond = rate
        lastAdjustAt = now
        return rate
    }

    /// The HS-6 burst-budget window B = min(2/fps, 25 ms), in ns — one
    /// definition shared by the ceiling math below and HS-20's
    /// EncoderVbvPolicy (which inverts it: ceiling / B back to a rate).
    public static func frameBudgetNS(fps: Int) -> UInt64 {
        min(UInt64(2_000_000_000) / UInt64(max(fps, 1)), 25_000_000)
    }

    /// The HS-6 frame ceiling at the LIVE estimate: R×B/8 −
    /// higherClassBytes(B), B = min(2/fps, 25 ms). Never below one
    /// shard — a ceiling of zero would forbid streaming entirely, and
    /// the floor rate exists precisely so a paced IDR stays possible.
    public func frameByteCeiling(fps: Int) -> Int {
        let budgetNS = Self.frameBudgetNS(fps: fps)
        let budgetSeconds = Double(budgetNS) / 1e9
        let gross = Double(rateBitsPerSecond) * budgetSeconds / 8
        let reserves = Double(
            config.audioReserveBitsPerSecond
                + config.controlReserveBitsPerSecond
        ) * budgetSeconds / 8
        return max(Int(gross - reserves), WireBudget.maxDatagramByteCount)
    }

    // MARK: - Internals

    private func clamp(_ rate: Int) -> Int {
        min(max(rate, config.floorBitsPerSecond), config.ceilingBitsPerSecond)
    }

    /// The overuse fall's anchor (HS-21): the median of the last few
    /// raw delivery samples. Median, not max: a max would ignore a lone
    /// LOW garbage sample but blunt a GENUINE sustained drop (the still
    /// higher pre-drop samples would win the window until they age out);
    /// a median rejects a lone outlier in either direction yet follows
    /// the bulk the moment the majority of the window reflects the new
    /// path. Nil before any delivery evidence (the caller falls back to
    /// the standing rate then, as before).
    private var overuseAnchorRate: Double? {
        guard !recentRawDeliveries.isEmpty else { return nil }
        let sorted = recentRawDeliveries.sorted()
        return sorted[sorted.count / 2]
    }

    /// HS-28: the median of the FRESH honest (path-limited) votes —
    /// the only evidence allowed to pull a fall anchor below the
    /// capacity belief (invariant 1: censored samples never vote).
    /// Nil when nothing fresh and honest exists — the fall is then
    /// bounded multiplicative, never trickle-anchored.
    private var honestAnchorRate: Double? {
        guard !recentHonestDeliveries.isEmpty else { return nil }
        let sorted = recentHonestDeliveries.map(\.rate).sorted()
        return sorted[sorted.count / 2]
    }

    private func expireWindows(now: UInt64) {
        deliveryWindow.removeAll {
            now &- $0.at > config.sampleWindowNS
        }
        for channel in delayBaselineWindows.keys {
            delayBaselineWindows[channel]!.removeAll {
                now &- $0.at > config.sampleWindowNS
            }
        }
        lossWindow.removeAll {
            now &- $0.at > config.lossWindowNS
        }
        postFecWindow.removeAll {
            now &- $0.at > config.lossWindowNS
        }
        recentNackShards = recentNackShards.filter {
            now &- $0.value <= config.lossWindowNS
        }
        recentHonestDeliveries.removeAll {
            now &- $0.at > config.honestVoteWindowNS
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
                newMissing += Int(dMissing)
                newReceived += Int(dReceived)
                if stats.channel == .videoActive {
                    videoAttempted += Int(dMissing) + Int(dReceived)
                }
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

    /// Counts the report's NACK section into the post-FEC window:
    /// distinct (frame, shard) pairs, deduped across reports inside the
    /// window (a re-NACK is the client insisting, not new loss).
    /// Frames in `recusedFrames` contribute nothing (HS-28): their
    /// shards are still queued in our own pacer, so the NACK measures
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
    /// NACKs with no attempt evidence yet still read as full loss —
    /// the fraction saturates at 1 rather than dividing by zero.
    private func currentPostFecLossFraction() -> Double {
        let nacked = postFecWindow.reduce(0) { $0 + $1.shardCount }
        guard nacked > 0 else { return 0 }
        let attempted = lossWindow.reduce(0) { $0 + $1.videoAttempted }
        guard attempted > nacked else { return 1 }
        return Double(nacked) / Double(attempted)
    }

    private struct MatchedSample {
        var channel: UInt8
        var sendNS: UInt64
        var bytes: Int
        var arrivalMicros: UInt64
        /// The pacer rate recorded at this datagram's release (HS-28).
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
            stats.dispersionSamplesMatched += 1
            matched.append(MatchedSample(
                channel: sample.channel.rawValue,
                sendNS: record.sendNS,
                bytes: record.bytes,
                arrivalMicros: dispersion.base.microseconds
                    &+ UInt64(sample.arrivalDeltaMicroseconds),
                paceBitsPerSecond: record.paceBitsPerSecond
            ))
        }
        matched.sort { $0.sendNS < $1.sendNS }
        return matched
    }

    /// Segments matched samples into trains by send spacing and feeds
    /// each train's delivery-rate sample into the max window. The gap
    /// scales with the standing rate (see the config comment): a
    /// paced-at-R sender spaces datagrams ≈ their wire time at R, so
    /// consecutive sends must still read as one train at any rate.
    private func absorbDeliveryTrains(
        _ matched: [MatchedSample], now: UInt64
    ) {
        guard matched.count >= 2 else { return }
        let wirePerDatagramNS = UInt64(
            Double(1_152 * 8) / Double(rateBitsPerSecond) * 1e9
        )
        let gapNS = max(config.trainGapNS, 3 * wirePerDatagramNS)
        var trainStart = 0
        func closeTrain(_ range: Range<Int>) {
            let train = matched[range]
            guard train.count >= 3 else { return }
            let firstArrival = train.map(\.arrivalMicros).min()!
            let lastArrival = train.map(\.arrivalMicros).max()!
            guard lastArrival > firstArrival else { return }
            // Classic packet-train accounting: the first packet's bytes
            // opened the measurement window, everything behind it was
            // delivered inside it.
            let bytes = train.dropFirst().reduce(0) { $0 + $1.bytes }
            let spanSeconds = Double(lastArrival - firstArrival) / 1e6
            let rate = Double(bytes) * 8 / spanSeconds
            lastDeliveryRate = rate
            lastDeliveryAt = now
            // Only FULL trains may anchor an overuse fall (HS-22). The
            // HS-21 median outvotes ONE garbage sample, but the live
            // clean-path crater proved a majority of the short window
            // can be micro-trains that measure their own pacing, not
            // the path: audio's 4+2 groups arrive as 2–3-packet trains
            // reading ~1 Mbps (the audio class's self-paced rate), and
            // two of those in the last three samples anchored a fall
            // from 17,000 to 709 kbps on a path delivering 90 Mbps.
            // Short trains keep informing the windowed-max (×0.5,
            // below) and evidence freshness — they just get no vote on
            // where a fall lands.
            if train.count >= config.minTrainPackets {
                recentRawDeliveries.append(rate)
                if recentRawDeliveries.count > config.overuseAnchorSampleCount {
                    recentRawDeliveries.removeFirst()
                }
                // The stall gate's drain evidence (HS-23): the
                // freshest full-train reading, not a window max — a
                // squeeze that begins right after a genuine drain
                // must not inherit the drain's super-rate sample.
                lastFullTrainRate = rate
                lastFullTrainAt = now
                // HS-28 invariant 1, at sample production: was the
                // pacer the constraint? The ledger's recorded pace at
                // the train's send window answers mechanically. The
                // pace across a train is taken at its MAX — a train
                // straddling a rate move is judged against the faster
                // pace, the conservative side (fewer honest votes).
                let pace = Double(
                    train.map(\.paceBitsPerSecond).max() ?? rateBitsPerSecond
                )
                let honest = rate
                    < pace * (1 - config.censoredSampleMarginFraction)
                if honest {
                    // The path measurably stretched this train — it
                    // speaks for the path and may vote in a fall
                    // anchor (and, at an executing fall, demote the
                    // belief to what the path really carries).
                    stats.honestSamples += 1
                    recentHonestDeliveries.append((at: now, rate: rate))
                    if recentHonestDeliveries.count
                        > config.overuseAnchorSampleCount {
                        recentHonestDeliveries.removeFirst()
                    }
                } else {
                    // Censored (≈ our pace) or compressed (a drain):
                    // either way it can only prove capacity ≥ itself.
                    stats.censoredSamples += 1
                }
                // Delivery above the belief is always honest news —
                // censored samples may RAISE it, never lower it.
                if beliefBits.map({ rate > $0 }) ?? true {
                    beliefBits = rate
                    stats.beliefRaises += 1
                }
            }
            stats.deliverySamples += 1
            let weighted = train.count >= config.minTrainPackets
                ? rate : rate * 0.5
            deliveryWindow.append(DeliverySample(at: now, rate: weighted))
        }
        for i in 1..<matched.count {
            if matched[i].sendNS &- matched[i - 1].sendNS > gapNS {
                closeTrain(trainStart..<i)
                trainStart = i
            }
        }
        closeTrain(trainStart..<matched.count)
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
            let baseline = delayBaselineWindows[channel]?
                .map(\.minDelayMicros).min()
            delayBaselineWindows[channel, default: []].append(
                DelaySample(at: now, minDelayMicros: reportMin)
            )
            guard let baseline else { continue }
            haveBaseline = true
            let inflation = reportMin - min(baseline, reportMin)
            worstInflation = max(worstInflation, inflation)
        }
        guard haveBaseline else {
            queuingDelayMicroseconds = 0
            consecutiveInflatedReports = 0
            inflatedStreakSinceNS = nil
            return false
        }
        queuingDelayMicroseconds = worstInflation
        if worstInflation > config.overuseThresholdMicroseconds {
            if consecutiveInflatedReports == 0 {
                inflatedStreakStartMicros = worstInflation
                inflatedStreakPeakMicros = worstInflation
                inflatedStreakSinceNS = now
            } else {
                inflatedStreakPeakMicros = max(
                    inflatedStreakPeakMicros ?? worstInflation,
                    worstInflation
                )
            }
            consecutiveInflatedReports += 1
            return true
        }
        consecutiveInflatedReports = 0
        inflatedStreakStartMicros = nil
        inflatedStreakPeakMicros = nil
        inflatedStreakSinceNS = nil
        return false
    }

    private func applyControlLaw(
        overuse: Bool,
        lossFraction: Double,
        postFecLossFraction: Double,
        pacerBacklogBytes: Int,
        now: UInt64
    ) -> RateEstimatorVerdict.Change? {
        let downshiftAllowed = lastDownshiftAt.map {
            now &- $0 >= config.downshiftMinIntervalNS
        } ?? true

        if overuse, downshiftAllowed {
            // Fall to 0.85 × what the path measurably delivered — the
            // GCC overuse response, anchored to evidence, never to the
            // configured rate alone. The anchor is the MEDIAN of the
            // recent raw samples (HS-21), not the single freshest: one
            // garbage short-train sample must not decide the fall.
            let anchor = overuseAnchorRate.map(Int.init) ?? rateBitsPerSecond

            // THE SELF-REFERENCE GATE (HS-22c, header): with standing
            // backlog, an anchor at ≈ (or above) the standing rate
            // measured OUR OWN pacing — it may hold the rate, never
            // anchor a fall, unless something a self-limited pacer
            // cannot produce corroborates a real path problem: loss,
            // post-FEC evidence, or queue growth across the streak.
            let backlogFloorBytes = max(1, Int(
                Double(rateBitsPerSecond)
                    * Double(config.selfReferenceBacklogWindowNS) / 8e9
            ))
            let selfReferential = pacerBacklogBytes >= backlogFloorBytes
                && Double(anchor) >= Double(rateBitsPerSecond)
                    * (1 - config.selfReferenceBandFraction)
            let queueGrew = inflatedStreakStartMicros.map {
                (queuingDelayMicroseconds ?? 0)
                    >= $0 + config.overuseThresholdMicroseconds
            } ?? false
            let corroborated = lossFraction >= config.lossCleanThreshold
                || postFecLossFraction > 0
                || queueGrew
            if selfReferential, !corroborated {
                stats.selfReferenceHolds += 1
                // Held, not fallen: the overuse verdict still blocks
                // every rise below, and the fall limiter stays free so
                // corroboration on the very next report may act.
            } else if lossFraction < config.lossCleanThreshold,
                      postFecLossFraction < config.postFecCleanThreshold,
                      now &- (inflatedStreakSinceNS ?? now)
                          < config.beliefDemotionSustainNS {
                // INVARIANT 2's PERSISTENCE (HS-28): an overuse fall
                // with no instant corroboration (no loss the clean
                // band would flag, no post-FEC evidence past the
                // clean column) waits until the pressure streak has
                // persisted a full fall-limiter window into the next
                // (`beliefDemotionSustainNS`). This subsumed BOTH the
                // dwell deferral and HS-23's stall gate: a scan-dwell
                // cycle — a bounded hole that closes with a
                // compressed drain — structurally cannot sustain
                // pressure across the span (the drain report clears
                // the streak and RAISES the belief), while a genuine
                // squeeze sails through and falls within ~1 s, at
                // most one limiter beat later than the old law. The
                // overuse verdict still blocks every rise below, and
                // the fall limiter stays unconsumed for the report
                // that finally acts. The books keep the old gates'
                // vocabulary: a withheld beat with fresh super-rate
                // drain evidence inside a bounded hole is a stall
                // hold; the rest are deferrals.
                let holePeak = inflatedStreakPeakMicros ?? Int64.max
                let drainFresh = lastFullTrainAt.map {
                    now &- $0 <= config.stallEvidenceWindowNS
                } ?? false
                let drainOutranPace = drainFresh
                    && (lastFullTrainRate ?? 0)
                        >= Double(rateBitsPerSecond)
                        * config.stallBurstRateFactor
                if drainOutranPace,
                   holePeak <= config.stallGapCeilingMicroseconds {
                    stats.stallHolds += 1
                } else {
                    stats.fallDeferrals += 1
                }
            } else {
                // HS-28: the fall EXECUTES here — and the anchor
                // answers to the CAPACITY BELIEF, never to the median
                // of raw recent samples. Invariant 2's demotion rides
                // the fall: a fresh honest (path-limited) median below
                // the belief is evidence a censored sender cannot
                // manufacture, so the belief follows the path down and
                // the fall lands on measured delivery exactly as the
                // HS-21 pins demand. With NO honest evidence the fall
                // is bounded multiplicative (0.85 × standing rate per
                // limiter beat) — a censored trickle can no longer
                // crater the rate in one step (leg B's `full-train
                // 398 kbps 0 ms ago` seam, closed by construction).
                let honestMedian = honestAnchorRate
                let belief = beliefBits ?? Double(rateBitsPerSecond)
                let demoted: Double
                if let honestMedian, honestMedian < belief {
                    demoted = honestMedian
                    beliefBits = honestMedian
                    stats.beliefDemotions += 1
                } else {
                    demoted = belief
                }
                // The ramp hunt's forensics: record exactly what was
                // on the table when this fall fired — the evidence a
                // post-mortem needs to say why neither gate held it.
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
                rateBitsPerSecond = clamp(min(
                    Int(demoted * config.downshiftFactor),
                    Int(Double(rateBitsPerSecond) * config.downshiftFactor)
                ))
                lastDownshiftAt = now
                lastAdjustAt = now
                stats.downshifts += 1
                return .overuse
            }
        }

        if lossFraction > config.lossDownshiftThreshold, downshiftAllowed {
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

        if postFecLossFraction > config.postFecDownshiftThreshold,
           downshiftAllowed {
            // Rung 3: loss FEC could not absorb. NOT the 2–10% hold —
            // that band is held precisely because parity absorbs it,
            // and this evidence says it did not. Multiplicative fall,
            // same limiter; the regime step rides the same verdict.
            rateBitsPerSecond = clamp(Int(
                Double(rateBitsPerSecond) * config.downshiftFactor
            ))
            lastDownshiftAt = now
            lastAdjustAt = now
            stats.downshifts += 1
            stats.postFecDownshifts += 1
            return .postFecLoss
        }

        // Clean: the path is healthy at this rate.
        if !overuse, lossFraction < config.lossCleanThreshold,
           postFecLossFraction <= config.postFecCleanThreshold {
            lastGoodRate = rateBitsPerSecond
        }

        // Rise only on evidence: fresh delivery samples, loss below
        // the CLEAN band (2–10% holds — FEC's band), no active
        // hold-down, headroom to the ceiling.
        guard rateBitsPerSecond < config.ceilingBitsPerSecond,
              !overuse, lossFraction < config.lossCleanThreshold,
              postFecLossFraction <= config.postFecCleanThreshold,
              let deliveredAt = lastDeliveryAt,
              now &- deliveredAt <= config.upshiftEvidenceWindowNS,
              lastDownshiftAt.map({
                  now &- $0 >= config.upshiftHoldAfterDownshiftNS
              }) ?? true
        else {
            lastAdjustAt = now
            return nil
        }
        let elapsedSeconds = Double(now &- lastAdjustAt) / 1e9
        guard elapsedSeconds > 0 else { return nil }
        let factor = 1 + config.upshiftPerSecond * min(elapsedSeconds, 1)
        rateBitsPerSecond = clamp(
            Int(Double(rateBitsPerSecond) * factor)
        )
        lastAdjustAt = now
        stats.upshifts += 1
        return .evidence
    }

    /// The §5.2 regime ladder's step law (see the header). Returns the
    /// new regime when this ingest moved it; nil otherwise.
    private func stepRegime(
        postFecLossFraction: Double, sawNacks: Bool, now: UInt64
    ) -> FecRegime? {
        if sawNacks || postFecLossFraction >= config.postFecCleanThreshold {
            lastPostFecEvidenceAt = now
        }
        switch fecRegime {
        case .clean:
            guard postFecLossFraction > config.postFecDownshiftThreshold
            else { return nil }
            fecRegime = .lossy
            stats.regimeSteps += 1
            return .lossy
        case .lossy:
            // Step down only after a sustained stretch with no
            // post-FEC evidence — one quiet second cannot flap the
            // ladder, and every fresh NACK re-anchors the hold.
            guard let lastEvidence = lastPostFecEvidenceAt,
                  now &- lastEvidence >= config.regimeStepDownHoldNS,
                  postFecLossFraction < config.postFecCleanThreshold
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
        guard now &- start >= config.recoveryWindowNS else { return [] }
        let clean = !recoveryWindowSawLoss && !recoveryWindowSawOveruse
        recoveryWindowStartNS = now
        recoveryWindowSawLoss = false
        recoveryWindowSawOveruse = false
        return [clean]
    }
}
