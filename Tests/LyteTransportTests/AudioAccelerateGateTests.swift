import XCTest
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE GATE (CL-17): the M7 audio remainder in virtual time — WSOLA
// accelerate drains an overfull pipe to target at a bounded rate with
// sine-wave continuity (the CL-11 evidence pattern), the skew term
// reads clock drift as a rate instead of depth, and a drain that runs
// dry hands to PLC cleanly. The route-change leg drives the production
// rebuild path against the real engine (skipped where no device
// exists).

final class AudioAccelerateGateTests: XCTestCase {

    private static let packetMicros: UInt64 = 5_000
    private static let packetFrames = AudioWire.samplesPerPacket   // 240
    private static let channels = AudioWire.channels               // 2
    private static let framesPerMs = 48

    /// One packet of a globally-phased sine, interleaved stereo —
    /// packet n picks up exactly where n−1 left off, so ANY dropped or
    /// duplicated sample outside a crossfade shows up as a click.
    private func sinePacketPcm(
        _ n: Int, hz: Double = 250, amplitude: Double = 0.5
    ) -> [Float] {
        var pcm = [Float]()
        pcm.reserveCapacity(Self.packetFrames * Self.channels)
        for frame in 0..<Self.packetFrames {
            let phase = 2 * Double.pi * hz
                * Double(n * Self.packetFrames + frame)
                / Double(AudioWire.sampleRate)
            let sample = Float(amplitude * sin(phase))
            for _ in 0..<Self.channels { pcm.append(sample) }
        }
        return pcm
    }

    /// Left-channel continuity: the largest sample-to-sample step. A
    /// clean sine's ceiling is A·2πf/fs; a splice seam that drops or
    /// repeats content jumps far past it.
    private func maxAdjacentDelta(_ interleaved: [Float]) -> Float {
        var worst: Float = 0
        var last: Float?
        var index = 0
        while index < interleaved.count {
            let sample = interleaved[index]
            if let last { worst = max(worst, abs(sample - last)) }
            last = sample
            index += Self.channels
        }
        return worst
    }

    private func leftChannelStats(_ interleaved: [Float])
        -> (rms: Double, zeroCrossHz: Double) {
        var sumSquares = 0.0
        var crossings = 0
        var last: Float = 0
        var frames = 0
        var index = 0
        while index < interleaved.count {
            let sample = interleaved[index]
            sumSquares += Double(sample) * Double(sample)
            if (sample > 0 && last <= 0) || (sample < 0 && last >= 0) {
                crossings += 1
            }
            if sample != 0 { last = sample }
            frames += 1
            index += Self.channels
        }
        let rms = (sumSquares / Double(max(frames, 1))).squareRoot()
        let seconds = Double(frames) / Double(AudioWire.sampleRate)
        return (rms, Double(crossings) / 2 / seconds)
    }

    // MARK: Leg 1 — WSOLA on a pure tone: pitch-true, click-free,
    // rate-bounded, exact books

    func testAccelerateOnSineIsContinuousPitchTrueAndRateBounded() {
        let accelerator = AudioAccelerator()
        var output: [Float] = []
        var inputFrames = 0
        for n in 0..<400 {                       // 2 s of 250 Hz tone
            let pcm = sinePacketPcm(n)
            inputFrames += Self.packetFrames
            output += accelerator.process(pcm, accelerate: true)
        }
        output += accelerator.flush()
        let stats = accelerator.stats

        // Books exact: nothing vanishes beyond the stretch.
        XCTAssertEqual(stats.inputFrames, UInt64(inputFrames))
        XCTAssertEqual(stats.outputFrames,
                       UInt64(output.count / Self.channels))
        XCTAssertEqual(stats.inputFrames,
                       stats.outputFrames + stats.framesRemoved,
                       "every input frame either plays or is excised")
        XCTAssertEqual(accelerator.pendingFrames, 0)

        // Rate bound: ≤5% sustained plus at most one banked period.
        XCTAssertGreaterThan(stats.removalOps, 0)
        XCTAssertLessThanOrEqual(
            stats.framesRemoved,
            UInt64(inputFrames) * 5 / 100
                + UInt64(AudioAccelerateConfig().maxPeriodFrames),
            "sustained speedup must stay within the 5% bound")
        XCTAssertGreaterThan(
            stats.framesRemoved, UInt64(inputFrames) * 3 / 100,
            "…but a self-similar tone should drain near the full rate")

        // Continuity: no click at any splice. A 250 Hz, 0.5-amplitude
        // sine steps at most A·2πf/fs ≈ 0.0164 per sample; allow 2×
        // for the crossfade's period rounding.
        let cleanCeiling = Float(0.5 * 2 * Double.pi * 250 / 48_000)
        XCTAssertLessThanOrEqual(maxAdjacentDelta(output),
                                 cleanCeiling * 2,
                                 "a splice seam clicked")
        // Pitch preserved (time-stretch, not resample) and level held.
        let measured = leftChannelStats(output)
        XCTAssertEqual(measured.zeroCrossHz, 250, accuracy: 5)
        XCTAssertEqual(20 * log10(measured.rms),
                       20 * log10(0.5 / 2.0.squareRoot()),
                       accuracy: 1.0)
    }

