// VideoBeatConductor — video's part under THE CONDUCTOR
// (docs/20260803-050422-metronome-playout-design.md), sans-IO.
//
// The six laws, as this instrument plays them:
//
//   cue   = score + path_delay_p99 + cushion × beat_period
//   beat  = every fresh frame presents ON the beat grid — its mapped
//           capture (the score) plus the cue, rounded to the nearest
//           beat. Rounding IS the half-beat bias: capture stamp
//           wobble under half a beat cannot move the presentation.
//   late  = a frame whose beat has already passed at arrival KEEPS
//           its beat (a PTS in the past): the renderer still decodes
//           it (the chain lives there) and simply never shows it.
//           Never rescheduled to arrival — nothing plays off-grid.
//   hole  = a blackout re-cues by WHOLE beats, once per episode:
//           the grid phase is preserved, the newest part lands on
//           the next beat, one scheduled hiccup instead of a smear.
//   slip  = when the measured path-delay tail proves a full beat of
//           surplus for a sustained window, the cue slips back one
//           beat — at most one per proof, phase preserved.
//   chain = retained refinements (same source capture re-encoded)
//           ride one microsecond behind their predecessor; stillness
//           has no cadence to violate, and the decoder always eats.
//
// The debt/flush machinery is recovery policy, not beat policy: a
// compressed catch-up train beyond the debt ceiling still flushes to
// await-IDR exactly as before (ported from the retired adaptive
// playout; its pins carried over).

public struct VideoBeatConductor: Sendable {
    public struct Config: Sendable, Equatable {
        /// The score's beat period. The rig's contract is 60 Hz end
        /// to end (see the Conductor doc); the value is config, not
        /// law, so a future score can retune it.
        public var beatPeriodMicroseconds: UInt64
        /// The automatic reserve floor. A hole adds whole beats; sustained
        /// clean proof returns them one at a time, never below this floor.
        public var cushionBeats: Int
        /// Hard safety ceiling on the automatic cue.
        public var maximumCueMicroseconds: UInt64
        /// Fresh frames of sustained surplus required before one slip.
        public var slipProofFrames: Int
        /// A compressed catch-up train beyond this is a blackout
        /// worth an IDR, not a playout problem.
        public var maximumFreshBurstDebtMicroseconds: UInt64
        /// Cadence-stable fresh frames before debt recovery re-arms.
        public var freshDebtRearmStableFrames: Int

        public init(
            beatPeriodMicroseconds: UInt64 = 16_667,
            cushionBeats: Int = 1,
            maximumCueMicroseconds: UInt64 = 150_000,
            slipProofFrames: Int = 600,
            maximumFreshBurstDebtMicroseconds: UInt64 = 200_000,
            freshDebtRearmStableFrames: Int = 30
        ) {
            self.beatPeriodMicroseconds = max(beatPeriodMicroseconds, 1_000)
            self.cushionBeats = max(cushionBeats, 1)
            self.maximumCueMicroseconds = max(
                maximumCueMicroseconds, self.beatPeriodMicroseconds)
            self.slipProofFrames = max(slipProofFrames, 1)
            self.maximumFreshBurstDebtMicroseconds =
                maximumFreshBurstDebtMicroseconds
            self.freshDebtRearmStableFrames = freshDebtRearmStableFrames
        }
    }

    public struct Decision: Sendable, Equatable {
        public var presentationMicroseconds: UInt64
        /// Total score-to-glass time in force for this part.
        public var cueMicroseconds: UInt64
        /// This part's measured mapped-capture-to-arrival path time.
        public var pathDelayMicroseconds: UInt64
        /// Cue remaining after the measured path time: the Conductor's
        /// actual timing reserve, including beat-grid alignment.
        public var reserveMicroseconds: UInt64
        /// How far past its beat the part arrived (0 = on time).
        public var latenessMicroseconds: UInt64
        public var shouldFlush: Bool
    }

    public private(set) var config: Config

    /// The grid: the last fresh part's on-beat presentation. Every
    /// move is a whole number of beats (ordinal step, re-cue, slip,
    /// ceiling cut), so the phase set at cue establishment survives
    /// every episode.
    private var gridPresentationMicroseconds: UInt64?
    /// The last fresh source capture, for the ordinal step.
    private var previousFreshSourceForStep: UInt64?
    /// Grid phase zero — the first cued presentation (tests pin that
    /// every later beat is anchor + k·period).
    private var anchorMicroseconds: UInt64 = 0
    private var lastPresentationMicroseconds: UInt64?
    private var lastMeasuredCueMicroseconds: UInt64 = 0
    private var lastPathDelayMicroseconds: UInt64 = 0
    private var lastReserveMicroseconds: UInt64 = 0
    private var lastSourceCaptureMicroseconds: UInt64?
    private var lastFrameWasRetained = false

    // Tail estimation: the Conductor's shared ring (the cue's
    // evidence — path-delay p99 over the recent window).
    private var pathDelayTailRing = Histogram<UInt64>(
        capacity: 600, retention: .rolling)

