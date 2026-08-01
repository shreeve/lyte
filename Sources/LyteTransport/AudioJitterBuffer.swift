// AudioJitterBuffer (CL-11): the adaptive playout buffer the
// audio-continuity decision doc sized this slice for. The recorded
// verdict (docs/20260720-145840): delay VARIANCE, not loss, is the
// dominant impairment — so the buffer targets variance absorption with
// a statistical target (the doc's §5.3 percentile idea at 5 ms-packet
// granularity), conceals true gaps through Opus PLC (§5.4 — the
// verdict the caller turns into a decode(nil)), and never grows
// unbounded (late packets are dropped, a post-stall burst re-centers).
// WSOLA time-scale modification (§5.2) is deliberately NOT here — the
// CL-17 AudioAccelerator lives on the pump's PCM side; this buffer
// hands it the band between target and the hard cap (the re-center is
// now the blunt tool past the cap and for number jumps only), and its
// target computation detrends sender/receiver clock skew (§5.5) so a
// slow drift reads as a rate to absorb, never as depth to cover.
//
// Pull model (how the production shell drives it): the render side
// consumes a PCM ring at exactly the hardware rate; a pump thread
// pulls verdicts whenever the ring sits below the adaptive target.
// Pacing therefore locks to the DAC's clock — sender/receiver clock
// skew expresses as a slow drift the target absorbs, not as a timer
// beating against arrivals. `urgent` is the pump's "the ring is about
// to underrun" signal: while the ring has cushion the buffer may
// answer a gap with `.starved` (wait — FEC recovery lands at most
// ~3 packet durations after a loss), but an urgent gap is concealed
// NOW, because zeros are strictly worse than PLC.
//
// Sans-IO and single-threaded by contract: AudioReceiver owns the lock
// and injects `now` (client-monotonic µs domain of arrival stamps).

import LyteWire

public struct AudioJitterConfig: Sendable {
    /// The 5 ms cadence, in the arrival-clock domain.
    public var packetDurationMicroseconds: Int64 = 5_000
    /// Where the target starts and its floor: 5 packets (25 ms). One
    /// packet above the brief's conservative band, and deliberately:
    /// HS-15 emits parity behind the group's 4th packet, so a lost
    /// group-FIRST packet becomes repairable only ~15–16 ms after its
    /// own slot. Under the hold-until-dry gap policy the conceal fires
    /// after (target − 1) packet durations of drain — a floor of 5
    /// gives a 20 ms budget that beats the worst repair by a clear
    /// margin, so a healable loss NEVER costs a PLC. (At 4 the race
    /// loses by ε; measured in the in-tree FEC gate.)
    public var initialTargetPackets = 5
    public var minTargetPackets = 5
    public var maxTargetPackets = 20
    /// Depth beyond target that triggers a re-center (a stall's burst
    /// arriving at once must not become permanent added latency).
    public var slackPackets = 4
    /// Consecutive PLC invocations before the buffer declares itself
    /// starved outright (Opus PLC degrades gracefully to ~100 ms; a
    /// blackout beyond that should sound like silence, not artifacts).
    public var maxConsecutiveConcealments = 20
    /// A number jump past this re-primes instead of concealing across
    /// it (a FROZEN blackout's resume is a new playout epoch, not
    /// 250+ packets of PLC).
    public var recenterJumpPackets = 50
    /// Arrival-skew window (packets) the target is computed over —
    /// 512 ≈ 2.6 s of history at the 5 ms cadence.
    public var deviationWindowPackets = 512
    /// Recompute the percentile target every five fresh packets (25 ms
    /// at the wire cadence). Samples still enter the windows packet by
    /// packet; only the O(window log window) projection is decimated.
    /// A value of 1 retains the eager controller for equivalence tests.
    public var retargetCadencePackets = 5
    /// A newly earned cushion survives roughly one adaptation window before
    /// it may shrink. Live glass traces showed the eager downward projection
    /// collapsing 20 → 5 packets in under three seconds, followed by the same
    /// tail burst raising it again only after PLC/underrun. Rise remains
    /// immediate; decay starts after this many fresh packets.
    public var targetDecayHoldPackets = 500
    /// Once the hold expires, remove at most one packet per ten seconds of
    /// clean evidence. A 20-packet emergency target therefore cannot collapse
    /// back to the 5-packet floor between recurring tail events.
    public var targetDecayStepPackets = 2_000
    /// CL-17: packets of depth beyond target before the receiver's
    /// pull decision engages WSOLA accelerate (hysteresis: engage at
    /// target + this, disengage at target).
    public var accelerateEngagePackets = 3
    /// CL-17: the skew detrend's sanity clamp, ppm. Consumer crystals
    /// sit under ~100 ppm; the clamp keeps a burst's step from ever
    /// masquerading as skew (the inverse of the drift-as-depth error
    /// the term exists to fix).
    public var maxSkewPartsPerMillion = 500.0

