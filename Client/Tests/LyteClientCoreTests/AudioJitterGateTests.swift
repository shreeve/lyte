import LyteClientCore
import LyteWire
import LyteWireTestKit
import XCTest

// The adaptive playout buffer in virtual time, driven the way the
// production pump drives it: a simulated PCM ring consumed at the
// hardware rate, refilled to the buffer's adaptive target, `urgent`
// when the ring nears dry. Scripted arrival traces: steady, bursty
// ±15 ms, true gaps → PLC, late-packet discipline, stall + burst
// re-centering. The FEC-healed leg runs through the real depacketizer
// in LyteTransport (AudioReceiverFecGateTests).

final class AudioJitterGateTests: XCTestCase {

    private static let packetMicros: UInt64 = 5_000
    private static let packetFrames = 240
    private static let framesPerMs = 48

    // MARK: - The virtual-time pump harness

    private struct SimResult {
        var played: [UInt32] = []
        var playedPackets: [AudioPacket] = []
        var concealed: [UInt32] = []
        /// Frames the ring could not supply while the stream flowed
        /// (measured only between first fill and the trace's end).
        var underrunFrames = 0
        /// (timeMs, plc count) pairs — for "clean second half" claims.
        var plcTimeline: [(atMicros: UInt64, number: UInt32)] = []
    }

    /// Drives the buffer exactly like LyteAudioPlayer's pump: 1 ms
    /// beats, ring drains 48 frames/ms once content exists, refills
    /// while below target, urgent when < one packet remains.
    private func simulate(
        buffer: AudioJitterBuffer,
        arrivals: [(atMicros: UInt64, packet: AudioPacket)],
        untilMicros: UInt64
    ) -> SimResult {
        var result = SimResult()
        var ringFrames = 0
        var flowing = false
        var cursor = 0
        let sorted = arrivals.sorted { $0.atMicros < $1.atMicros }
        var t: UInt64 = 0
        while t <= untilMicros {
            while cursor < sorted.count, sorted[cursor].atMicros <= t {
                buffer.insert(
                    sorted[cursor].packet,
                    arrivalMicroseconds: sorted[cursor].atMicros)
                cursor += 1
            }
            // Render side: one ms of consumption.
            if flowing {
                if ringFrames >= Self.framesPerMs {
                    ringFrames -= Self.framesPerMs
                } else {
                    result.underrunFrames += Self.framesPerMs - ringFrames
                    ringFrames = 0
                }
            }
            // Pump side: refill to target.
            var pulling = true
            while pulling,
                  ringFrames < buffer.targetPackets * Self.packetFrames {
                let urgent = ringFrames < Self.packetFrames
                switch buffer.pull(nowMicroseconds: t, urgent: urgent) {
                case .packet(let packet):
                    result.played.append(packet.number)
                    result.playedPackets.append(packet)
                    ringFrames += Self.packetFrames
                    flowing = true
                case .conceal(let number):
                    result.concealed.append(number)
                    result.plcTimeline.append((t, number))
                    ringFrames += Self.packetFrames
                    flowing = true
                case .starved:
                    pulling = false
                }
            }
            t += 1_000
        }
        return result
    }

    private func packet(_ n: UInt32, recovered: Bool = false) -> AudioPacket {
        AudioPacket(
            number: n,
            captureMicroseconds: UInt64(n) * Self.packetMicros,
            bytes: [UInt8(truncatingIfNeeded: Int(n))] + [1, 2, 3],
            recovered: recovered)
    }

    // MARK: Leg 1 — steady cadence: silence-free, minimal delay

    func testSteadyTraceZeroPlcZeroUnderrunTightTarget() {
        let buffer = AudioJitterBuffer()
        let arrivals = (0..<400).map { n in
            (atMicros: 10_000 + UInt64(n) * Self.packetMicros,
             packet: packet(UInt32(n)))
        }
        // The sim ends AT the last arrival: a trace that just stops is
        // a stall (PLC bridges it by design), not part of this leg.
        let result = simulate(
            buffer: buffer, arrivals: arrivals,
            untilMicros: 10_000 + 399 * Self.packetMicros)
        let stats = buffer.snapshotStats()
        XCTAssertEqual(result.played.count, 400, "every packet plays")
        XCTAssertEqual(result.played, result.played.sorted(), "in order")
        XCTAssertEqual(stats.plcInvocations, 0)
        XCTAssertEqual(stats.latePacketsDropped, 0)
        XCTAssertEqual(result.underrunFrames, 0)
        XCTAssertEqual(stats.targetPackets,
                       AudioJitterConfig().initialTargetPackets,
                       "zero measured jitter must not grow the target")
        XCTAssertEqual(stats.recenterEvents, 0)
    }