    // Slip proof: consecutive fresh frames with ≥1 beat of surplus
    // (the shared proof-before-shed law).
    private var slipProof = ProofCounter()

    // Debt (ported): a genuinely compressed catch-up train.
    private var lastFreshSourceMicroseconds: UInt64?
    private var lastFreshArrivalMicroseconds: UInt64?
    private var freshBurstDebtMicroseconds: UInt64 = 0
    private var debtRecoveryArmed = true
    private var stableFreshFramesAfterDebtRecovery = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func reset() {
        lastMeasuredCueMicroseconds = 0
        lastPathDelayMicroseconds = 0
        lastReserveMicroseconds = 0
        gridPresentationMicroseconds = nil
        previousFreshSourceForStep = nil
        anchorMicroseconds = 0
        lastPresentationMicroseconds = nil
        lastSourceCaptureMicroseconds = nil
        lastFrameWasRetained = false
        pathDelayTailRing.removeAll()
        slipProof.reset()
        lastFreshSourceMicroseconds = nil
        lastFreshArrivalMicroseconds = nil
        freshBurstDebtMicroseconds = 0
        debtRecoveryArmed = true
        stableFreshFramesAfterDebtRecovery = 0
    }

    /// A decoder reset starts a new dependency episode, not a new
    /// timebase: the grid, cue, and presentation floor all survive.
    public mutating func noteRandomAccessEnqueued() {
        lastSourceCaptureMicroseconds = nil
        lastFreshSourceMicroseconds = nil
        lastFreshArrivalMicroseconds = nil
        freshBurstDebtMicroseconds = 0
        lastFrameWasRetained = false
        if debtRecoveryArmed {
            stableFreshFramesAfterDebtRecovery = 0
        }
    }