    public init() {}

    /// The absolute pending bound (and the pump's ring hard cap):
    /// backlog past this is dropped by a re-center. maxTarget + slack.
    public var hardCapPackets: Int { maxTargetPackets + slackPackets }
}

/// What the puller should feed the decoder next.
public enum AudioPullVerdict: Equatable, Sendable {
    /// Decode and play this packet.
    case packet(AudioPacket)
    /// The packet at this number is gone (or still absent under an
    /// urgent pull) — invoke PLC for one packet duration.
    case conceal(number: UInt32)
    /// Nothing to feed: not yet primed, waiting out a reorder/FEC
    /// window, or a blackout exhausted the PLC budget.
    case starved
}

public struct AudioJitterStats: Sendable {
    public var packetsInserted: UInt64 = 0
    public var packetsPlayed: UInt64 = 0
    public var plcInvocations: UInt64 = 0
    /// Arrived after their slot had already played (or been concealed).
    public var latePacketsDropped: UInt64 = 0
    public var duplicatesDropped: UInt64 = 0
    /// Re-center events (overgrowth or number jump) and what they cost.
    public var recenterEvents: UInt64 = 0
    public var packetsDroppedInRecenter: UInt64 = 0
    /// Times a starved verdict was issued after priming (ring-cushion
    /// waits and blackout silence both land here).
    public var starvedVerdicts: UInt64 = 0
    /// Buffer depth in packets, recorded at every post-prime pull.
    /// 600 pulls at the 5 ms cadence = the rolling 3 s gauge window
    /// (one window for every overlay gauge, owner ruling 2026-07-30) —
    /// the gauge describes NOW, not the session's opening minute.
    public var depthPackets = LatencyHistogram(capacity: 600)
    /// |observed − nominal| inter-arrival deviation µs, fresh in-order
    /// arrivals only.
    public var interArrivalDeviation = LatencyHistogram(capacity: 600)
    /// Current adaptive target (packets).
    public var targetPackets = 0
    /// Windowed standard deviation of inter-arrival time, µs.
    public var interArrivalStdDevMicroseconds: Double = 0
    /// CL-17: the skew-window trend, ppm — the sender/receiver clock
    /// skew as the arrival lattice sees it (positive = sender slow,
    /// depth shrinks; negative = sender fast, depth grows — the drain
    /// the accelerate side absorbs). Clamped, 0 until ≥128 samples.
    public var skewPartsPerMillion: Double = 0
    /// Number of full percentile/detrend projections performed. This is
    /// an instrumentation hook for guarding the receive hot path.
    public var retargetComputations: UInt64 = 0

    public init() {}
}

public final class AudioJitterBuffer {
    public let config: AudioJitterConfig
    public private(set) var stats = AudioJitterStats()
    /// The adaptive delay target the pump sizes its ring against.
    public private(set) var targetPackets: Int

    private var pending: [UInt32: (packet: AudioPacket, arrivalMicroseconds: UInt64)] = [:]
    private var started = false
    private var nextNumber: UInt32 = 0
    private var consecutiveConcealments = 0

    // Adaptation state (the percentile controller, audio-continuity
    // §5.3 at packet granularity): each fresh arrival's SKEW off the
    // 5 ms arrival lattice — skew_n = (arrival_n − anchorArrival) −
    // (n − anchorNumber) × 5 ms — windowed; the target covers the
    // window's (max − min) SPREAD. Spread is the statistic that sees
    // a burst for what it is: a 75 ms outage whose clump arrives at
    // once leaves EVERY clumped packet 5–75 ms late on the lattice,
    // where per-pair inter-arrival deviations hide it in one sample
    // (found live — the first pup leg churned late/PLC with the
    // target stuck at the floor). Windowed differences also cancel
    // sender/receiver clock drift (≤0.2 ms across the window at
    // consumer-crystal ppm).
    /// Signed anchor arrival: the wrap-fold below shifts it by the
    /// window minimum, which a sender-fast drift makes NEGATIVE — a
    /// small test-clock origin underflowed the old unsigned form
    /// (production uptime stamps never could; fixed at CL-17).
    private var skewAnchor: (number: UInt32, arrivalMicroseconds: Int64)?
    private var skewWindow: [Int64] = []
    private var skewCursor = 0
    /// The detrend's output (CL-17): the window's least-squares slope
    /// read as clock skew, clamped to config bounds.
    private var estimatedSkewPpm: Double = 0
    // Pairwise inter-arrival deviation, kept for the σ/histogram
    // diagnostics the stats line reports.
    private var lastArrival: (number: UInt32, atMicroseconds: UInt64)?
    private var deviationWindow: [Int64] = []
    private var deviationCursor = 0
    private var freshSamplesSinceRetarget = 0
    private var freshSamplesSinceTargetRaise = 0
    private var freshSamplesSinceTargetDecrease = 0
    /// A configured opening is deliberately drainable at once; only cushion
    /// raised by measured path tails earns the long hold.
    private var targetCushionEarnedByPath = false