    // MARK: Leg 2 — passthrough is byte-exact; transients defer; a
    // disengage flush strands nothing

    func testPassthroughExactTransientsDeferSilenceCutsFreely() {
        // Not accelerating: the samples come back verbatim.
        let accelerator = AudioAccelerator()
        var rng = SplitMix64(seed: 0xC117)
        let noise = (0..<(Self.packetFrames * Self.channels)).map { _ in
            Float(bitPattern: 0x3F00_0000 | UInt32(rng.next() & 0x7F_FFFF))
                - 0.75   // ~±0.25, deterministic
        }
        XCTAssertEqual(accelerator.process(noise, accelerate: false), noise)

        // Accelerating through noise: no self-similar period exists —
        // the op defers instead of tearing, and every sample still
        // comes through in order.
        var output: [Float] = []
        var fed: [Float] = []
        for _ in 0..<40 {
            let pcm = (0..<(Self.packetFrames * Self.channels)).map { _ in
                Float(bitPattern: 0x3F00_0000 | UInt32(rng.next() & 0x7F_FFFF))
                    - 0.75
            }
            fed += pcm
            output += accelerator.process(pcm, accelerate: true)
        }
        output += accelerator.flush()
        XCTAssertEqual(accelerator.stats.framesRemoved, 0,
                       "white noise offers no period worth cutting")
        XCTAssertGreaterThan(accelerator.stats.opsDeferredLowCorrelation, 0)
        XCTAssertEqual(output, fed, "deferred ops pass through verbatim")

        // Silence splices freely — cutting nothing is free.
        let quiet = AudioAccelerator()
        for _ in 0..<40 {
            _ = quiet.process(
                [Float](repeating: 0,
                        count: Self.packetFrames * Self.channels),
                accelerate: true)
        }
        XCTAssertGreaterThan(quiet.stats.framesRemoved, 0,
                             "silence must drain at full rate")
    }

    // MARK: - The virtual-time pump harness (the CL-11 sim grown the
    // accelerator: receiver → synthetic decode → WSOLA → ring → DAC)

    private struct PumpResult {
        var played: [UInt32] = []
        var concealed: [UInt32] = []
        var output: [Float] = []
        var underrunFrames = 0
        /// First virtual instant the total pipe (pending + gather +
        /// ring) reached target + 1 packets and the drain disengaged.
        var drainedAtMicros: UInt64?
        var maxDepthPackets = 0.0
    }