    public mutating func schedule(
        mappedCaptureMicroseconds: UInt64,
        arrivalMicroseconds: UInt64,
        sourceCaptureMicroseconds: UInt64? = nil,
        isRandomAccess: Bool = false
    ) -> Decision {
        _ = isRandomAccess
        let period = config.beatPeriodMicroseconds
        let sourceCapture = sourceCaptureMicroseconds
            ?? mappedCaptureMicroseconds

        // chain (retained): the same authored pixels re-encoded ride
        // a microsecond behind their predecessor — no beat to claim.
        if lastSourceCaptureMicroseconds == sourceCapture {
            lastFrameWasRetained = true
            let presentation = max(
                arrivalMicroseconds,
                (lastPresentationMicroseconds ?? 0) &+ 1)
            lastPresentationMicroseconds = presentation
            return Decision(
                presentationMicroseconds: presentation,
                cueMicroseconds: lastMeasuredCueMicroseconds,
                pathDelayMicroseconds: lastPathDelayMicroseconds,
                reserveMicroseconds: lastReserveMicroseconds,
                latenessMicroseconds: 0,
                shouldFlush: false)
        }
        lastSourceCaptureMicroseconds = sourceCapture

        // Debt (ported verbatim from the adaptive playout): only a
        // genuinely compressed catch-up train accrues; normal cadence
        // ends the episode and re-arms after proof.
        if !lastFrameWasRetained,
           let previousFreshSource = lastFreshSourceMicroseconds,
           let previousFreshArrival = lastFreshArrivalMicroseconds {
            let sourceStep = sourceCapture > previousFreshSource
                ? sourceCapture - previousFreshSource : 0
            let arrivalStep = arrivalMicroseconds > previousFreshArrival
                ? arrivalMicroseconds - previousFreshArrival : 0
            if sourceStep > 0, arrivalStep < sourceStep / 2 {
                freshBurstDebtMicroseconds &+= sourceStep - arrivalStep
                if !debtRecoveryArmed {
                    stableFreshFramesAfterDebtRecovery = 0
                }
            } else {
                freshBurstDebtMicroseconds = 0
                if !debtRecoveryArmed {
                    stableFreshFramesAfterDebtRecovery += 1
                    if stableFreshFramesAfterDebtRecovery
                        >= config.freshDebtRearmStableFrames {
                        debtRecoveryArmed = true
                        stableFreshFramesAfterDebtRecovery = 0
                    }
                }
            }
        } else {
            freshBurstDebtMicroseconds = 0
        }
        lastFreshSourceMicroseconds = sourceCapture
        lastFreshArrivalMicroseconds = arrivalMicroseconds
        lastFrameWasRetained = false
        let excessiveDebt = freshBurstDebtMicroseconds
            > config.maximumFreshBurstDebtMicroseconds
        let shouldFlush = excessiveDebt && debtRecoveryArmed
        if shouldFlush { debtRecoveryArmed = false }

        // Path delay feeds the tail estimator.
        let pathDelay = arrivalMicroseconds >= mappedCaptureMicroseconds
            ? arrivalMicroseconds - mappedCaptureMicroseconds : 0
        pathDelayTailRing.record(pathDelay)

        // beat: the grid advances ORDINALLY — each fresh part steps
        // round(sourceStep / period) beats (never less than one) from
        // its predecessor. Capture-stamp wobble under half a beat
        // cannot collide two parts onto one beat or mint a phantom
        // skip; a true source skip (a genuinely missed capture) steps
        // the honest number of beats. The residual clock drift this
        // leaves (fixed period vs the score's crystal) is exactly
        // what the slip law absorbs.
        var presentation: UInt64
        if let lastGrid = gridPresentationMicroseconds,
           let previousSource = previousFreshSourceForStep {
            let sourceStep = sourceCapture > previousSource
                ? sourceCapture - previousSource : 0
            let beats = max(1, (sourceStep &+ period / 2) / period)
            presentation = lastGrid &+ beats &* period
        } else {
            // cue establishment: the first fresh part sets the grid
            // phase from its own delay plus the cushion, under the
            // ceiling.
            let cue = min(
                pathDelay &+ UInt64(config.cushionBeats) &* period,
                config.maximumCueMicroseconds)
            presentation = mappedCaptureMicroseconds &+ cue
            anchorMicroseconds = presentation
        }
        previousFreshSourceForStep = sourceCapture

        // The ceiling is live, with whole-beat hysteresis: a cut fires
        // only when a FULL beat of excess exists (mapping residual at
        // a pinned ceiling must not chatter the grid) and only when
        // the frame stays comfortably on time afterwards (so a re-cue
        // that the ceiling permitted is never fought back down — the
        // two moves are mutually exclusive by construction).
        if let lastGrid = gridPresentationMicroseconds {
            while presentation > mappedCaptureMicroseconds,
                  presentation - mappedCaptureMicroseconds
                      >= config.maximumCueMicroseconds &+ period,
                  presentation >= lastGrid &+ period,
                  presentation >= arrivalMicroseconds &+ period {
                presentation -= period
            }
        }

        // hole: the newest part's beat is already ≥1 beat gone —
        // re-cue forward by WHOLE beats so it lands on the next beat.
        // (A merely-late single part — under one beat — keeps its
        // past beat and is never shown; that is the late law, and it
        // must not move the grid.)
        if arrivalMicroseconds > presentation,
           arrivalMicroseconds - presentation >= period {
            let lag = arrivalMicroseconds - presentation
            var beatsBehind = (lag + period - 1) / period
            let cueNow = presentation &- mappedCaptureMicroseconds
            let room = config.maximumCueMicroseconds > cueNow
                ? (config.maximumCueMicroseconds - cueNow) / period : 0
            // The ceiling wins: re-cue as far as allowed, and the
            // remainder stays honest lateness.
            beatsBehind = min(beatsBehind, room)
            presentation &+= beatsBehind &* period
            slipProof.reset()
        }

        // slip: sustained proof of a full beat of surplus hands one
        // beat back. The evidence is the MEASURED cue (grid minus
        // score) against the path-delay tail — so the slow drift of
        // a fixed period against the score's crystal surfaces here
        // and is repaid one scheduled beat at a time.
        let measuredCue = presentation > mappedCaptureMicroseconds
            ? presentation - mappedCaptureMicroseconds : 0
        let cushionFloor = UInt64(config.cushionBeats) &* period
        if measuredCue >= pathDelay &+ cushionFloor &+ period {
            slipProof.advance()
            if slipProof.reached(config.slipProofFrames),
               measuredCue >= (pathDelayTailRing.p99 ?? 0)
                   &+ cushionFloor &+ period {
                presentation -= period
                slipProof.reset()
            }
        } else {
            slipProof.reset()
        }

        // late: the beat stands even when it has passed — report the
        // lateness, never reschedule.
        let lateness = arrivalMicroseconds > presentation
            ? arrivalMicroseconds - presentation : 0
        gridPresentationMicroseconds = max(
            presentation, gridPresentationMicroseconds ?? 0)

        // Strictly increasing PTS is the only concession: a
        // transitional collision (slip, ceiling cut) bumps one
        // microsecond and the grid itself never moves off-phase.
        if let previous = lastPresentationMicroseconds,
           presentation <= previous {
            presentation = previous &+ 1
        }
        lastPresentationMicroseconds = presentation
        let finalCue = presentation > mappedCaptureMicroseconds
            ? presentation - mappedCaptureMicroseconds : 0
        let reserve = finalCue > pathDelay ? finalCue - pathDelay : 0
        lastMeasuredCueMicroseconds = finalCue
        lastPathDelayMicroseconds = pathDelay
        lastReserveMicroseconds = reserve

        return Decision(
            presentationMicroseconds: presentation,
            cueMicroseconds: finalCue,
            pathDelayMicroseconds: pathDelay,
            reserveMicroseconds: reserve,
            latenessMicroseconds: lateness,
            shouldFlush: shouldFlush)
    }

}
