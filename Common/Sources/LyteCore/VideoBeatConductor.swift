// VideoBeatConductor: sans-IO video playout on the Conductor's beat grid
// (docs/decisions/20260803-050422-metronome-playout-design.md).
// cue = score + measured path delay + cushion × beat period; every fresh
// frame presents on the nearest beat and the grid only ever moves by
// whole beats. The per-law rules are documented on each step below. Debt
// flushing to await-IDR is recovery policy, separate from beat policy.

public struct VideoBeatConductor: Sendable {
    public struct Config: Sendable, Equatable {
        /// The score's beat period (60 Hz end to end by default).
        public var beatPeriodMicroseconds: UInt64
        /// The automatic reserve floor. A hole adds whole beats; sustained
        /// clean proof returns them one at a time, never below this floor.
        public var cushionBeats: Int
        /// The automatic reserve ceiling. Path trouble may grow the cushion
        /// only to this many whole beats; a worse hole stays honestly late
        /// instead of silently turning into more latency.
        public var maximumCushionBeats: Int
        /// Hard safety ceiling on the automatic cue.
        public var maximumCueMicroseconds: UInt64
        /// Elapsed clean surplus required before one slip. Time, rather than
        /// frame count, keeps the return law identical for 60 Hz motion,
        /// 30 Hz video, and sparse/static content.
        public var slipProofMicroseconds: UInt64
        /// A compressed catch-up train beyond this is a blackout
        /// worth an IDR, not a playout problem.
        public var maximumFreshBurstDebtMicroseconds: UInt64
        /// Cadence-stable fresh frames before debt recovery re-arms.
        public var freshDebtRearmStableFrames: Int

