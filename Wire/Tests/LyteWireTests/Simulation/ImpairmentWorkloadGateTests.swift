import XCTest
import LyteWire
import LyteWireTestKit

// The deterministic Wire half of `impairment-gate`: sustained packetized
// video and bidirectional CTRL ARQ share one phased virtual path. This is a
// workload gate, not another SimNet primitive test. It drives the same
// packetizer/FEC/envelope/assembler and ARQ machinery the two ends compose,
// then asserts user-visible cadence, bounded state, recovery, exactly-once,
// and quiescence properties across a realistic impairment story.
final class ImpairmentWorkloadGateTests: XCTestCase {
    private typealias CtrlEndpoint = ArqEndpoint<HostClock>

    private struct DecodedObservation {
        var frame: UInt32
        var capture: UInt64
        var arrival: UInt64
    }

    private func frame(number: UInt32, byteCount: Int, isIDR: Bool) -> [UInt8] {
        let header: [UInt8] = [
            0, 0, 0, 1, isIDR ? 0x26 : 0x02, 0x01,
        ]
        return header + (0..<(byteCount - header.count)).map {
            UInt8(truncatingIfNeeded: Int(number) &* 31 &+ $0 &* 17 &+ 7)
        }
    }

    func testPhasedVideoAndControlWorkloadMeetsRecoverySLOs() throws {
        let frameInterval: UInt64 = 16_667
        let constrainedStart: UInt64 = 1_500_000
        let burstStart: UInt64 = 2_500_000
        let reorderStart: UInt64 = 3_200_000
        let blackoutStart: UInt64 = 4_000_000
        let recoveryStart: UInt64 = 4_250_000
        let steadyStart: UInt64 = 5_000_000
        let workloadEnd: UInt64 = 6_000_000
        let drainEnd: UInt64 = 8_000_000
        let queueLimit = 128 * 1_024
        let assemblerLimit = 24

        let clean = SimNetConfig(
            baseDelayMicroseconds: 3_000,
            jitterMicroseconds: 1_000,
            bandwidthBitsPerSecond: 20_000_000,
            maxQueueByteCount: queueLimit
        )
        var net = SimNet(
            config: clean,
            seed: 0x1A_1F_4E_57,
            schedule: [
                // Deliberately below the offered video rate: queue delay grows
                // and the finite tail-drop queue must bound it.
                SimNetPhase(
                    startMicroseconds: constrainedStart,
                    config: SimNetConfig(
                        baseDelayMicroseconds: 3_000,
                        jitterMicroseconds: 1_000,
                        bandwidthBitsPerSecond: 4_000_000,
                        maxQueueByteCount: queueLimit
                    )
                ),
                // Capacity returns, but short correlated erasures now stress
                // whole-frame FEC rather than independent packet loss.
                SimNetPhase(
                    startMicroseconds: burstStart,
                    config: SimNetConfig(
                        baseDelayMicroseconds: 3_000,
                        jitterMicroseconds: 2_000,
                        bandwidthBitsPerSecond: 20_000_000,
                        maxQueueByteCount: queueLimit,
                        burstLoss: SimNetBurstLoss(
                            startRate: 0.025,
                            minimumDatagrams: 2,
                            maximumDatagrams: 5
                        )
                    )
                ),
                // Displacement reordering exceeds one frame interval while
                // ordinary loss and duplication exercise dedupe/holdback.
                SimNetPhase(
                    startMicroseconds: reorderStart,
                    config: SimNetConfig(
                        lossRate: 0.01,
                        duplicateRate: 0.02,
                        baseDelayMicroseconds: 3_000,
                        jitterMicroseconds: 45_000,
                        bandwidthBitsPerSecond: 20_000_000,
                        maxQueueByteCount: queueLimit
                    )
                ),
                SimNetPhase(
                    startMicroseconds: blackoutStart,
                    config: SimNetConfig(
                        lossRate: 1,
                        maxQueueByteCount: queueLimit
                    )
                ),
                SimNetPhase(
                    startMicroseconds: recoveryStart,
                    config: clean
                ),
            ]
        )

        var packetizer = VideoPacketizer()
        var assembler = VideoAssembler(config: VideoAssemblerConfig(
            holdbackFrameCount: 3,
            staleAfterMicroseconds: 250_000,
            maxTrackedGroups: assemblerLimit,
            reorderThresholdPackets: 3,
            fecImpossibleThresholdPackets: 10
        ))
        let arqConfig = ArqConfig(
            initialRttMicroseconds: 20_000,
            minPtoMicroseconds: 10_000,
            maxPtoMicroseconds: 500_000,
            maxSegmentBodyByteCount: 256
        )
        var hostCtrl = CtrlEndpoint(channel: .ctrl, config: arqConfig)
        var clientCtrl = CtrlEndpoint(channel: .ctrl, config: arqConfig)
        var hostCtrlSeq = ChannelSeq(rawValue: 0)
        var clientCtrlSeq = ChannelSeq(rawValue: 0)

        let hostMessages: [(UInt64, [UInt8])] = [
            (0, ModeTransition(mode: .active).encode()),
            (burstStart, ModeTransition(mode: .idle).encode()),
            (recoveryStart, ModeTransition(mode: .active).encode()),
        ]
        let clientMessages: [(UInt64, [UInt8])] = [
            (constrainedStart, IdrRequest(
                requestSeq: 0, frame: FrameNumber(rawValue: 89),
                coalescedCount: 1
            ).encode()),
            (reorderStart, IdrRequest(
                requestSeq: 1, frame: FrameNumber(rawValue: 191),
                coalescedCount: 3
            ).encode()),
            (recoveryStart, IdrRequest(
                requestSeq: 2, frame: FrameNumber(rawValue: 254),
                coalescedCount: 15
            ).encode()),
        ]
        let finalFrame = frame(number: 239, byteCount: 3_500, isIDR: true)
        let finalGroup = ArqGroupId(rawValue: 1)

        var nextHostMessage = 0
        var nextClientMessage = 0
        var finalFrameQueued = false
        var sentFrames: [UInt32: [UInt8]] = [:]
        var replayDatagram: [UInt8]?
        var replayQueued = false
        var decoded: [DecodedObservation] = []
        var decodedFrames = Set<UInt32>()
        var skippedFrames = Set<UInt32>()
        var staleDrops = 0
        var fecImpossible = 0
        var queueSamples: [Int] = []
        var peakTrackedGroups = 0
        var peakArqOutstanding = 0
        var hostDelivered: [[UInt8]] = []
        var clientDelivered: [[UInt8]] = []
        var finalFrameDeliveries = 0
        var finalFrameAcks = 0
        var ctrlSent = 0

        func absorbVideo(
            _ events: [VideoAssemblerEvent], now: UInt64
        ) {
            for event in events {
                switch event {
                case .decoded(let unit):
                    let number = unit.frameNumber.rawValue
                    XCTAssertTrue(
                        decodedFrames.insert(number).inserted,
                        "frame \(number) decoded more than once"
                    )
                    XCTAssertFalse(
                        skippedFrames.contains(number),
                        "stale frame \(number) resurrected after skip"
                    )
                    XCTAssertEqual(
                        unit.annexB, sentFrames[number],
                        "frame \(number) was not byte-exact"
                    )
                    decoded.append(DecodedObservation(
                        frame: number,
                        capture: unit.timestamp.microseconds,
                        arrival: now
                    ))
                case .framesSkipped(let from, let through, _):
                    if from.rawValue <= through.rawValue {
                        for number in from.rawValue...through.rawValue {
                            skippedFrames.insert(number)
                        }
                    }
                case .fecImpossible:
                    fecImpossible += 1
                case .shardDropped(.staleFrame):
                    staleDrops += 1
                default:
                    break
                }
            }
        }

        func ctrlEnvelope(
            payload: [UInt8], seq: inout ChannelSeq
        ) throws -> [UInt8] {
            let envelope = Envelope(
                channel: .ctrl,
                seq: seq,
                frame: FrameNumber(rawValue: 0),
                timestamp: 0,
                fec: 0
            )
            seq = seq.next
            return try envelope.encode(plaintextShard: payload)
        }

        var nextFrameAt: UInt64 = 0
        var nextFrameNumber: UInt32 = 0
        var now: UInt64 = 0
        while now <= drainEnd {
            let instant = HostTimestamp(microseconds: now)

            while now <= workloadEnd, nextFrameAt <= now {
                let number = nextFrameNumber
                let isIDR = number.isMultiple(of: 120)
                // A 7.0–9.5 KiB cadence resembles inter-frame variability
                // without making FEC runtime dominate the suite.
                let byteCount = 7_000 + Int(number % 6) * 500
                let bytes = frame(
                    number: number, byteCount: byteCount, isIDR: isIDR
                )
                sentFrames[number] = bytes
                let shards = try packetizer.packetize(
                    frame: bytes,
                    frameNumber: FrameNumber(rawValue: number),
                    captureTimestamp: HostTimestamp(
                        microseconds: nextFrameAt
                    ),
                    isIDR: isIDR,
                    regime: now >= burstStart && now < recoveryStart
                        ? .lossy : .clean
                )
                for shard in shards {
                    let datagram = try shard.encodeDatagram()
                    if number == 0, replayDatagram == nil {
                        replayDatagram = datagram
                    }
                    net.send(from: 0, bytes: datagram, now: now)
                }
                nextFrameNumber &+= 1
                nextFrameAt &+= frameInterval
            }

            while nextHostMessage < hostMessages.count,
                  hostMessages[nextHostMessage].0 <= now {
                try hostCtrl.send(
                    message: hostMessages[nextHostMessage].1, now: instant
                )
                nextHostMessage += 1
            }
            while nextClientMessage < clientMessages.count,
                  clientMessages[nextClientMessage].0 <= now {
                try clientCtrl.send(
                    message: clientMessages[nextClientMessage].1, now: instant
                )
                nextClientMessage += 1
            }
            // A reliable final frame enters just before the blackout. Its
            // initial segments/ACKs are cut, forcing PTO recovery afterwards.
            if !finalFrameQueued, now >= blackoutStart - 5_000 {
                finalFrameQueued = true
                try hostCtrl.sendOneShot(
                    message: finalFrame, group: finalGroup, now: instant
                )
            }
            // Replay a genuinely old network datagram after recovery. The
            // assembler must classify it stale; it may never emit frame zero.
            if !replayQueued, now >= steadyStart,
               let replayDatagram {
                replayQueued = true
                net.send(from: 0, bytes: replayDatagram, now: now)
            }

            for delivery in net.deliveries(upTo: now) {
                let decodedDatagram = try Envelope.decode(delivery.bytes)
                switch decodedDatagram.envelope.channel {
                case .videoActive:
                    absorbVideo(
                        assembler.ingest(
                            envelope: decodedDatagram.envelope,
                            payload: decodedDatagram.payload,
                            now: ClientTimestamp(microseconds: now)
                        ),
                        now: now
                    )
                case .ctrl:
                    let events = delivery.destination == 0
                        ? hostCtrl.ingest(
                            payload: decodedDatagram.payload, now: instant
                        )
                        : clientCtrl.ingest(
                            payload: decodedDatagram.payload, now: instant
                        )
                    for event in events {
                        switch event {
                        case .message(let group, let bytes):
                            if delivery.destination == 0 {
                                hostDelivered.append(bytes)
                            } else if group == finalGroup {
                                finalFrameDeliveries += 1
                                XCTAssertEqual(bytes, finalFrame)
                            } else {
                                clientDelivered.append(bytes)
                            }
                        case .oneShotAcknowledged(let group):
                            if delivery.destination == 0, group == finalGroup {
                                finalFrameAcks += 1
                            }
                        case .ignored:
                            break
                        }
                    }
                default:
                    XCTFail("unexpected workload channel")
                }
            }

            absorbVideo(
                assembler.evictStale(
                    now: ClientTimestamp(microseconds: now)
                ),
                now: now
            )

            let hostPoll = hostCtrl.poll(now: instant)
            for payload in hostPoll.datagrams {
                net.send(
                    from: 0,
                    bytes: try ctrlEnvelope(
                        payload: payload, seq: &hostCtrlSeq
                    ),
                    now: now
                )
                ctrlSent += 1
            }
            let clientPoll = clientCtrl.poll(now: instant)
            for payload in clientPoll.datagrams {
                net.send(
                    from: 1,
                    bytes: try ctrlEnvelope(
                        payload: payload, seq: &clientCtrlSeq
                    ),
                    now: now
                )
                ctrlSent += 1
            }

            queueSamples.append(net.queuedByteCount(from: 0, at: now))
            let tracked = sentFrames.keys.count {
                assembler.status(of: FrameNumber(rawValue: $0)) != nil
            }
            peakTrackedGroups = max(peakTrackedGroups, tracked)
            peakArqOutstanding = max(
                peakArqOutstanding,
                hostCtrl.outstandingSegmentCount
                    + clientCtrl.outstandingSegmentCount
            )

            now += 1_000
        }

        // Integrity and boundedness over the whole run.
        XCTAssertEqual(
            decoded.map(\.frame), decoded.map(\.frame).sorted(),
            "decode order must be strictly ascending"
        )
        XCTAssertEqual(Set(decoded.map(\.frame)).count, decoded.count)
        XCTAssertTrue(
            CadenceSLO.queueStayedBounded(queueSamples, limit: queueLimit)
        )
        XCTAssertLessThanOrEqual(net.peakQueuedByteCount, queueLimit)
        XCTAssertLessThanOrEqual(peakTrackedGroups, assemblerLimit)
        XCTAssertLessThanOrEqual(
            peakArqOutstanding, 32,
            "CTRL retransmit state must remain workload-bounded"
        )
        XCTAssertGreaterThan(
            net.queueDroppedCount, 0,
            "the constrained phase must actually exercise tail drop"
        )
        XCTAssertGreaterThan(
            fecImpossible, 0,
            "burst/blackout workload must cross the IDR-demand seam"
        )
        XCTAssertGreaterThan(
            staleDrops, 0,
            "late network data must be rejected, not resurrected"
        )

        func arrivals(
            captureRange: Range<UInt64>
        ) -> [UInt64] {
            decoded.filter {
                captureRange.contains($0.capture)
            }.map(\.arrival)
        }

        // Baseline: 60 fps packetization/FEC/assembly has no >25 ms stall
        // and p99 cadence remains within one scheduler millisecond of source.
        let baseline = arrivals(captureRange: 250_000..<constrainedStart)
        XCTAssertGreaterThan(baseline.count, 70)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(CadenceSLO.percentile(
                CadenceSLO.interArrivalGaps(baseline), p: 0.99
            )),
            UInt64(18_000)
        )
        XCTAssertTrue(
            CadenceSLO.stalls(baseline, exceeding: 25_000).isEmpty
        )