    func testCadencedRetargetMatchesEagerControllerAtEveryBoundary() {
        var eagerConfig = AudioJitterConfig()
        eagerConfig.retargetCadencePackets = 1
        var cadencedConfig = eagerConfig
        cadencedConfig.retargetCadencePackets = 5
        let eager = AudioJitterBuffer(config: eagerConfig)
        let cadenced = AudioJitterBuffer(config: cadencedConfig)

        // Deterministic virtual arrival time combines bounded jitter,
        // a queue step, and clock skew. Both controllers ingest every
        // packet; only their projection cadence differs.
        for n in 0..<600 {
            let jitter = Int64((n * 7_919) % 23_001) - 11_500
            let queueStep: Int64 = n >= 240 && n < 300 ? 18_000 : 0
            let clockSkew = Int64(n) * 2
            let at = 100_000 + Int64(n) * 5_000
                + jitter + queueStep + clockSkew
            let arrival = UInt64(at)
            eager.insert(packet(UInt32(n)), arrivalMicroseconds: arrival)
            cadenced.insert(packet(UInt32(n)), arrivalMicroseconds: arrival)

            if (n + 1).isMultiple(of: 5), n + 1 >= 20 {
                let eagerStats = eager.snapshotStats()
                let cadencedStats = cadenced.snapshotStats()
                XCTAssertEqual(cadenced.targetPackets, eager.targetPackets,
                    "packet \(n): quantized target must equal eager projection")
                XCTAssertEqual(
                    cadencedStats.skewPartsPerMillion,
                    eagerStats.skewPartsPerMillion,
                    accuracy: 0.000_001,
                    "packet \(n): detrend must use the same packet window")
            }
        }

        let eagerCount = eager.snapshotStats().retargetComputations
        let cadencedCount = cadenced.snapshotStats().retargetComputations
        XCTAssertEqual(eagerCount, 585)
        XCTAssertEqual(cadencedCount, 117)
        XCTAssertEqual(eagerCount, cadencedCount * 5,
            "default cadence removes four of every five full-window sorts")
    }

    func testDuplicateAndLatePacketsCannotMoveAdaptation() {
        var config = AudioJitterConfig()
        config.retargetCadencePackets = 1
        let buffer = AudioJitterBuffer(config: config)
        for n in 0..<100 {
            let jitter = UInt64((n * 997) % 9_000)
            buffer.insert(
                packet(UInt32(n)),
                arrivalMicroseconds: 50_000 + UInt64(n) * Self.packetMicros + jitter)
        }

        let beforeDuplicate = buffer.snapshotStats()
        buffer.insert(packet(99), arrivalMicroseconds: 9_000_000)
        let afterDuplicate = buffer.snapshotStats()
        XCTAssertEqual(afterDuplicate.duplicatesDropped, 1)
        XCTAssertEqual(afterDuplicate.retargetComputations,
                       beforeDuplicate.retargetComputations)
        XCTAssertEqual(afterDuplicate.targetPackets, beforeDuplicate.targetPackets)
        XCTAssertEqual(afterDuplicate.skewPartsPerMillion,
                       beforeDuplicate.skewPartsPerMillion)

        while case .packet = buffer.pull(
            nowMicroseconds: 9_000_000, urgent: true) {}
        let beforeLate = buffer.snapshotStats()
        buffer.insert(packet(0), arrivalMicroseconds: 10_000_000)
        let afterLate = buffer.snapshotStats()
        XCTAssertEqual(afterLate.latePacketsDropped, 1)
        XCTAssertEqual(afterLate.retargetComputations,
                       beforeLate.retargetComputations)
        XCTAssertEqual(afterLate.targetPackets, beforeLate.targetPackets)
        XCTAssertEqual(afterLate.skewPartsPerMillion,
                       beforeLate.skewPartsPerMillion)
    }

