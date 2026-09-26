// AudioJitterBuffer: the adaptive audio playout buffer
// (docs/decisions/20260720-145840-audio-continuity.md). It absorbs delay
// variance with a skew-spread target, conceals true gaps through Opus
// PLC, and stays bounded (late packets drop, a post-stall burst
// re-centers). A packet late only for a concealment issued on an empty
// buffer still plays, so a slow sender's drift becomes delay rather than
// a concealment per packet. Depth between target and the hard cap belongs
// to LyteTransport's AudioAccelerator; clock skew is detrended so drift
// reads as a rate to absorb, never as depth to cover.
//
// Pull model: the render side drains a PCM ring at the hardware rate and
// a pump pulls verdicts while the ring sits below target. `urgent` means
// the ring is about to underrun: a gap may otherwise be waited out
// (`.starved`, FEC repair lands within ~3 packet durations), but an
// urgent gap is concealed now — zeros are worse than PLC.
//
// Sans-IO and single-threaded: AudioReceiver owns the lock and injects
// `now` (client-monotonic µs, the arrival-stamp domain).

import LyteCore
import LyteWire

public struct AudioJitterConfig: Sendable {
    /// The 5 ms cadence (audio's beat period), in the arrival-clock
    /// domain — the wire's constant, not a private copy.
    public var packetDurationMicroseconds =
        Int64(AudioWire.packetDurationMicroseconds)
    /// Where the target starts and its floor: 5 packets (25 ms). FEC
    /// parity follows a group's 4th packet, so a lost group-first packet
    /// is repairable only ~15–16 ms after its slot; the conceal fires
    /// after (target − 1) packet durations, and 5 leaves a 20 ms budget
    /// so a healable loss never costs a PLC.
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
    /// Recompute the target every five fresh packets (25 ms). Samples
    /// enter the windows per packet; only the projection is decimated.
    /// A value of 1 keeps the eager controller for equivalence tests.
    public var retargetCadencePackets = 5
    /// A cushion earned from the path survives roughly one adaptation
    /// window before it may shrink. Rise is immediate; decay starts
    /// after this many fresh packets.
    public var targetDecayHoldPackets = 500
    /// Once the hold expires, shed at most one packet per ten seconds of
    /// clean evidence, so an emergency target cannot collapse to the
    /// floor between recurring tail events.
    public var targetDecayStepPackets = 2_000
    /// Packets of depth beyond target before the receiver engages WSOLA
    /// accelerate (engage at target + this, disengage at target).
    public var accelerateEngagePackets = 3
    /// The skew detrend's clamp, ppm. Consumer crystals sit under
    /// ~100 ppm; the clamp keeps a burst's step from masquerading as skew.
    public var maxSkewPartsPerMillion = 500.0

    public init() {}

    /// The pending bound outside a wake burst's drain: backlog past this
    /// is dropped by a re-center. maxTarget + slack.
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
    /// 600 pulls at the 5 ms cadence = the rolling 3 s gauge window.
    public var depthPackets = Histogram<UInt64>(
        capacity: 600, retention: .rolling)
    /// |observed − nominal| inter-arrival deviation µs, fresh in-order
    /// arrivals only.
    public var interArrivalDeviation = Histogram<UInt64>(
        capacity: 600, retention: .rolling)
    /// Current adaptive target (packets).
    public var targetPackets = 0
    /// Windowed standard deviation of inter-arrival time, µs.
    public var interArrivalStdDevMicroseconds: Double = 0
    /// Sender/receiver clock skew from the skew-window trend, ppm
    /// (positive = sender slow, depth shrinks). Clamped; 0 until ≥128
    /// samples.
    public var skewPartsPerMillion: Double = 0
    /// Number of full spread/detrend projections performed.
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
    /// The last packet handed out to play; nil before the first.
    private var lastPlayedNumber: UInt32?
    private var consecutiveConcealments = 0
    /// Set by an announced quiet, cleared by the packet that wakes it.
    private var announcedQuiet = false
    /// The latest arrival of the wake burst that ends a quiet: the host
    /// ships its pre-roll at once, which describes its ring, not the path.
    private var wakeBurstArrival: UInt64?
    /// The oldest number playout may still step back to. The slots from
    /// here to nextNumber were concealed on an empty buffer or skipped by
    /// a wake re-prime, and nothing has played since, so a wire-carried
    /// packet for one of them plays (the concealment becomes delay)
    /// instead of dropping.
    private var rewindFloor: UInt32?
    /// The pending depth past which a re-center fires: the hard cap, or
    /// the depth a wake burst delivered (the host's pre-roll is announced
    /// contract, not a stall), lowered with the depth as it drains.
    private var overgrowthLimit: Int