    public init(config: AudioJitterConfig = AudioJitterConfig()) {
        self.config = config
        self.targetPackets = config.initialTargetPackets
        self.stats.targetPackets = config.initialTargetPackets
        self.deviationWindow.reserveCapacity(config.deviationWindowPackets)
    }

    // MARK: - Insert

    public func insert(_ packet: AudioPacket, arrivalMicroseconds: UInt64) {
        stats.packetsInserted += 1

        if started {
            let distance = Int32(bitPattern: packet.number &- nextNumber)
            if distance < 0 {
                // A narrowly late packet is direct evidence that the current
                // cushion was too shallow. Learn from its sequence distance,
                // not its arrival timestamp (which may include repair time).
                // Ancient packets remain adaptation-inert replay noise.
                let behind = distance == .min ? Int.max : Int(-distance)
                if behind <= config.maxTargetPackets {
                    targetPackets = min(
                        config.maxTargetPackets,
                        targetPackets + behind)
                    targetCushionEarnedByPath = true
                    freshSamplesSinceTargetRaise = 0
                    freshSamplesSinceTargetDecrease = 0
                    stats.targetPackets = targetPackets
                }
                stats.latePacketsDropped += 1
                return
            }
        }
        guard pending[packet.number] == nil else {
            stats.duplicatesDropped += 1
            return
        }
        // Only packets admitted to the playout epoch describe the path.
        // Late/replayed packets carry stale or retransmit timing and must
        // not perturb target, skew, or diagnostic windows.
        noteArrivalForAdaptation(packet, arrivalMicroseconds: arrivalMicroseconds)
        pending[packet.number] = (packet, arrivalMicroseconds)

        if !started {
            if pending.count >= targetPackets {
                started = true
                nextNumber = oldestPendingNumber()!
            }
            return
        }
        recenterIfOvergrown()
    }

    // MARK: - Pull

    /// One playout decision. `urgent` = the consumer is about to run
    /// dry, so a gap must be concealed rather than waited out.
    public func pull(
        nowMicroseconds: UInt64, urgent: Bool = false
    ) -> AudioPullVerdict {
        guard started else { return .starved }
        stats.depthPackets.record(UInt64(pending.count))

        if let entry = pending.removeValue(forKey: nextNumber) {
            nextNumber &+= 1
            consecutiveConcealments = 0
            stats.packetsPlayed += 1
            return .packet(entry.packet)
        }

        guard let oldest = oldestPendingNumber() else {
            // Empty buffer: the stream stalled. PLC bridges a short
            // stall; a long one goes quiet until arrivals re-prime.
            guard urgent else {
                stats.starvedVerdicts += 1
                return .starved
            }
            return concealOrGoQuiet()
        }

        // A gap at the head with material behind it. A huge jump is a
        // resume-after-blackout: re-prime at the new head rather than
        // concealing across the void.
        let gap = Int32(bitPattern: oldest &- nextNumber)
        if gap >= Int32(config.recenterJumpPackets) {
            stats.recenterEvents += 1
            nextNumber = oldest
            consecutiveConcealments = 0
            let entry = pending.removeValue(forKey: nextNumber)!
            nextNumber &+= 1
            stats.packetsPlayed += 1
            return .packet(entry.packet)
        }

        // The missing packet may still be riding reorder or FEC repair
        // (parity lands ≤ ~3 packet durations behind a loss). The
        // adapted cushion between here and the speaker IS the wait
        // budget: hold while the consumer has audio, conceal the
        // moment it is due and dry. No arrival-time heuristics — an
        // early successor must never talk us into concealing a packet
        // that is merely a few ms late.
        guard urgent else {
            stats.starvedVerdicts += 1
            return .starved
        }
        return concealOrGoQuiet()
    }