    func testNarrowLatePacketEarnsOnePacketOfCushion() {
        let buffer = AudioJitterBuffer()
        for n in 0..<5 {
            buffer.insert(
                packet(UInt32(n)),
                arrivalMicroseconds: UInt64(n) * Self.packetMicros)
        }
        for _ in 0..<5 {
            guard case .packet = buffer.pull(
                nowMicroseconds: 25_000, urgent: true) else {
                return XCTFail("primed packets must play")
            }
        }
        buffer.insert(packet(6), arrivalMicroseconds: 30_000)
        guard case .conceal(number: 5) = buffer.pull(
            nowMicroseconds: 30_000, urgent: true) else {
            return XCTFail("missing packet 5 must be concealed")
        }

        let beforeLate = buffer.targetPackets
        buffer.insert(packet(5), arrivalMicroseconds: 31_000)
        XCTAssertEqual(buffer.snapshotStats().latePacketsDropped, 1)
        XCTAssertEqual(buffer.targetPackets, beforeLate + 1)
    }

    // MARK: Leg 2 — bursty ±15 ms delay variance (the dominant
    // impairment per the audio-continuity verdict)

    func testBurstyJitterAdaptsTargetAndStaysContinuous() {
        let buffer = AudioJitterBuffer()
        var rng = SplitMix64(seed: 0xC111)   // "CL-11"
        let count = 2_000
        let arrivals = (0..<count).map { n -> (UInt64, AudioPacket) in
            let jitter = Int64(rng.next() % 30_001) - 15_000
            let at = Int64(50_000) + Int64(n) * Int64(Self.packetMicros)
                + jitter
            return (UInt64(at), packet(UInt32(n)))
        }
        let lastArrival = arrivals.map(\.0).max()!
        let result = simulate(
            buffer: buffer,
            arrivals: arrivals.map { (atMicros: $0.0, packet: $0.1) },
            untilMicros: lastArrival)
        let stats = buffer.snapshotStats()

        XCTAssertGreaterThan(
            stats.targetPackets, AudioJitterConfig().minTargetPackets)
        XCTAssertLessThanOrEqual(
            stats.targetPackets, AudioJitterConfig().maxTargetPackets)
        // Continuity once adapted: the second half is seam-free.
        let half = UInt64(count / 2) * Self.packetMicros + 50_000
        let latePlc = result.plcTimeline.filter { $0.atMicros > half }
        XCTAssertEqual(latePlc.count, 0,
            "adapted target absorbs ±15 ms: no PLC in the second half")
        // Reordered arrivals land as late drops or early holds, never
        // silent discontinuity: everything played stays in order.
        XCTAssertEqual(result.played, result.played.sorted())
        XCTAssertGreaterThan(result.played.count, count * 95 / 100)
    }

    func testEarnedCushionHoldsThenDecaysGradually() {
        var config = AudioJitterConfig()
        config.retargetCadencePackets = 1
        let buffer = AudioJitterBuffer(config: config)
        var raised = 0
        var held = 0
        for n in 0..<3_000 {
            let stepOffset: UInt64 = n >= 20 ? 50_000 : 0
            let arrival = 100_000 + UInt64(n) * Self.packetMicros + stepOffset
            buffer.insert(
                packet(UInt32(n)), arrivalMicroseconds: arrival)
            _ = buffer.pull(nowMicroseconds: arrival, urgent: true)
            if n == 200 { raised = buffer.targetPackets }
            if n == 400 { held = buffer.targetPackets }
        }

        XCTAssertGreaterThan(raised, config.minTargetPackets)
        XCTAssertGreaterThanOrEqual(
            held, raised,
            "earned cushion must survive the 2.5 s hold window")
        XCTAssertLessThan(
            buffer.targetPackets, held,
            "clean evidence eventually decays cushion")
        XCTAssertGreaterThan(
            buffer.targetPackets, config.minTargetPackets,
            "decay is gradual, never an eager collapse")
    }

    // MARK: Leg 4 — a true gap (loss beyond FEC) → PLC, exactly sized