    // Adaptation state: each fresh arrival's skew off the 5 ms arrival
    // lattice — (arrival_n − anchorArrival) − (n − anchorNumber) × 5 ms —
    // is windowed, and the target covers the window's (max − min) spread.
    // Spread sees a burst as a burst: a clump after a 75 ms outage leaves
    // every clumped packet 5–75 ms late, where pairwise inter-arrival
    // deviation hides it in one sample.
    /// Signed: the wrap-fold shifts it by the window minimum, which a
    /// sender-fast drift makes negative.
    private var skewAnchor: (number: UInt32, arrivalMicroseconds: Int64)?
    /// Each sample's packet number (as its offset from the anchor) is the
    /// detrend's x-axis: lost, late or recovered packets leave no sample,
    /// and the drift is a rate per packet, not per sample.
    private var skewWindow: [(number: Int64, skew: Int64)] = []
    private var skewCursor = 0
    /// The window's least-squares slope read as clock skew, clamped.
    private var estimatedSkewPpm: Double = 0
    // Pairwise inter-arrival deviation, for the σ/histogram diagnostics.
    private var lastArrival: (number: UInt32, atMicroseconds: UInt64)?
    private var deviationWindow: [Int64] = []
    private var deviationCursor = 0
    // Proof before shed: fresh packets counted toward the retarget
    // cadence, the post-raise hold and the between-sheds step; any
    // contrary event starts a count over.
    private var retargetProof = 0
    private var raiseHoldProof = 0
    private var shedStepProof = 0
    /// A configured opening is deliberately drainable at once; only cushion
    /// raised by measured path tails earns the long hold.
    private var targetCushionEarnedByPath = false

    public init(config: AudioJitterConfig = AudioJitterConfig()) {
        self.config = config
        self.targetPackets = config.initialTargetPackets
        self.stats.targetPackets = config.initialTargetPackets
        self.overgrowthLimit = config.hardCapPackets
        self.deviationWindow.reserveCapacity(config.deviationWindowPackets)
    }

    /// An announced audio quiet is contract, not path evidence: until a
    /// wire-carried packet ahead of the last one played arrives, an empty
    /// buffer is not concealed, and that packet re-primes playout at
    /// itself (the host numbers on from the last packet it sent); a
    /// reordered predecessor arriving before anything plays still leads.
    /// A recovered or replayed packet neither wakes the quiet nor rewinds
    /// playout. The adaptation windows reset so the wake burst re-bases
    /// the epoch; the target survives. Idempotent.
    public func noteAnnouncedQuiet() {
        announcedQuiet = true
        resetAdaptationWindows()
    }

    /// True from an announced quiet until the packet that wakes it.
    public var isAnnouncedQuiet: Bool { announcedQuiet }

    private func resetAdaptationWindows() {
        skewAnchor = nil
        lastArrival = nil
        skewWindow.removeAll(keepingCapacity: true)
        skewCursor = 0
        deviationWindow.removeAll(keepingCapacity: true)
        deviationCursor = 0
    }

    // MARK: - Insert

