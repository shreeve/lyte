// AudioJitterBuffer (CL-11): the adaptive playout buffer the
// audio-continuity decision doc sized this slice for. The recorded
// verdict (docs/20260720-145840): delay VARIANCE, not loss, is the
// dominant impairment — so the buffer targets variance absorption with
// a statistical target (the doc's §5.3 percentile idea at 5 ms-packet
// granularity), conceals true gaps through Opus PLC (§5.4 — the
// verdict the caller turns into a decode(nil)), and never grows
// unbounded (late packets are dropped, a post-stall burst re-centers).
// WSOLA time-scale modification (§5.2) is deliberately NOT here — it
// is the M7 receiver's seam-quality refinement; this buffer's
// re-center is a counted content skip, honest and bounded.
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
    public var depthPackets = LatencyHistogram(capacity: 1 << 14)
    /// |observed − nominal| inter-arrival deviation µs, fresh in-order
    /// arrivals only.
    public var interArrivalDeviation = LatencyHistogram(capacity: 1 << 14)
    /// Current adaptive target (packets).
    public var targetPackets = 0
    /// Windowed standard deviation of inter-arrival time, µs.
    public var interArrivalStdDevMicroseconds: Double = 0

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
    // window's (p99 − min) SPREAD. Spread is the statistic that sees
    // a burst for what it is: a 75 ms outage whose clump arrives at
    // once leaves EVERY clumped packet 5–75 ms late on the lattice,
    // where per-pair inter-arrival deviations hide it in one sample
    // (found live — the first pup leg churned late/PLC with the
    // target stuck at the floor). Windowed differences also cancel
    // sender/receiver clock drift (≤0.2 ms across the window at
    // consumer-crystal ppm).
    private var skewAnchor: (number: UInt32, arrivalMicroseconds: UInt64)?
    private var skewWindow: [Int64] = []
    private var skewCursor = 0
    // Pairwise inter-arrival deviation, kept for the σ/histogram
    // diagnostics the stats line reports.
    private var lastArrival: (number: UInt32, atMicroseconds: UInt64)?
    private var deviationWindow: [Int64] = []
    private var deviationCursor = 0

    public init(config: AudioJitterConfig = AudioJitterConfig()) {
        self.config = config
        self.targetPackets = config.initialTargetPackets
        self.stats.targetPackets = config.initialTargetPackets
        self.deviationWindow.reserveCapacity(config.deviationWindowPackets)
    }

    // MARK: - Insert

    public func insert(_ packet: AudioPacket, arrivalMicroseconds: UInt64) {
        stats.packetsInserted += 1
        noteArrivalForAdaptation(packet, arrivalMicroseconds: arrivalMicroseconds)

        if started,
           Int32(bitPattern: packet.number &- nextNumber) < 0 {
            stats.latePacketsDropped += 1
            return
        }
        guard pending[packet.number] == nil else {
            stats.duplicatesDropped += 1
            return
        }
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

    /// Overgrowth discipline: a burst that leaves more than
    /// target + slack queued is a stall's backlog — skip forward so
    /// equilibrium latency returns to the target (counted content
    /// skip; M7's accelerate replaces the skip with compression).
    private func recenterIfOvergrown() {
        let limit = targetPackets + config.slackPackets
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
        let anchor = skewAnchor ?? (packet.number, arrivalMicroseconds)
        if skewAnchor == nil { skewAnchor = anchor }
        let numberDelta = Int32(bitPattern: packet.number &- anchor.number)
        let skew = Int64(bitPattern:
            arrivalMicroseconds &- anchor.arrivalMicroseconds)
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
                              UInt64(Int64(anchor.arrivalMicroseconds) + low))
                for index in skewWindow.indices { skewWindow[index] -= low }
            }
        }
        retarget()
    }

    /// The percentile controller (audio-continuity §5.3 at packet
    /// granularity): the target covers the skew window's p99 − min
    /// spread plus one packet of headroom, clamped to config bounds.
    /// Only ever applied via natural drain/growth — no queue jumps.
    private func retarget() {
        guard skewWindow.count >= 16 else { return }
        let sorted = skewWindow.sorted()
        let p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
        let spread = p99 - sorted[0]
        let needed = 1 + Int((spread
            + config.packetDurationMicroseconds - 1)
            / config.packetDurationMicroseconds)
        targetPackets = min(
            max(needed, config.minTargetPackets),
            config.maxTargetPackets)
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