        public init(
            beatPeriodMicroseconds: UInt64 = ScoreBeat.periodMicroseconds,
            cushionBeats: Int = 1,
            maximumCushionBeats: Int = 4,
            maximumCueMicroseconds: UInt64 = 150_000,
            slipProofMicroseconds: UInt64 = 2_000_000,
            maximumFreshBurstDebtMicroseconds: UInt64 = 200_000,
            freshDebtRearmStableFrames: Int = 30
        ) {
            self.beatPeriodMicroseconds = max(beatPeriodMicroseconds, 1_000)
            self.cushionBeats = max(cushionBeats, 1)
            self.maximumCushionBeats = max(
                maximumCushionBeats, self.cushionBeats)
            self.maximumCueMicroseconds = max(
                maximumCueMicroseconds, self.beatPeriodMicroseconds)
            self.slipProofMicroseconds = max(slipProofMicroseconds, 1_000)
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

    /// The last fresh part's on-beat presentation. It only moves by whole
    /// beats, so the phase set at cue establishment survives every episode.
    private var gridPresentationMicroseconds: UInt64?
    /// The last fresh source capture, for the ordinal step.
    private var previousFreshSourceForStep: UInt64?
    private var lastPresentationMicroseconds: UInt64?
    private var lastMeasuredCueMicroseconds: UInt64 = 0
    private var lastPathDelayMicroseconds: UInt64 = 0
    private var lastReserveMicroseconds: UInt64 = 0
    private var lastSourceCaptureMicroseconds: UInt64?
    private var lastFrameWasRetained = false
    /// Reserve in whole beats: starts at the floor, grows only by re-cue,
    /// returns one beat at a time by ceiling cut or slip, and is capped by
    /// an on-time part's measured reserve so it counts reserve actually held.
    private var cushionBeatsInForce: Int

    // Slip proof is elapsed time, not sample count: still content emits
    // fewer frames. Every sample in the window must hold a full beat of
    // surplus; the window's maximum path delay keeps the verdict as strict
    // as its worst sample.
    private var slipProofStartMicroseconds: UInt64?
    private var slipProofMaximumPathDelayMicroseconds: UInt64 = 0
    /// Arrival of the first part in the current unbroken run of late
    /// fresh parts (the stretch law's proof window).
    private var stretchProofStartMicroseconds: UInt64?

    // Debt: a genuinely compressed catch-up train.
    private var lastFreshSourceMicroseconds: UInt64?
    private var lastFreshArrivalMicroseconds: UInt64?
    private var freshBurstDebtMicroseconds: UInt64 = 0
    private var debtRecoveryArmed = true
    private var stableFreshFramesAfterDebtRecovery = 0

    public init(config: Config = Config()) {
        self.config = config
        self.cushionBeatsInForce = config.cushionBeats
    }

    /// A new timebase: every book returns to its initial state.
    public mutating func reset() {
        self = VideoBeatConductor(config: config)
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

    /// Schedules one part. A random-access part plays to the same grid as
    /// any fresh part; decoder episodes are the handoff's concern.
    public mutating func schedule(
        mappedCaptureMicroseconds: UInt64,
        arrivalMicroseconds: UInt64,
        sourceCaptureMicroseconds: UInt64? = nil
    ) -> Decision {
        let mapped = mappedCaptureMicroseconds
        let arrival = arrivalMicroseconds
        let sourceCapture = sourceCaptureMicroseconds ?? mapped

        if lastSourceCaptureMicroseconds == sourceCapture {
            return chain(arrival: arrival)
        }
        lastSourceCaptureMicroseconds = sourceCapture

        let shouldFlush = accrueDebt(
            sourceCapture: sourceCapture, arrival: arrival)
        let pathDelay = arrival >= mapped ? arrival - mapped : 0

        var presentation = step(
            sourceCapture: sourceCapture, mapped: mapped,
            pathDelay: pathDelay)
        cutToCeiling(&presentation, mapped: mapped, arrival: arrival)
        recue(&presentation, mapped: mapped, arrival: arrival)
        slip(&presentation, mapped: mapped, arrival: arrival,
             pathDelay: pathDelay)
        bound(&presentation, arrival: arrival)
        return finish(
            presentation, mapped: mapped, arrival: arrival,
            pathDelay: pathDelay, shouldFlush: shouldFlush)
    }

    // MARK: - The laws, in the order one fresh part meets them

    /// chain (retained): the same authored pixels re-encoded ride a
    /// microsecond behind their predecessor — no beat to claim, no
    /// lateness minted, the books unchanged.
    private mutating func chain(arrival: UInt64) -> Decision {
        lastFrameWasRetained = true
        let presentation = max(
            arrival, (lastPresentationMicroseconds ?? 0) &+ 1)
        lastPresentationMicroseconds = presentation
        return Decision(
            presentationMicroseconds: presentation,
            cueMicroseconds: lastMeasuredCueMicroseconds,
            pathDelayMicroseconds: lastPathDelayMicroseconds,
            reserveMicroseconds: lastReserveMicroseconds,
            latenessMicroseconds: 0,
            shouldFlush: false)
    }

    /// Debt (recovery policy, not beat policy): only a genuinely
    /// compressed catch-up train accrues; normal cadence ends the episode
    /// and re-arms after proof. Returns whether to flush to await-IDR.
    private mutating func accrueDebt(
        sourceCapture: UInt64, arrival: UInt64
    ) -> Bool {
        if !lastFrameWasRetained,
           let previousFreshSource = lastFreshSourceMicroseconds,
           let previousFreshArrival = lastFreshArrivalMicroseconds {
            let sourceStep = sourceCapture > previousFreshSource
                ? sourceCapture - previousFreshSource : 0
            let arrivalStep = arrival > previousFreshArrival
                ? arrival - previousFreshArrival : 0
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
        lastFreshArrivalMicroseconds = arrival
        lastFrameWasRetained = false
        let shouldFlush = debtRecoveryArmed
            && freshBurstDebtMicroseconds
                > config.maximumFreshBurstDebtMicroseconds
        if shouldFlush { debtRecoveryArmed = false }
        return shouldFlush
    }

    /// beat: the grid advances ORDINALLY — each fresh part steps
    /// round(sourceStep / period) beats (never less than one) from its
    /// predecessor. Capture-stamp wobble under half a beat cannot collide
    /// two parts onto one beat or mint a phantom skip; a true source skip
    /// steps the honest number of beats. The first fresh part establishes
    /// the cue: its own delay plus the cushion, under the ceiling.
    private mutating func step(
        sourceCapture: UInt64, mapped: UInt64, pathDelay: UInt64
    ) -> UInt64 {
        let period = config.beatPeriodMicroseconds
        defer { previousFreshSourceForStep = sourceCapture }
        if let lastGrid = gridPresentationMicroseconds,
           let previousSource = previousFreshSourceForStep {
            let sourceStep = sourceCapture > previousSource
                ? sourceCapture - previousSource : 0
            let beats = max(1, (sourceStep &+ period / 2) / period)
            return lastGrid &+ beats &* period
        }
        let cue = min(
            pathDelay &+ UInt64(config.cushionBeats) &* period,
            config.maximumCueMicroseconds)
        return mapped &+ cue
    }

    /// The ceiling is live, with whole-beat hysteresis: a cut fires only
    /// while a FULL beat of excess exists (mapping residual at a pinned
    /// ceiling must not chatter the grid), never below the previous beat,
    /// and only while the part stays a beat early (so a re-cue the ceiling
    /// permitted is never fought back down). Each constraint reads
    /// "presentation − k·period ≥ threshold + period", so the number of
    /// whole-beat cuts is computed, not looped.
    private mutating func cutToCeiling(
        _ presentation: inout UInt64, mapped: UInt64, arrival: UInt64
    ) {
        guard let lastGrid = gridPresentationMicroseconds else { return }
        let period = config.beatPeriodMicroseconds
        let (ceiling, overflow) = mapped.addingReportingOverflow(
            config.maximumCueMicroseconds)
        let threshold = max(overflow ? .max : ceiling, lastGrid, arrival)
        guard presentation > threshold else { return }
        let cuts = (presentation - threshold) / period
        guard cuts > 0 else { return }
        presentation -= cuts * period
        cushionBeatsInForce = max(
            cushionBeatsInForce - Int(clamping: cuts), config.cushionBeats)
    }

    /// hole + stretch: re-cue forward by whole beats so the newest part
    /// lands on the next beat, within the cue and cushion ceilings (the
    /// remainder stays lateness). A hole is a beat already ≥ 1 beat gone;
    /// a stretch is every fresh part across an elapsed proof window
    /// arriving past its beat (a sub-beat shortfall). A single late part
    /// keeps its past beat and does not move the grid.
    private mutating func recue(
        _ presentation: inout UInt64, mapped: UInt64, arrival: UInt64
    ) {
        let period = config.beatPeriodMicroseconds
        guard arrival > presentation else {
            stretchProofStartMicroseconds = nil
            return
        }
        let lag = arrival - presentation
        var stretchProven = false
        if let proofStart = stretchProofStartMicroseconds {
            stretchProven = arrival >= proofStart
                && arrival - proofStart >= config.slipProofMicroseconds
        } else {
            stretchProofStartMicroseconds = arrival
        }
        guard stretchProven || lag >= period else { return }

        stretchProofStartMicroseconds = nil
        // Under a fast client clock the mapped capture can overtake the
        // grid; the cue in force is then zero, never a wrapped difference
        // that would erase the ceiling room.
        let cueNow = presentation > mapped ? presentation - mapped : 0
        let room = config.maximumCueMicroseconds > cueNow
            ? (config.maximumCueMicroseconds - cueNow) / period : 0
        let cushionRoom = UInt64(max(
            config.maximumCushionBeats - cushionBeatsInForce, 0))
        let beats = min((lag + period - 1) / period, room, cushionRoom)
        presentation &+= beats &* period
        cushionBeatsInForce += Int(beats)
        resetSlipProof()
    }

    /// slip: an elapsed proof window in which every fresh sample proves a
    /// full beat of surplus above the floor hands one beat back, on the
    /// same schedule at any frame rate.
    private mutating func slip(
        _ presentation: inout UInt64, mapped: UInt64, arrival: UInt64,
        pathDelay: UInt64
    ) {
        let period = config.beatPeriodMicroseconds
        let cushionFloor = UInt64(config.cushionBeats) &* period
        let measuredCue = presentation > mapped ? presentation - mapped : 0
        guard measuredCue >= pathDelay &+ cushionFloor &+ period else {
            resetSlipProof()
            return
        }
        guard let proofStart = slipProofStartMicroseconds,
              arrival >= proofStart else {
            startSlipProof(at: arrival, pathDelay: pathDelay)
            return
        }
        slipProofMaximumPathDelayMicroseconds = max(
            slipProofMaximumPathDelayMicroseconds, pathDelay)
        guard arrival - proofStart >= config.slipProofMicroseconds else {
            return
        }
        guard measuredCue >= slipProofMaximumPathDelayMicroseconds
            &+ cushionFloor &+ period else {
            // The window's worst sample refutes the return; restart the
            // proof from this qualifying sample.
            startSlipProof(at: arrival, pathDelay: pathDelay)
            return
        }
        presentation -= period
        cushionBeatsInForce = max(
            cushionBeatsInForce - 1, config.cushionBeats)
        resetSlipProof()
        // The boundary sample may begin the next proof (never a second
        // return in this call), so the return rate holds even at one Hz.
        let slippedCue = presentation > mapped ? presentation - mapped : 0
        if slippedCue >= pathDelay &+ cushionFloor &+ period {
            startSlipProof(at: arrival, pathDelay: pathDelay)
        }
    }

    /// horizon: no part presents further past its arrival than the cue
    /// ceiling plus the cushion ceiling. A capture stamp beyond that (a
    /// host clock fault) carries its mapped capture and ceiling with it,
    /// so the cue re-establishes at the cushion floor from arrival and
    /// the grid snaps there instead of holding every later part behind a
    /// far-future beat.
    private mutating func bound(
        _ presentation: inout UInt64, arrival: UInt64
    ) {
        let period = config.beatPeriodMicroseconds
        let lead = config.maximumCueMicroseconds
            &+ UInt64(config.maximumCushionBeats) &* period
        guard presentation > arrival, presentation - arrival > lead else {
            return
        }
        presentation = arrival &+ UInt64(config.cushionBeats) &* period
        gridPresentationMicroseconds = nil
        cushionBeatsInForce = config.cushionBeats
        stretchProofStartMicroseconds = nil
        resetSlipProof()
    }

    /// late: the beat stands even when it has passed — report the
    /// lateness, never reschedule. Strictly increasing PTS is the only
    /// concession: a transitional collision (slip, ceiling cut) bumps one
    /// microsecond and the grid itself never moves off-phase.
    private mutating func finish(
        _ scheduled: UInt64, mapped: UInt64, arrival: UInt64,
        pathDelay: UInt64, shouldFlush: Bool
    ) -> Decision {
        let period = config.beatPeriodMicroseconds
        let lateness = arrival > scheduled ? arrival - scheduled : 0
        gridPresentationMicroseconds = max(
            scheduled, gridPresentationMicroseconds ?? 0)

        var presentation = scheduled
        if let previous = lastPresentationMicroseconds,
           presentation <= previous {
            presentation = previous &+ 1
        }
        lastPresentationMicroseconds = presentation
        let cue = presentation > mapped ? presentation - mapped : 0
        let reserve = cue > pathDelay ? cue - pathDelay : 0

        // Cap the posture at an on-time part's measured reserve; otherwise
        // drift-driven holes would spend the ceiling as banked cushion and
        // the hole law would fall silent.
        if lateness == 0 {
            let reserveBeats = Int(clamping: (reserve &+ period &- 1) / period)
            cushionBeatsInForce = min(
                cushionBeatsInForce,
                max(config.cushionBeats, reserveBeats))
        }
        lastMeasuredCueMicroseconds = cue
        lastPathDelayMicroseconds = pathDelay
        lastReserveMicroseconds = reserve

        return Decision(
            presentationMicroseconds: presentation,
            cueMicroseconds: cue,
            pathDelayMicroseconds: pathDelay,
            reserveMicroseconds: reserve,
            latenessMicroseconds: lateness,
            shouldFlush: shouldFlush)
    }

    private mutating func resetSlipProof() {
        slipProofStartMicroseconds = nil
        slipProofMaximumPathDelayMicroseconds = 0
    }

    private mutating func startSlipProof(
        at arrivalMicroseconds: UInt64,
        pathDelay: UInt64
    ) {
        slipProofStartMicroseconds = arrivalMicroseconds
        slipProofMaximumPathDelayMicroseconds = pathDelay
    }
}