    private func runPump(
        receiver: AudioReceiver,
        accelerator: AudioAccelerator,
        arrivals: [(at: UInt64, envelope: Envelope, payload: [UInt8])],
        untilMicros: UInt64
    ) -> PumpResult {
        var result = PumpResult()
        var ringFrames = 0
        var flowing = false
        var cursor = 0
        var t: UInt64 = 0
        while t <= untilMicros {
            while cursor < arrivals.count, arrivals[cursor].at <= t {
                receiver.ingest(
                    envelope: arrivals[cursor].envelope,
                    payload: arrivals[cursor].payload,
                    now: ClientTimestamp(microseconds: arrivals[cursor].at))
                cursor += 1
            }
            if flowing {
                if ringFrames >= Self.framesPerMs {
                    ringFrames -= Self.framesPerMs
                } else {
                    result.underrunFrames += Self.framesPerMs - ringFrames
                    ringFrames = 0
                }
            }
            var accelerating = false
            var pulling = true
            while pulling {
                if ringFrames < Self.packetFrames,
                   accelerator.pendingFrames > 0 {
                    let flushed = accelerator.flush()
                    ringFrames += flushed.count / Self.channels
                    result.output += flushed
                }
                guard ringFrames
                    < receiver.targetDepthPackets * Self.packetFrames
                else { break }
                let urgent = ringFrames < Self.packetFrames
                let held = ringFrames + accelerator.pendingFrames
                let decision = receiver.pullDecision(
                    now: ClientTimestamp(microseconds: t),
                    urgent: urgent,
                    renderPipelineMicroseconds: UInt64(held) * 1_000_000
                        / UInt64(AudioWire.sampleRate))
                accelerating = decision.accelerate
                let pcm: [Float]
                switch decision.verdict {
                case .packet(let packet):
                    result.played.append(packet.number)
                    pcm = sinePacketPcm(Int(packet.number))
                case .conceal(let number):
                    result.concealed.append(number)
                    pcm = [Float](repeating: 0,
                                  count: Self.packetFrames * Self.channels)
                case .starved:
                    pulling = false
                    continue
                }
                let out = accelerator.process(
                    pcm, accelerate: decision.accelerate)
                ringFrames += out.count / Self.channels
                result.output += out
                flowing = true
            }
            let depth = Double(receiver.pendingPackets)
                + Double(ringFrames + accelerator.pendingFrames)
                    / Double(Self.packetFrames)
            result.maxDepthPackets = max(result.maxDepthPackets, depth)
            if flowing, result.drainedAtMicros == nil, !accelerating,
               depth <= Double(receiver.targetDepthPackets + 1) {
                result.drainedAtMicros = t
            }
            t += 1_000
        }
        return result
    }