    func testTrueGapConcealsExactlyTheMissingSlots() {
        let buffer = AudioJitterBuffer()
        // Packets 0…199 steady, except numbers 100–103 (one whole
        // group) never arrive.
        let arrivals = (0..<200).compactMap { n -> (UInt64, AudioPacket)? in
            guard n < 100 || n > 103 else { return nil }
            return (10_000 + UInt64(n) * Self.packetMicros,
                    packet(UInt32(n)))
        }
        let result = simulate(
            buffer: buffer,
            arrivals: arrivals.map { (atMicros: $0.0, packet: $0.1) },
            untilMicros: 10_000 + 199 * Self.packetMicros)
        let stats = buffer.snapshotStats()
        XCTAssertEqual(Set(result.concealed), Set([100, 101, 102, 103]),
                       "PLC exactly at the missing slots")
        XCTAssertEqual(stats.plcInvocations, 4)
        XCTAssertEqual(result.played.count, 196)
        XCTAssertEqual(result.played, result.played.sorted())
    }

    /// A blackout longer than the PLC budget but shorter than the re-prime
    /// jump: once concealment has gone quiet, the resumed stream plays at
    /// its first urgent pull instead of waiting in silence until the
    /// backlog overgrows and a recenter throws the arrived audio away.
    func testResumeAfterSpentConcealmentBudgetPlaysAtOnce() {
        let buffer = AudioJitterBuffer()
        let budget = buffer.config.maxConsecutiveConcealments
        for n in UInt32(0)..<5 {
            buffer.insert(packet(n), arrivalMicroseconds: UInt64(n) * 5_000)
        }
        for _ in 0..<5 {
            guard case .packet = buffer.pull(nowMicroseconds: 0, urgent: true)
            else { return XCTFail("the primed packets play") }
        }
        for _ in 0..<budget {
            guard case .conceal = buffer.pull(nowMicroseconds: 0, urgent: true)
            else { return XCTFail("the blackout conceals within budget") }
        }
        XCTAssertEqual(buffer.pull(nowMicroseconds: 0, urgent: true), .starved,
                       "past the budget with nothing queued, silence")

        let resume = UInt32(5 + budget + 10)
        for n in resume..<resume + 3 {
            buffer.insert(packet(n), arrivalMicroseconds: 1_000_000)
        }
        XCTAssertEqual(buffer.pull(nowMicroseconds: 1_000_000, urgent: true),
                       .packet(packet(resume)))
        XCTAssertEqual(buffer.snapshotStats().packetsDroppedInRecenter, 0)
    }

    /// An announced quiet is not a blackout: no PLC runs while it lasts,
    /// and the host's wake burst (numbered on from the last packet sent)
    /// re-primes playout, so none of it is late and none of it raises the
    /// target. PLC that ran before the notice arrived does not push the
    /// resume behind the playhead.
    func testAnnouncedQuietConcealsNothingAndTheWakeBurstPlays() {
        let buffer = AudioJitterBuffer()
        for n in UInt32(0)..<10 {
            buffer.insert(packet(n), arrivalMicroseconds: UInt64(n) * 5_000)
        }
        for n in UInt32(0)..<10 {
            XCTAssertEqual(buffer.pull(nowMicroseconds: 50_000, urgent: true),
                           .packet(packet(n)))
        }
        for _ in 0..<3 {
            guard case .conceal = buffer.pull(nowMicroseconds: 60_000, urgent: true)
            else { return XCTFail("before the notice a gap conceals") }
        }
        buffer.noteAnnouncedQuiet()
        for _ in 0..<25 {
            XCTAssertEqual(buffer.pull(nowMicroseconds: 100_000, urgent: true), .starved)
        }
        // The pre-roll's quiet head goes to the hard-cap recenter; its
        // newest packets (the sound that tripped the wire) survive.
        for n in UInt32(10)..<50 {
            buffer.insert(packet(n), arrivalMicroseconds: 3_000_000)
        }
        XCTAssertEqual(buffer.pull(nowMicroseconds: 3_000_000, urgent: true),
                       .packet(packet(30)))
        for n in UInt32(50)..<150 {
            let at = 3_000_000 + UInt64(n - 49) * 5_000
            buffer.insert(packet(n), arrivalMicroseconds: at)
            _ = buffer.pull(nowMicroseconds: at, urgent: true)
        }
        let stats = buffer.snapshotStats()
        XCTAssertEqual(stats.plcInvocations, 3)
        XCTAssertEqual(stats.latePacketsDropped, 0)
        XCTAssertEqual(stats.targetPackets, 5)
    }