    /// Packets currently queued (the ring-driven design keeps this
    /// near zero in steady state — buffered audio lives in the ring).
    public var pendingCount: Int { pending.count }

    public func snapshotStats() -> AudioJitterStats {
        var out = stats
        out.targetPackets = targetPackets
        out.interArrivalStdDevMicroseconds = windowStdDev()
        out.skewPartsPerMillion = estimatedSkewPpm
        return out
    }

    // MARK: - Interior

    private func concealOrGoQuiet() -> AudioPullVerdict {
        guard consecutiveConcealments < config.maxConsecutiveConcealments
        else {
            stats.starvedVerdicts += 1
            return .starved
        }
        consecutiveConcealments += 1
        stats.plcInvocations += 1
        let number = nextNumber
        nextNumber &+= 1
        return .conceal(number: number)
    }

    private func oldestPendingNumber() -> UInt32? {
        pending.keys.min { a, b in
            Int32(bitPattern: a &- b) < 0
        }
    }

    /// Overgrowth discipline, CL-17 posture: backlog between target
    /// and the hard cap belongs to WSOLA accelerate (time compression,
    /// no content lost); only past the cap does the skip fire — a
    /// blackout's burst must still never become unbounded latency.
    private func recenterIfOvergrown() {
        let limit = config.hardCapPackets
        guard pending.count > limit else { return }
        guard let newest = pending.keys.max(by: { a, b in
            Int32(bitPattern: a &- b) < 0
        }) else { return }
        let newNext = newest &- UInt32(targetPackets) &+ 1
        guard Int32(bitPattern: newNext &- nextNumber) > 0 else { return }
        var dropped: UInt64 = 0
        for key in pending.keys
        where Int32(bitPattern: key &- newNext) < 0 {
            pending.removeValue(forKey: key)
            dropped += 1
        }
        nextNumber = newNext
        consecutiveConcealments = 0
        stats.recenterEvents += 1
        stats.packetsDroppedInRecenter += dropped
    }

    /// Fresh, wire-carried arrivals feed the adaptation (recovered
    /// packets arrive on parity's schedule and duplicates on
    /// retransmit luck — neither describes the path).
    private func noteArrivalForAdaptation(
        _ packet: AudioPacket, arrivalMicroseconds: UInt64
    ) {
        guard !packet.recovered else { return }

        // Diagnostics: pairwise inter-arrival deviation (σ, histogram).
        if let last = lastArrival {
            let numberDelta = Int32(bitPattern: packet.number &- last.number)
            if numberDelta != 0, numberDelta.magnitude <= 8 {
                let expected = Int64(numberDelta)
                    * config.packetDurationMicroseconds
                let observed = Int64(bitPattern:
                    arrivalMicroseconds &- last.atMicroseconds)
                let deviation = observed - expected
                stats.interArrivalDeviation.record(UInt64(deviation.magnitude))
                if deviationWindow.count < config.deviationWindowPackets {
                    deviationWindow.append(deviation)
                } else {
                    deviationWindow[deviationCursor] = deviation
                    deviationCursor =
                        (deviationCursor + 1) % deviationWindow.count
                }
            }
        }
        lastArrival = (packet.number, arrivalMicroseconds)

        // The controller's sample: lattice skew against the anchor.
        let anchor = skewAnchor
            ?? (packet.number, Int64(arrivalMicroseconds))
        if skewAnchor == nil { skewAnchor = anchor }
        let numberDelta = Int32(bitPattern: packet.number &- anchor.number)
        let skew = Int64(arrivalMicroseconds) - anchor.arrivalMicroseconds
            - Int64(numberDelta) * config.packetDurationMicroseconds
        if skewWindow.count < config.deviationWindowPackets {
            skewWindow.append(skew)
        } else {
            skewWindow[skewCursor] = skew
            skewCursor = (skewCursor + 1) % skewWindow.count
            // Re-anchor periodically so the lattice reference cannot
            // wander (clock drift, a re-centered epoch): when the
            // cursor wraps, fold the window's min back into the anchor.
            if skewCursor == 0, let low = skewWindow.min() {
                skewAnchor = (anchor.number,
                              anchor.arrivalMicroseconds + low)
                for index in skewWindow.indices { skewWindow[index] -= low }
            }
        }
        freshSamplesSinceRetarget += 1
        freshSamplesSinceTargetRaise += 1
        freshSamplesSinceTargetDecrease += 1
        let cadence = max(1, config.retargetCadencePackets)
        guard freshSamplesSinceRetarget >= cadence else { return }
        freshSamplesSinceRetarget = 0
        retarget()
    }