    /// One audio packet as the wire carries it (the leg-3 pattern from
    /// the CL-11 gate: real envelopes through the real depacketizer,
    /// data shards only — loss is not this gate's subject).
    private func wireArrivals(
        count: Int,
        arrivalStride: UInt64 = packetMicros,
        startAt: UInt64 = 10_000
    ) throws -> [(at: UInt64, envelope: Envelope, payload: [UInt8])] {
        var arrivals: [(at: UInt64, envelope: Envelope, payload: [UInt8])] = []
        let geometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 320)
        for n in 0..<count {
            let group = n / 4
            let index = n % 4
            let envelope = Envelope(
                channel: .audio,
                seq: ChannelSeq(rawValue: UInt16((group * 6 + index) & 0xFFFF)),
                frame: FrameNumber(rawValue: UInt32(group * 4)),
                timestamp: UInt64(n) * Self.packetMicros,
                fec: try FecField.reedSolomonShard(index, of: geometry).encoded)
            let payload = (0..<80).map {
                UInt8(truncatingIfNeeded: n &* 31 &+ $0)
            }
            arrivals.append(
                (startAt + UInt64(n) * arrivalStride, envelope, payload))
        }
        return arrivals
    }

    // MARK: Leg 3 — the drain: a 100 ms prime reaches target within
    // seconds at ≤5%, no skip, no PLC, in order

    func testOverfullPipeDrainsToTargetWithinBoundNoSkipNoPlc() throws {
        var config = AudioJitterConfig()
        config.initialTargetPackets = 20      // the forced ~100 ms open
        let receiver = AudioReceiver(jitterConfig: config)
        let accelerator = AudioAccelerator()
        let arrivals = try wireArrivals(count: 1_200)   // 6 s steady
        let result = runPump(
            receiver: receiver, accelerator: accelerator,
            arrivals: arrivals, untilMicros: 6_000_000)

        let stats = receiver.snapshotStats()
        XCTAssertGreaterThanOrEqual(stats.accelerateEngagements, 1,
            "the primed surplus must engage accelerate")
        XCTAssertEqual(stats.jitter.targetPackets,
                       config.minTargetPackets,
                       "a jitter-free trace decays the target to the floor")
        // Drained to target within the rate bound's reach: 15 packets
        // of surplus at 5% ≈ 1.5 s; allow scheduling slack.
        let drainedAt = try XCTUnwrap(result.drainedAtMicros,
                                      "the pipe never reached target")
        XCTAssertLessThanOrEqual(drainedAt, 3_500_000,
            "≈75 ms of surplus at ≤5% should drain in well under 3.5 s")
        // The drain was compression, never a skip and never silence.
        XCTAssertEqual(stats.jitter.recenterEvents, 0)
        XCTAssertEqual(stats.jitter.plcInvocations, 0)
        XCTAssertEqual(result.concealed.count, 0)
        XCTAssertEqual(result.played, result.played.sorted())
        XCTAssertEqual(result.played.count, Set(result.played).count)
        XCTAssertEqual(result.underrunFrames, 0)
        // Rate bound held over the whole run.
        let accel = accelerator.stats
        XCTAssertLessThanOrEqual(
            accel.framesRemoved,
            accel.inputFrames * 5 / 100
                + UInt64(AudioAccelerateConfig().maxPeriodFrames))
        XCTAssertGreaterThanOrEqual(accel.millisecondsDrained, 50,
            "most of the ~75 ms surplus drains through WSOLA")
        // Continuity through the whole drained stream (zero PLC, so
        // the sine must be seamless end to end).
        let cleanCeiling = Float(0.5 * 2 * Double.pi * 250 / 48_000)
        XCTAssertLessThanOrEqual(maxAdjacentDelta(result.output),
                                 cleanCeiling * 2)
        // The books agree with the receiver's own counters.
        XCTAssertEqual(stats.pullsAccelerated > 0, true)
    }

    // MARK: Leg 4 — the skew estimate converges, both signs, clamped

    func testSkewEstimateConvergesAndDriftNeverInflatesTarget() {
        // +200 ppm (sender slow): arrivals stretch 1 µs per packet.
        let slow = AudioJitterBuffer()
        for n in 0..<700 {
            slow.insert(
                AudioPacket(number: UInt32(n),
                            captureMicroseconds: UInt64(n) * Self.packetMicros,
                            bytes: [1], recovered: false),
                arrivalMicroseconds: 10_000 + UInt64(n) * 5_001)
            _ = slow.pull(nowMicroseconds: 10_000 + UInt64(n) * 5_001,
                          urgent: false)
        }
        let slowStats = slow.snapshotStats()
        XCTAssertEqual(slowStats.skewPartsPerMillion, 200, accuracy: 60)
        XCTAssertEqual(slowStats.targetPackets,
                       AudioJitterConfig().minTargetPackets,
                       "pure drift must not read as jitter depth")

        // −200 ppm (sender fast): the sign flips.
        let fast = AudioJitterBuffer()
        for n in 0..<700 {
            fast.insert(
                AudioPacket(number: UInt32(n),
                            captureMicroseconds: UInt64(n) * Self.packetMicros,
                            bytes: [1], recovered: false),
                arrivalMicroseconds: 10_000 + UInt64(n) * 4_999)
            _ = fast.pull(nowMicroseconds: 10_000 + UInt64(n) * 4_999,
                          urgent: false)
        }
        XCTAssertEqual(fast.snapshotStats().skewPartsPerMillion,
                       -200, accuracy: 60)

        // An implausible trend clamps — a burst's step can never
        // masquerade as crystal skew.
        let wild = AudioJitterBuffer()
        for n in 0..<700 {
            wild.insert(
                AudioPacket(number: UInt32(n),
                            captureMicroseconds: UInt64(n) * Self.packetMicros,
                            bytes: [1], recovered: false),
                arrivalMicroseconds: 10_000 + UInt64(n) * 4_900)
            _ = wild.pull(nowMicroseconds: 10_000 + UInt64(n) * 4_900,
                          urgent: false)
        }
        XCTAssertEqual(abs(wild.snapshotStats().skewPartsPerMillion),
                       AudioJitterConfig().maxSkewPartsPerMillion,
                       accuracy: 1)
    }

    // MARK: Leg 5 — sender-fast drift is absorbed by the drain, never
    // by recenter skips or growing latency

    func testSenderFastDriftIsAbsorbedByAccelerateNotSkips() throws {
        let receiver = AudioReceiver()
        let accelerator = AudioAccelerator()
        // 0.5% fast: every 4,975 µs a packet carrying 5 ms of audio —
        // surplus accrues at ~2.4 packets/min, well inside the 5%
        // drain bound.
        let arrivals = try wireArrivals(count: 4_000,
                                        arrivalStride: 4_975)
        let result = runPump(
            receiver: receiver, accelerator: accelerator,
            arrivals: arrivals, untilMicros: 4_000 * 4_975 + 10_000)

        let stats = receiver.snapshotStats()
        XCTAssertEqual(stats.jitter.recenterEvents, 0,
                       "drift must drain, never skip")
        XCTAssertEqual(stats.jitter.plcInvocations, 0)
        XCTAssertEqual(result.underrunFrames, 0)
        XCTAssertGreaterThan(accelerator.stats.framesRemoved, 0,
                             "the surplus went through WSOLA")
        // Depth stays pinned near target: never grows past the engage
        // band plus one gather's worth.
        let ceiling = Double(stats.jitter.targetPackets
            + AudioJitterConfig().accelerateEngagePackets) + 5
        XCTAssertLessThanOrEqual(result.maxDepthPackets, ceiling,
            "drift parked as latency: depth \(result.maxDepthPackets)")
        XCTAssertEqual(result.played, result.played.sorted())
        XCTAssertEqual(result.played.count, Set(result.played).count)
    }

    // MARK: Leg 6 — drain-then-underrun hands to PLC cleanly

    func testDrainThenStallHandsToPlcCleanlyAndGoesQuiet() throws {
        var config = AudioJitterConfig()
        config.initialTargetPackets = 20
        let receiver = AudioReceiver(jitterConfig: config)
        let accelerator = AudioAccelerator()
        // Steady for 1 s (drain in progress), then the wire goes dark.
        let arrivals = try wireArrivals(count: 200)
        let result = runPump(
            receiver: receiver, accelerator: accelerator,
            arrivals: arrivals, untilMicros: 2_500_000)

        let stats = receiver.snapshotStats()
        // PLC bridged the stall for exactly the configured budget,
        // then the buffer went quiet rather than looping artifacts.
        XCTAssertEqual(result.concealed.count,
                       config.maxConsecutiveConcealments)
        XCTAssertEqual(stats.jitter.plcInvocations,
                       UInt64(config.maxConsecutiveConcealments))
        XCTAssertGreaterThan(stats.jitter.starvedVerdicts, 0)
        // Everything real played first, in order, nothing stranded in
        // the gather (the dry-ring override flushed it).
        XCTAssertEqual(result.played.count, 200)
        XCTAssertEqual(result.played, result.played.sorted())
        XCTAssertEqual(accelerator.pendingFrames, 0)
        // The conceal run starts exactly where the content ended.
        XCTAssertEqual(result.concealed.first, 200)
        // Books exact through the handoff.
        let accel = accelerator.stats
        XCTAssertEqual(accel.inputFrames,
                       accel.outputFrames + accel.framesRemoved)
    }

    // MARK: Leg 7 — an output-device change rebuilds the engine with
    // the ring intact, counted (the production notification path)

    func testRouteChangeRebuildsOutputAndCounts() throws {
        let receiver = AudioReceiver()
        let player = try LyteAudioPlayer(receiver: receiver)
        do {
            try player.start()
        } catch {
            throw XCTSkip("no output device in this environment (\(error))")
        }
        defer { player.stop() }

        XCTAssertEqual(player.snapshotStats().routeChangesHandled, 0)
        player.handleOutputConfigurationChange()
        // The rebuild runs on the route queue against the real HAL.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              player.snapshotStats().routeChangesHandled == 0 {
            usleep(50_000)
        }
        let stats = player.snapshotStats()
        XCTAssertEqual(stats.routeChangesHandled, 1,
                       "the rebuild must complete and count")
        XCTAssertEqual(stats.routeChangeFailures, 0)
    }
}
