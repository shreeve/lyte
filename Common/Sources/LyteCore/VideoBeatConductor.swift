// VideoBeatConductor — video's part under THE CONDUCTOR
// (docs/decisions/20260803-050422-metronome-playout-design.md), sans-IO.
//
// The laws, as this instrument plays them:
//
//   cue   = score + measured_path_delay + cushion × beat_period
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
//   slip  = when every fresh sample across an elapsed clean window
//           proves a full beat of surplus, the cue slips back one
//           beat — at most one per proof, phase preserved.
//   stretch = the mirror of slip: when every fresh part across an
//           elapsed proof window arrives past its beat (a sub-beat
//           shortfall — a fast client clock draining the cue, or a
//           path grown by under a beat), the cue re-cues one beat.
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

    /// The grid: the last fresh part's on-beat presentation. Every
    /// move is a whole number of beats (ordinal step, re-cue, slip,
    /// ceiling cut), so the phase set at cue establishment survives
    /// every episode.
    private var gridPresentationMicroseconds: UInt64?
    /// The last fresh source capture, for the ordinal step.
    private var previousFreshSourceForStep: UInt64?
    private var lastPresentationMicroseconds: UInt64?
    private var lastMeasuredCueMicroseconds: UInt64 = 0
    private var lastPathDelayMicroseconds: UInt64 = 0
    private var lastReserveMicroseconds: UInt64 = 0
    private var lastSourceCaptureMicroseconds: UInt64?
    private var lastFrameWasRetained = false
    /// The quantized reserve posture currently in force. It starts at the
    /// configured floor, grows only through the hole law, and returns one
    /// beat at a time through ceiling cuts or sustained slip proof. An
    /// on-time part caps it at its measured reserve (in whole beats, never
    /// below the floor), so it counts reserve actually held, not moves.
    private var cushionBeatsInForce: Int

    // Video's slip proof is elapsed-time policy, not sample-count policy:
    // Direct Eye intentionally emits fewer frames when pixels stay still.
    // Every fresh sample in the window must retain a full beat of surplus;
    // any contrary evidence resets the window. The maximum observed path
    // delay keeps the final verdict at least as strict as every constituent
    // sample without retaining stale evidence past the named duration.
    private var slipProofStartMicroseconds: UInt64?
    private var slipProofMaximumPathDelayMicroseconds: UInt64 = 0
    /// Arrival of the first part in the current unbroken run of late
    /// fresh parts (the stretch law's proof window).
    private var stretchProofStartMicroseconds: UInt64?

    // Debt (ported): a genuinely compressed catch-up train.
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
        // The measured path delay is injected evidence; no OS clock enters
        // this sans-IO policy.
        let pathDelay = arrival >= mapped ? arrival - mapped : 0

        var presentation = step(
            sourceCapture: sourceCapture, mapped: mapped,
            pathDelay: pathDelay)
        cutToCeiling(&presentation, mapped: mapped, arrival: arrival)
        recue(&presentation, mapped: mapped, arrival: arrival)
        slip(&presentation, mapped: mapped, arrival: arrival,
             pathDelay: pathDelay)
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

    /// stretch + hole: re-cue forward by WHOLE beats so the newest part
    /// lands on the next beat, once per episode, within the cue ceiling
    /// and the cushion ceiling (the remainder stays honest lateness).
    ///
    /// hole — the part's beat is already ≥ 1 beat gone.
    /// stretch — the mirror of slip: EVERY fresh part across an elapsed
    ///   proof window arrived past its beat. The cue is short by a sub-beat
    ///   amount (a fast client clock draining it, or a path grown by under
    ///   a beat) and the late law alone would never show those parts.
    ///
    /// A single merely-late part keeps its past beat and is never shown;
    /// that is the late law, and it does not move the grid.
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

    /// slip: an elapsed proof window in which EVERY fresh sample proves a
    /// full beat of surplus above the floor hands one beat back. Time owns
    /// the duration, so 60 Hz motion, 30 Hz video, and one-Hz static
    /// keepalives all return cushion on the same schedule. The maximum
    /// path delay seen inside the window keeps the verdict at least as
    /// strict as every constituent sample; no stale outlier survives
    /// merely because content is sparse.
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
            // The window's earlier worst path sample still refutes the
            // return. Begin a new exact-duration proof with the current
            // qualifying sample; old evidence cannot linger by count.
            startSlipProof(at: arrival, pathDelay: pathDelay)
            return
        }
        presentation -= period
        cushionBeatsInForce = max(
            cushionBeatsInForce - 1, config.cushionBeats)
        resetSlipProof()
        // This same fresh sample may begin the next proof after the
        // one-beat return. Reusing the boundary sample makes "one beat
        // every two seconds" literal even at one Hz; it never authorizes a
        // second return in this call.
        let slippedCue = presentation > mapped ? presentation - mapped : 0
        if slippedCue >= pathDelay &+ cushionFloor &+ period {
            startSlipProof(at: arrival, pathDelay: pathDelay)
        }
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

        // The posture never claims more beats than the measured reserve
        // of an on-time part. A hole lands its part on the NEXT beat, so a
        // drift-driven hole leaves under one beat of real reserve; without
        // this, drift holes would spend the ceiling as if they had banked
        // cushion and the hole law would fall silent.
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