    /// The continuity controller (audio-continuity §5.3 at packet
    /// granularity): the target covers the observed skew-window spread plus
    /// one packet of headroom, clamped to config bounds. The former p99
    /// discarded about five samples in a 512-packet window; live interval
    /// traces showed those sparse tails were exactly the late/PLC events.
    /// Audio's no-crack contract makes the bounded window maximum the honest
    /// statistic (the hard 100 ms cap still prevents unbounded latency).
    /// Only ever applied via natural drain/growth — no queue jumps.
    /// CL-17 adds the M7 §5.5 skew term: the window's least-squares
    /// trend is clock DRIFT, not jitter — it is estimated (clamped to
    /// consumer-crystal plausibility so a burst's step can't fake it),
    /// exposed, and removed before the spread is measured, so a slow
    /// drift reads as a rate for accelerate to absorb, never as depth
    /// the target must cover.
    private func retarget() {
        guard skewWindow.count >= 16 else { return }
        stats.retargetComputations += 1
        let samples = chronologicalSkewWindow()

        var slopePerPacket = 0.0
        if samples.count >= 128 {
            // Least squares over (index, skew): index steps are one
            // packet interval apart on the arrival lattice.
            let n = Double(samples.count)
            let meanX = (n - 1) / 2
            var meanY = 0.0
            for value in samples { meanY += Double(value) }
            meanY /= n
            var num = 0.0
            var den = 0.0
            for (index, value) in samples.enumerated() {
                let dx = Double(index) - meanX
                num += dx * (Double(value) - meanY)
                den += dx * dx
            }
            let clamp = config.maxSkewPartsPerMillion * 1e-6
                * Double(config.packetDurationMicroseconds)
            slopePerPacket = min(max(num / den, -clamp), clamp)
        }
        estimatedSkewPpm = slopePerPacket
            / Double(config.packetDurationMicroseconds) * 1e6

        var residuals = [Double](repeating: 0, count: samples.count)
        for (index, value) in samples.enumerated() {
            residuals[index] = Double(value) - slopePerPacket * Double(index)
        }
        residuals.sort()
        let spread = Int64((residuals[residuals.count - 1]
            - residuals[0]).rounded(.up))
        let needed = 1 + Int((spread
            + config.packetDurationMicroseconds - 1)
            / config.packetDurationMicroseconds)
        // The target moves only once playout runs: the configured
        // initial target owns the priming phase (CL-17 — a primed
        // start must actually open that deep; the controller then
        // earns its way down and accelerate drains the surplus).
        guard started else { return }
        let desired = min(
            max(needed, config.minTargetPackets),
            config.maxTargetPackets)
        if desired > targetPackets {
            targetPackets = desired
            targetCushionEarnedByPath = true
            freshSamplesSinceTargetRaise = 0
            freshSamplesSinceTargetDecrease = 0
        } else if desired < targetPackets, !targetCushionEarnedByPath {
            targetPackets = desired
        } else if desired < targetPackets,
                  freshSamplesSinceTargetRaise
                    >= max(1, config.targetDecayHoldPackets),
                  freshSamplesSinceTargetDecrease
                    >= max(1, config.targetDecayStepPackets) {
            targetPackets -= 1
            freshSamplesSinceTargetDecrease = 0
            if targetPackets == config.minTargetPackets {
                targetCushionEarnedByPath = false
            }
        }
        stats.targetPackets = targetPackets
    }

    /// The skew ring in arrival order (oldest first) — the detrend's
    /// x-axis must be time, and the ring wraps.
    private func chronologicalSkewWindow() -> [Int64] {
        guard skewWindow.count == config.deviationWindowPackets,
              skewCursor != 0 else { return skewWindow }
        return Array(skewWindow[skewCursor...])
            + Array(skewWindow[..<skewCursor])
    }

    private func windowStdDev() -> Double {
        guard deviationWindow.count >= 2 else { return 0 }
        let mean = Double(deviationWindow.reduce(0, +))
            / Double(deviationWindow.count)
        let variance = deviationWindow.reduce(0.0) {
            let d = Double($1) - mean
            return $0 + d * d
        } / Double(deviationWindow.count - 1)
        return variance.squareRoot()
    }
}