    /// Before playout starts nothing orders the pending packets by
    /// distance, and serial order is ambiguous across 2^31. A packet far
    /// from those already pending re-primes from itself, so playout never
    /// anchors on a stale or hostile outlier.
    func testPrimingNeverAnchorsAcrossAHalfRangeJump() {
        let buffer = AudioJitterBuffer()
        buffer.insert(packet(0), arrivalMicroseconds: 0)
        buffer.insert(packet(1), arrivalMicroseconds: 5_000)
        let far = UInt32(1) << 31 + 5
        for n in far..<far + 5 {
            buffer.insert(packet(n), arrivalMicroseconds: 10_000)
        }
        for n in far..<far + 5 {
            XCTAssertEqual(buffer.pull(nowMicroseconds: 10_000, urgent: true),
                           .packet(packet(n)))
        }
        XCTAssertEqual(buffer.pendingCount, 0,
                       "the outliers left no stale packets behind")
    }

    // MARK: Leg 5 — late-packet discipline

    func testLatePacketIsDroppedNotReplayed() {
        let buffer = AudioJitterBuffer()
        var arrivals = (0..<200).compactMap { n -> (UInt64, AudioPacket)? in
            guard n != 50 else { return nil }
            return (10_000 + UInt64(n) * Self.packetMicros,
                    packet(UInt32(n)))
        }
        // Packet 50 shows up 150 ms past its slot — long after its
        // moment was concealed.
        arrivals.append((10_000 + 50 * Self.packetMicros + 150_000,
                         packet(50)))
        let result = simulate(
            buffer: buffer,
            arrivals: arrivals.map { (atMicros: $0.0, packet: $0.1) },
            untilMicros: 10_000 + 199 * Self.packetMicros)
        let stats = buffer.snapshotStats()
        XCTAssertEqual(stats.latePacketsDropped, 1)
        XCTAssertEqual(result.concealed, [50])
        XCTAssertFalse(result.played.contains(50),
                       "a late packet never plays out of order")
        XCTAssertEqual(result.played, result.played.sorted())
    }

    // MARK: Leg 6 — stall + burst: bounded depth, re-centered latency

    func testStallBurstRecentersInsteadOfGrowingLatencyForever() {
        let buffer = AudioJitterBuffer()
        var arrivals: [(UInt64, AudioPacket)] = []
        // 100 steady packets…
        for n in 0..<100 {
            arrivals.append((10_000 + UInt64(n) * Self.packetMicros,
                             packet(UInt32(n))))
        }
        // …then a 300 ms stall: packets 100–159 all land at once…
        let burstAt = 10_000 + 100 * Self.packetMicros + 300_000
        for n in 100..<160 {
            arrivals.append((burstAt, packet(UInt32(n))))
        }
        // …then steady again from where the wire caught up.
        for n in 160..<260 {
            arrivals.append((burstAt + UInt64(n - 159) * Self.packetMicros,
                             packet(UInt32(n))))
        }
        let result = simulate(
            buffer: buffer,
            arrivals: arrivals.map { (atMicros: $0.0, packet: $0.1) },
            untilMicros: burstAt + UInt64(260 - 159) * Self.packetMicros)
        let stats = buffer.snapshotStats()
        XCTAssertGreaterThanOrEqual(stats.recenterEvents, 1,
            "the burst backlog must re-center, not become latency")
        XCTAssertGreaterThan(stats.packetsDroppedInRecenter, 0)
        // After the re-center the buffer sits at/below target + slack.
        let config = AudioJitterConfig()
        if let depthMax = stats.depthPackets.maxValue {
            XCTAssertLessThanOrEqual(
                Int(depthMax),
                config.maxTargetPackets + config.slackPackets,
                "pending depth stays bounded through the burst")
        }
        // The tail plays contiguously (post-recenter numbers ordered).
        XCTAssertEqual(result.played, result.played.sorted())
        XCTAssertTrue(result.played.contains(259), "the stream resumed")
    }
}