        // During pressure the queue is allowed to trade completeness for
        // bounded latency, but not to stop decoded progress for 400 ms.
        let pressure = arrivals(
            captureRange: constrainedStart..<blackoutStart
        )
        XCTAssertGreaterThan(pressure.count, 80)
        XCTAssertTrue(
            CadenceSLO.stalls(pressure, exceeding: 400_000).isEmpty
        )

        // The blackout is real (no frame captured in it survives), and its
        // visible stall is neither hidden nor allowed to leak past recovery.
        XCTAssertTrue(decoded.filter {
            $0.capture >= blackoutStart && $0.capture < recoveryStart
        }.isEmpty)
        let lastBeforeBlackout = try XCTUnwrap(decoded.last {
            $0.capture < blackoutStart
        }?.arrival)
        let firstAfterBlackout = try XCTUnwrap(decoded.first {
            $0.capture >= recoveryStart
        }?.arrival)
        let blackoutStall = firstAfterBlackout - lastBeforeBlackout
        XCTAssertGreaterThanOrEqual(blackoutStall, 200_000)
        XCTAssertLessThanOrEqual(blackoutStall, 600_000)

        // Recovery: first post-blackout captured frame must decode within
        // 350 ms of path restoration (stale window + path/serialization).
        let recoveryDelay = try XCTUnwrap(CadenceSLO.recoveryDelay(
            after: recoveryStart,
            observations: decoded.filter {
                $0.capture >= recoveryStart
            }.map(\.arrival)
        ))
        XCTAssertLessThanOrEqual(recoveryDelay, 350_000)