    public func insert(_ packet: AudioPacket, arrivalMicroseconds: UInt64) {
        stats.packetsInserted += 1

        if announcedQuiet, !packet.recovered,
           lastPlayedNumber.map({ Int32(bitPattern: packet.number &- $0) > 0 })
               ?? true {
            announcedQuiet = false
            wakeBurstArrival = arrivalMicroseconds
            if pending.isEmpty {
                nextNumber = packet.number
                rewindFloor = lastPlayedNumber.map { $0 &+ 1 }
            }
        }
        if started {
            let distance = Int32(bitPattern: packet.number &- nextNumber)
            if distance < 0, !packet.recovered, let floor = rewindFloor,
               Int32(bitPattern: packet.number &- floor) >= 0 {
                nextNumber = packet.number
            } else if distance < 0 {
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
                    raiseHoldProof = 0
                    shedStepProof = 0
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
        // Before playout nothing bounds the pending numbers' spread, and
        // serial order is ambiguous across 2^31: a packet far from those
        // pending re-primes from itself, so every pending pair stays
        // within the hard cap and the oldest is well defined.
        if !started, let pendingNumber = pending.keys.first,
           Int32(bitPattern: packet.number &- pendingNumber).magnitude
               > UInt32(config.hardCapPackets) {
            stats.packetsDroppedInRecenter += UInt64(pending.count)
            pending.removeAll()
            resetAdaptationWindows()
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
        if wakeBurstArrival != nil {
            overgrowthLimit = max(overgrowthLimit, pending.count)
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
        overgrowthLimit = max(
            config.hardCapPackets,
            min(overgrowthLimit, pending.count + config.slackPackets))

        if let entry = pending.removeValue(forKey: nextNumber) {
            lastPlayedNumber = nextNumber
            nextNumber &+= 1
            consecutiveConcealments = 0
            rewindFloor = nil
            stats.packetsPlayed += 1
            return .packet(entry.packet)
        }

        guard let oldest = oldestPendingNumber() else {
            // Empty buffer: the stream stalled. PLC bridges a short
            // stall; a long one goes quiet until arrivals re-prime. An
            // announced quiet is silence by contract.
            guard urgent, !announcedQuiet else {
                stats.starvedVerdicts += 1
                return .starved
            }
            // The stream may only be late: the concealment stands in for
            // the packet, which still plays after it if it arrives next.
            let verdict = concealOrGoQuiet()
            if case .conceal(let number) = verdict, rewindFloor == nil {
                rewindFloor = number
            }
            return verdict
        }

        // A gap at the head with material behind it. A huge jump is a
        // resume-after-blackout: re-prime at the new head rather than
        // concealing across the void.
        let gap = Int32(bitPattern: oldest &- nextNumber)
        if gap >= Int32(config.recenterJumpPackets) {
            return resume(at: oldest)
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
        // A spent concealment budget means the blackout already went
        // quiet: the audio waiting behind the gap resumes now rather than
        // after the backlog overgrows and a recenter discards it.
        guard consecutiveConcealments < config.maxConsecutiveConcealments
        else { return resume(at: oldest) }
        rewindFloor = nil
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

    /// Re-primes playout at a pending packet and plays it: a new playout
    /// epoch after a blackout, never concealment across the void.
    private func resume(at number: UInt32) -> AudioPullVerdict {
        stats.recenterEvents += 1
        consecutiveConcealments = 0
        rewindFloor = nil
        let entry = pending.removeValue(forKey: number)!
        lastPlayedNumber = number
        nextNumber = number &+ 1
        stats.packetsPlayed += 1
        return .packet(entry.packet)
    }

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

    /// Backlog between target and the overgrowth limit belongs to WSOLA
    /// accelerate; only past the limit does the skip fire, so a blackout's
    /// burst never becomes unbounded latency.
    private func recenterIfOvergrown() {
        guard pending.count > overgrowthLimit else { return }
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
        rewindFloor = nil
        overgrowthLimit = config.hardCapPackets
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
        if let burst = wakeBurstArrival {
            guard arrivalMicroseconds &- burst
                >= UInt64(config.packetDurationMicroseconds)
            else {
                wakeBurstArrival = arrivalMicroseconds
                return
            }
            wakeBurstArrival = nil
        }

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
        let sample = (number: Int64(numberDelta), skew: skew)
        if skewWindow.count < config.deviationWindowPackets {
            skewWindow.append(sample)
        } else {
            skewWindow[skewCursor] = sample
            skewCursor = (skewCursor + 1) % skewWindow.count
            // Re-anchor periodically so the lattice reference cannot
            // wander (clock drift, a re-centered epoch): when the
            // cursor wraps, fold the window's min back into the anchor.
            if skewCursor == 0, let low = skewWindow.lazy.map(\.skew).min() {
                skewAnchor = (anchor.number,
                              anchor.arrivalMicroseconds + low)
                for index in skewWindow.indices {
                    skewWindow[index].skew -= low
                }
            }
        }
        retargetProof += 1
        raiseHoldProof += 1
        shedStepProof += 1
        let cadence = max(1, config.retargetCadencePackets)
        guard retargetProof >= cadence else { return }
        retargetProof = 0
        retarget()
    }

    /// The target covers the detrended skew-window spread plus one packet
    /// of headroom, clamped to config bounds. The window maximum (not a
    /// percentile) is the statistic because sparse tails are exactly the
    /// late/PLC events. The least-squares trend is clock drift, not
    /// jitter: it is estimated, clamped, exposed, and removed before the
    /// spread is measured. Applied only via natural drain/growth.
    private func retarget() {
        guard skewWindow.count >= 16 else { return }
        stats.retargetComputations += 1
        let count = skewWindow.count

        var slopePerPacket = 0.0
        if count >= 128 {
            // Least squares over (packet number, skew).
            let n = Double(count)
            var meanX = 0.0
            var meanY = 0.0
            for sample in skewWindow {
                meanX += Double(sample.number)
                meanY += Double(sample.skew)
            }
            meanX /= n
            meanY /= n
            var num = 0.0
            var den = 0.0
            for sample in skewWindow {
                let dx = Double(sample.number) - meanX
                num += dx * (Double(sample.skew) - meanY)
                den += dx * dx
            }
            let clamp = config.maxSkewPartsPerMillion * 1e-6
                * Double(config.packetDurationMicroseconds)
            if den > 0 { slopePerPacket = min(max(num / den, -clamp), clamp) }
        }
        estimatedSkewPpm = slopePerPacket
            / Double(config.packetDurationMicroseconds) * 1e6

        // The detrended spread in one pass: no copy, no sort.
        var lowest = Double.infinity
        var highest = -Double.infinity
        for sample in skewWindow {
            let residual = Double(sample.skew)
                - slopePerPacket * Double(sample.number)
            lowest = min(lowest, residual)
            highest = max(highest, residual)
        }
        let spread = Int64((highest - lowest).rounded(.up))
        let needed = 1 + Int((spread
            + config.packetDurationMicroseconds - 1)
            / config.packetDurationMicroseconds)
        // The configured initial target owns the priming phase; the
        // controller moves the target only once playout runs.
        guard started else { return }
        let desired = min(
            max(needed, config.minTargetPackets),
            config.maxTargetPackets)
        if desired > targetPackets {
            targetPackets = desired
            targetCushionEarnedByPath = true
            raiseHoldProof = 0
            shedStepProof = 0
        } else if desired < targetPackets, !targetCushionEarnedByPath {
            targetPackets = desired
        } else if desired < targetPackets,
                  raiseHoldProof >= max(1, config.targetDecayHoldPackets),
                  shedStepProof >= max(1, config.targetDecayStepPackets) {
            targetPackets -= 1
            shedStepProof = 0
            if targetPackets == config.minTargetPackets {
                targetCushionEarnedByPath = false
            }
        }
        stats.targetPackets = targetPackets
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