        // Once one second of clean recovery has elapsed, the workload must
        // return to steady 60 fps cadence with no >25 ms stalls.
        let steady = arrivals(captureRange: steadyStart..<workloadEnd)
        XCTAssertGreaterThan(steady.count, 55)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(CadenceSLO.percentile(
                CadenceSLO.interArrivalGaps(steady), p: 0.99
            )),
            UInt64(18_000)
        )
        XCTAssertTrue(CadenceSLO.stalls(
            steady, exceeding: 25_000
        ).isEmpty)

        // CTRL stream and one-shot semantics survive the same phases:
        // ordered byte-exact delivery, exactly one final-frame delivery and
        // completion, bounded retransmit state, then permanent quiescence.
        XCTAssertEqual(hostDelivered, clientMessages.map(\.1))
        XCTAssertEqual(clientDelivered, hostMessages.map(\.1))
        XCTAssertEqual(finalFrameDeliveries, 1)
        XCTAssertEqual(finalFrameAcks, 1)
        XCTAssertTrue(hostCtrl.isQuiescent)
        XCTAssertTrue(clientCtrl.isQuiescent)
        XCTAssertEqual(hostCtrl.outstandingSegmentCount, 0)
        XCTAssertEqual(clientCtrl.outstandingSegmentCount, 0)
        XCTAssertLessThan(ctrlSent, 100, "CTRL retransmits did not quiesce")
        XCTAssertNil(net.nextArrivalTime)

        let hostAfter = hostCtrl.poll(
            now: HostTimestamp(microseconds: drainEnd + 1_000_000)
        )
        let clientAfter = clientCtrl.poll(
            now: HostTimestamp(microseconds: drainEnd + 1_000_000)
        )
        XCTAssertTrue(hostAfter.datagrams.isEmpty)
        XCTAssertNil(hostAfter.nextTimerDeadline)
        XCTAssertTrue(clientAfter.datagrams.isEmpty)
        XCTAssertNil(clientAfter.nextTimerDeadline)
    }
}
