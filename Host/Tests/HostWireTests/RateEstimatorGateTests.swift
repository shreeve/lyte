import XCTest
import HostCore
import HostSession
@_spi(Testing) import HostWire
import HostWireTestKit
import LyteWire
import LyteWireTestKit

// The congestion estimator's contract:
//
//   • delivery rate is MEASURED from dispersion trains matched against
//     the send ledger, and short trains are weighted down, not trusted;
//   • the rate falls fast on loss (multiplicative, at most one downshift
//     per 500 ms, never below the 2 Mbps operational floor) and on
//     queuing-delay inflation (anchored to the measured delivery rate),
//     and rises only on evidence (fresh delivery samples), ≤10%/s,
//     never above the negotiated ceiling;
//   • the estimator owns the RECOVERY window verdicts: loss inside a
//     window holds RECOVERY;
//   • the machine's IdrPacing policies get numbers: WAKE at
//     min(btlRate, lastGoodRate), RECOVERY at max(floor, ½ × stale
//     estimate), applied to the shared pacer the moment the machine
//     demands them;
//   • frameByteCeiling tracks the live estimate and current FEC regime;
//   • a loss burst that crashes the send rate mid-stream leaves audio
//     inter-send at 5 ms ± 2 ms at p99: rate changes re-cap video,
//     never audio's cadence.

final class RateEstimatorGateTests: XCTestCase {

    private static let ceiling = 20_000_000
    private static let ms: UInt64 = 1_000_000

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_041,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    /// A constant client−host clock offset for synthetic arrivals (the
    /// domains genuinely differ live; only differences may matter).
    private static let clockOffsetMicros: UInt64 = 9_000_000_000

    private func makeEstimator(
        _ tweak: (inout RateEstimatorConfig) -> Void = { _ in }
    ) -> RateEstimator {
        var config = RateEstimatorConfig(
            ceilingBitsPerSecond: Self.ceiling
        )
        tweak(&config)
        return RateEstimator(config: config, now: 0)
    }

    /// Records one back-to-back train of `count` video datagrams in the
    /// ledger starting at `sendStartNS`, and returns the dispersion
    /// samples for arrivals paced at `bottleneckBitsPerSecond` plus
    /// `extraDelayMicros` of standing queue.
    private func train(
        _ estimator: RateEstimator,
        seqStart: Int,
        count: Int,
        bytes: Int = 1_152,
        channel: ChannelId = .videoActive,
        frameNumber: UInt32 = 0,
        sendStartNS: UInt64,
        sendSpacingNS: UInt64 = 500_000,
        bottleneckBitsPerSecond: Double,
        extraDelayMicros: UInt64 = 0
    ) -> [FeedbackReport.Dispersion.Sample] {
        let arrivalSpacing = Double(bytes) * 8 / bottleneckBitsPerSecond * 1e6
        var samples: [FeedbackReport.Dispersion.Sample] = []
        for i in 0..<count {
            let sendNS = sendStartNS + UInt64(i) * sendSpacingNS
            let seq = ChannelSeq(rawValue: UInt16(truncatingIfNeeded: seqStart + i))
            estimator.noteSent(
                channel: channel, seq: seq, bytes: bytes, now: sendNS,
                deliveryFrame: channel == .videoActive
                    ? FrameNumber(rawValue: frameNumber) : nil
            )
            let arrival = Self.clockOffsetMicros
                + sendStartNS / 1_000
                + UInt64(Double(i) * arrivalSpacing)
                + extraDelayMicros
            samples.append(FeedbackReport.Dispersion.Sample(
                channel: channel, seq: seq,
                arrivalDeltaMicroseconds: 0 // fixed up by report(at:)
            ))
            arrivals.append(arrival)
        }
        return samples
    }

    /// Scratch arrivals matching the samples `train` returned, in order.
    private var arrivals: [UInt64] = []

    /// Builds a report whose dispersion carries the accumulated
    /// arrivals; clears the scratch.
    private func report(
        samples: [FeedbackReport.Dispersion.Sample],
        clientMicros: UInt64,
        channels: [FeedbackReport.ChannelStats] = [],
        nacks: [FeedbackReport.NackEntry] = []
    ) -> FeedbackReport {
        defer { arrivals.removeAll() }
        guard !samples.isEmpty else {
            return FeedbackReport(
                clientTimestamp: ClientTimestamp(microseconds: clientMicros),
                channels: channels,
                nacks: nacks
            )
        }
        let base = arrivals.min()!
        let fixed = zip(samples, arrivals).map { sample, arrival in
            FeedbackReport.Dispersion.Sample(
                channel: sample.channel, seq: sample.seq,
                arrivalDeltaMicroseconds: UInt32(arrival - base)
            )
        }
        return FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: clientMicros),
            channels: channels,
            dispersion: FeedbackReport.Dispersion(
                base: ClientTimestamp(microseconds: base), samples: fixed
            ),
            nacks: nacks
        )
    }

    private func lossLedger(
        received: UInt32, missing: UInt32
    ) -> [FeedbackReport.ChannelStats] {
        [FeedbackReport.ChannelStats(
            channel: .videoActive,
            highestSeq: ChannelSeq(rawValue: 0),
            received: received, missing: missing, duplicates: 0
        )]
    }

    // MARK: - Delivery rate is measured, not hoped

    func testDeliveryRateMeasuredFromDispersionTrains() {
        let estimator = makeEstimator()
        // 40 shards sent back-to-back; the path delivers them at
        // 8 Mbps — the arrival spacing IS the bottleneck.
        let samples = train(
            estimator, seqStart: 0, count: 40,
            sendStartNS: 10 * Self.ms,
            bottleneckBitsPerSecond: 8e6
        )
        let verdict = estimator.ingest(
            report(samples: samples, clientMicros: 50_000),
            now: 60 * Self.ms, inRecovery: false
        )
        XCTAssertNil(verdict.newRateBitsPerSecond,
                     """
                         one clean report must not move the standing rate \
                         already at the ceiling
                         """)
        let measured = estimator.deliveryRateBitsPerSecond
        XCTAssertNotNil(measured)
        XCTAssertEqual(Double(measured!), 8e6, accuracy: 0.4e6,
                       "delivery rate must read the arrival spacing")
        XCTAssertEqual(estimator.stats.deliverySamples, 1)
        XCTAssertEqual(estimator.stats.dispersionSamplesMatched, 40)
    }

    // MARK: - The stretched-train guard

    func testHoleDominatedTrainIsRecusedFromTheHonestVote() {
        // A radio hole inside a train, in virtual time: 12 shards
        // sent back-to-back at the 20 Mbps pace; the first five arrive
        // tight (200 µs apart), a 150 ms radio hole opens, the rest
        // arrive tight behind it. The span reads ~0.7 Mbps — "honest"
        // by the pace margin — but the span IS the hole (max gap ≈ 99%
        // of it). Such a reading must keep its delivery-window role
        // and lose its vote: no honest sample, one recusal.
        let estimator = makeEstimator()
        var samples: [FeedbackReport.Dispersion.Sample] = []
        for i in 0..<12 {
            let seq = ChannelSeq(rawValue: UInt16(i))
            estimator.noteSent(
                channel: .videoActive, seq: seq, bytes: 1_152,
                now: 10 * Self.ms + UInt64(i) * 500_000
            )
            let tight = UInt64(i) * 200
            let hole: UInt64 = i >= 5 ? 150_000 : 0
            arrivals.append(
                Self.clockOffsetMicros + 10_000 + tight + hole)
            samples.append(FeedbackReport.Dispersion.Sample(
                channel: .videoActive, seq: seq,
                arrivalDeltaMicroseconds: 0
            ))
        }
        _ = estimator.ingest(
            report(samples: samples, clientMicros: 200_000),
            now: 200 * Self.ms, inRecovery: false
        )
        XCTAssertEqual(estimator.stats.stretchedTrainsRecused, 1)
        XCTAssertEqual(estimator.stats.honestSamples, 0,
                       "a hole reading must not enter the honest median")
        XCTAssertEqual(estimator.stats.deliverySamples, 1,
                       "the sample still feeds the delivery window")
    }

    func testUniformlySlowTrainStillVotesHonest() {
        // The guard's other edge: a genuinely slow path stretches every
        // gap alike (max gap ≈ 1/(n−1) of the span) — that reading is
        // the truth about the path and MUST keep its vote, or the
        // guard would blind real squeezes.
        let estimator = makeEstimator()
        let samples = train(
            estimator, seqStart: 0, count: 12,
            sendStartNS: 10 * Self.ms,
            bottleneckBitsPerSecond: 5e6
        )
        _ = estimator.ingest(
            report(samples: samples, clientMicros: 50_000),
            now: 60 * Self.ms, inRecovery: false
        )
        XCTAssertEqual(estimator.stats.honestSamples, 1,
                       "a uniformly stretched train speaks for the path")
        XCTAssertEqual(estimator.stats.stretchedTrainsRecused, 0)
    }

    func testSingleSocketBurstCannotDemoteCapacityBelief() {
        let estimator = makeEstimator()
        let seed = train(
            estimator, seqStart: 0, count: 12,
            sendStartNS: 10 * Self.ms,
            bottleneckBitsPerSecond: 20e6
        )
        _ = estimator.ingest(
            report(samples: seed, clientMicros: 30_000),
            now: 30 * Self.ms, inRecovery: false
        )
        // One sendmmsg acceptance gives every datagram the same actual-send
        // timestamp. Arrival serialization at 7 Mbps is a microburst service
        // reading, not proof that sustained capacity fell from 20 Mbps.
        let samples = train(
            estimator, seqStart: 20, count: 12,
            sendStartNS: 40 * Self.ms, sendSpacingNS: 0,
            bottleneckBitsPerSecond: 7e6
        )
        _ = estimator.ingest(
            report(samples: samples, clientMicros: 50_000),
            now: 60 * Self.ms, inRecovery: false
        )
        XCTAssertEqual(estimator.stats.honestSamples, 0)
        XCTAssertEqual(estimator.stats.burstGeometryTrainsRecused, 1,
            "one socket batch must not become a sustained-capacity witness")
        XCTAssertEqual(estimator.capacityBeliefBitsPerSecond, 20_000_000,
            "burst geometry may not demote the capacity belief")
    }

    func testShortTrainsAreWeightedDown() {
        let estimator = makeEstimator()
        // A 4-packet train (below the 8-packet confidence bar) measures
        // 8 Mbps — the max filter must see it at half weight.
        let samples = train(
            estimator, seqStart: 0, count: 4,
            sendStartNS: 10 * Self.ms,
            bottleneckBitsPerSecond: 8e6
        )
        _ = estimator.ingest(
            report(samples: samples, clientMicros: 50_000),
            now: 60 * Self.ms, inRecovery: false
        )
        let measured = estimator.deliveryRateBitsPerSecond
        XCTAssertNotNil(measured)
        XCTAssertEqual(Double(measured!), 4e6, accuracy: 0.4e6,
                       "short-train dispersion noise must not win the max")
    }

    func testMixedAudioCadenceCannotManufactureVideoCapacity() {
        let estimator = makeEstimator {
            $0.floorBitsPerSecond = 500_000
            $0.initialRateBitsPerSecond = 500_000
        }
        // Sparse video contributes only two packets: no capacity train.
        // Twelve 131-byte audio packets at their fixed 5 ms source
        // cadence interleave across the same 55 ms. The old channel-
        // blind segmentation chained all fourteen into one "full" train
        // and manufactured a sub-floor path estimate; even merely
        // splitting channels would still mistake audio's application
        // cadence (~210 kbps) for path capacity.
        let video = train(
            estimator, seqStart: 0, count: 2,
            sendStartNS: 10 * Self.ms, sendSpacingNS: 55 * Self.ms,
            bottleneckBitsPerSecond: 100e6
        )
        let audio = train(
            estimator, seqStart: 100, count: 12, bytes: 131,
            channel: .audio, sendStartNS: 10 * Self.ms,
            sendSpacingNS: 5 * Self.ms,
            bottleneckBitsPerSecond: 100e6
        )
        _ = estimator.ingest(
            report(samples: video + audio, clientMicros: 100_000),
            now: 100 * Self.ms, inRecovery: false
        )
        XCTAssertNil(estimator.deliveryRateBitsPerSecond,
            "fixed-cadence audio and sparse video are not a capacity probe")
        XCTAssertNil(estimator.capacityBeliefBitsPerSecond)
        XCTAssertEqual(estimator.stats.deliverySamples, 0)
        XCTAssertEqual(estimator.stats.dispersionSamplesMatched, 14,
            "audio remains matched for per-channel delay evidence")
    }

    func testSeparateSixtyFpsVideoFramesNeverChainAtTheFloor() {
        let estimator = makeEstimator {
            $0.floorBitsPerSecond = 500_000
            $0.initialRateBitsPerSecond = 500_000
        }
        var samples: [FeedbackReport.Dispersion.Sample] = []
        // Six sparse two-shard frame flights, one every 16.7 ms. The
        // floor's rate-scaled gap is ~55 ms, so spacing alone chained
        // all twelve into a "full" train. Frame identity must close each
        // two-packet flight before minTrainPackets can be manufactured.
        for frame in 0..<6 {
            samples += train(
                estimator, seqStart: frame * 10, count: 2,
                frameNumber: UInt32(frame),
                sendStartNS: 10 * Self.ms
                    + UInt64(frame) * 16_666_667,
                bottleneckBitsPerSecond: 100e6
            )
        }
        _ = estimator.ingest(
            report(samples: samples, clientMicros: 120_000),
            now: 120 * Self.ms, inRecovery: false
        )
        XCTAssertNil(estimator.deliveryRateBitsPerSecond)
        XCTAssertNil(estimator.capacityBeliefBitsPerSecond)
        XCTAssertEqual(estimator.stats.deliverySamples, 0)
    }

    func testSameFrameLowRateShardsRemainOneTrain() {
        let estimator = makeEstimator {
            $0.floorBitsPerSecond = 500_000
            $0.initialRateBitsPerSecond = 500_000
        }
        let samples = train(
            estimator, seqStart: 0, count: 4, frameNumber: 77,
            sendStartNS: 10 * Self.ms, sendSpacingNS: 18_400_000,
            bottleneckBitsPerSecond: 500e3
        )
        _ = estimator.ingest(
            report(samples: samples, clientMicros: 100_000),
            now: 100 * Self.ms, inRecovery: false
        )
        XCTAssertEqual(estimator.stats.deliverySamples, 1)
        XCTAssertEqual(
            Double(estimator.deliveryRateBitsPerSecond ?? 0),
            250e3, accuracy: 30e3,
            """
                the four-packet same-frame train stays intact and keeps \
                the existing short-train ×0.5 weighting
                """
        )
    }

    func testCrossFrameBacklogCannotTriggerFalseFallOrChurn() {
        let estimator = makeEstimator()
        var now = 20 * Self.ms
        var seq = 0

        // Establish a healthy 20 Mbps belief from one real frame flight.
        let seed = train(
            estimator, seqStart: seq, count: 12, frameNumber: 1,
            sendStartNS: 10 * Self.ms,
            bottleneckBitsPerSecond: 20e6
        )
        seq += 12
        _ = estimator.ingest(
            report(samples: seed, clientMicros: 20_000),
            now: now, inRecovery: false
        )
        let downshiftsBefore = estimator.stats.downshifts

        func multiFrameBeat(extraDelayMicros: UInt64) -> RateEstimatorVerdict {
            var samples: [FeedbackReport.Dispersion.Sample] = []
            // Standing backlog drains continuously, but packet pairs
            // still belong to six distinct source frames. Without the
            // identity boundary this becomes one 12-packet ~14 Mbps
            // honest vote under a 20 Mbps pace.
            let sendBase = now - 10 * Self.ms
            for frame in 0..<6 {
                samples += train(
                    estimator, seqStart: seq, count: 2,
                    frameNumber: UInt32(100 + frame),
                    sendStartNS: sendBase + UInt64(frame) * 1_200_000,
                    bottleneckBitsPerSecond: 5e6,
                    extraDelayMicros: extraDelayMicros
                )
                seq += 2
            }
            let verdict = estimator.ingest(
                report(samples: samples, clientMicros: now / 1_000),
                now: now, inRecovery: false,
                pacerBacklogBytes: 100_000
            )
            now += 300 * Self.ms
            return verdict
        }

        _ = multiFrameBeat(extraDelayMicros: 0)
        _ = multiFrameBeat(extraDelayMicros: 0)
        for _ in 0..<5 {
            let verdict = multiFrameBeat(extraDelayMicros: 40_000)
            XCTAssertNil(verdict.newRateBitsPerSecond,
                "cross-frame source cadence supplied a false honest fall")
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)
        XCTAssertEqual(estimator.stats.downshifts, downshiftsBefore)
        XCTAssertGreaterThanOrEqual(estimator.stats.selfReferenceHolds, 1,
            """
                persisted delay with backlog and no frame-local witness \
                must hold as self-explaining, not churn
                """)
    }

    /// Q-1, the receipts fix: a receiver radio that drains a queued
    /// dwell in one compressed burst hands the windowed-MAX filter a
    /// legitimate super-rate full train (the quality probe's summary
    /// printed 272–777 Mbps "delivery" on a ~90 Mbps wire). The
    /// control law keeps its burst-tolerant max, but the REPORTED
    /// delivery figure is the full-train median — one burst sample
    /// stays outvoted and the receipts read the path, not the drain.
    func testReportedDeliveryOutvotesClumpedBurstSample() {
        let estimator = makeEstimator()
        for (i, bottleneck) in [8e6, 8e6, 400e6].enumerated() {
            let samples = train(
                estimator, seqStart: i * 100, count: 40,
                sendStartNS: UInt64(10 + 100 * i) * Self.ms,
                bottleneckBitsPerSecond: bottleneck
            )
            _ = estimator.ingest(
                report(samples: samples,
                       clientMicros: UInt64(50_000 + 100_000 * i)),
                now: UInt64(60 + 100 * i) * Self.ms, inRecovery: false
            )
        }
        XCTAssertEqual(estimator.stats.deliverySamples, 3)
        let burstMax = estimator.deliveryRateBitsPerSecond
        XCTAssertNotNil(burstMax)
        XCTAssertGreaterThan(burstMax!, 100_000_000,
                             """
                                 the max window keeps the burst sample — \
                                 the control law's probe is untouched
                                 """)
        let reported = estimator.measuredDeliveryRateBitsPerSecond
        XCTAssertNotNil(reported)
        XCTAssertEqual(Double(reported!), 8e6, accuracy: 0.4e6,
                       """
                           the reported delivery is the full-train median \
                           — a lone clumped burst cannot print as the \
                           session's delivery rate
                           """)
    }

    func testUnmatchedSamplesAreIgnoredNotInvented() {
        let estimator = makeEstimator()
        // Samples naming datagrams the ledger never saw (a client
        // fabricating seqs, or ledger eviction): counted, ignored.
        let samples = (0..<10).map {
            FeedbackReport.Dispersion.Sample(
                channel: .videoActive,
                seq: ChannelSeq(rawValue: UInt16(1_000 + $0)),
                arrivalDeltaMicroseconds: UInt32($0 * 1_000)
            )
        }
        let bogus = FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: 1_000),
            dispersion: FeedbackReport.Dispersion(
                base: ClientTimestamp(microseconds: 1_000), samples: samples
            )
        )
        _ = estimator.ingest(bogus, now: 10 * Self.ms, inRecovery: false)
        XCTAssertNil(estimator.deliveryRateBitsPerSecond)
        XCTAssertEqual(estimator.stats.dispersionSamplesUnmatched, 10)
        XCTAssertEqual(estimator.stats.deliverySamples, 0)
    }

    // MARK: - Falls fast on loss, floors, re-rises on evidence

    func testLossBurstFallsMultiplicativelyAndReconverges() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)
        var received: UInt32 = 0
        var missing: UInt32 = 0

        func beat(lossPerHundred: UInt32) -> RateEstimatorVerdict {
            received += 100 - lossPerHundred
            missing += lossPerHundred
            return driver.beat(
                bottleneckMbps: 18,
                channels: lossLedger(received: received, missing: missing))
        }

        // Prime: the first ledger report only establishes totals.
        _ = beat(lossPerHundred: 0)
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        // 5% loss is FEC's band (2–10%): the rate HOLDS — no fall, no
        // rise (resiliency G1: a 5% uniform path keeps streaming).
        for _ in 0..<40 {
            XCTAssertNil(beat(lossPerHundred: 5).newRateBitsPerSecond,
                         "2–10% pre-FEC loss is FEC's to absorb — hold")
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)
        // Drain the loss window before the burst leg.
        for _ in 0..<45 { _ = beat(lossPerHundred: 0) }

        // A 20% burst, 2 s: over the downshift band — ×(1 − loss/2)
        // per 500 ms-limited fall (GCC's loss response). The rolling
        // window needs ~0.5 s of burst before the fraction crosses
        // 10%, then falls land every 500 ms while it stays there.
        var downshiftRates: [Int] = []
        var priorRates: [Int] = []
        for _ in 0..<80 { // 2 s of lossy 25 ms reports
            let before = estimator.rateBitsPerSecond
            if let rate = beat(lossPerHundred: 20).newRateBitsPerSecond {
                downshiftRates.append(rate)
                priorRates.append(before)
            }
        }
        XCTAssertGreaterThanOrEqual(downshiftRates.count, 2,
                       "a sustained 20% burst must fall repeatedly")
        XCTAssertLessThanOrEqual(downshiftRates.count, 4,
                       "the 500 ms limiter bounds falls in a 2 s burst")
        for (rate, prior) in zip(downshiftRates, priorRates) {
            XCTAssertLessThanOrEqual(Double(rate), Double(prior) * 0.95,
                "every fall is multiplicative (≥5% at a >10% window)")
        }
        XCTAssertLessThanOrEqual(estimator.rateBitsPerSecond,
                                 Int(Double(Self.ceiling) * 0.85))

        // Clean again. The rolling 1 s loss window honestly keeps the
        // fraction over threshold for its tail — up to two more
        // rate-limited falls — then the hold-down passes and the rate
        // climbs ≤10%/s on delivery evidence.
        var lastRate = estimator.rateBitsPerSecond
        var crashFloor = lastRate
        var sawClimb = false
        for i in 0..<200 { // 5 s of clean reports
            let before = lastRate
            if let rate = beat(lossPerHundred: 0).newRateBitsPerSecond {
                if rate < before {
                    XCTAssertLessThan(i, 40,
                        """
                            falls after the 1 s loss window drained \
                            would be invented loss
                            """)
                } else {
                    XCTAssertLessThanOrEqual(
                        Double(rate), Double(before) * 1.011,
                        "one 25 ms beat must climb ≤ ~10%/s")
                    sawClimb = true
                }
                lastRate = rate
                crashFloor = min(crashFloor, rate)
            }
        }
        XCTAssertTrue(sawClimb, "the rate must re-rise on clean evidence")
        XCTAssertGreaterThan(lastRate, crashFloor)
        XCTAssertLessThanOrEqual(lastRate, Self.ceiling)
        XCTAssertGreaterThanOrEqual(estimator.stats.lossDownshifts, 2)
    }

    /// The floor deadlock: at 500 kbps the pacer
    /// spaces full-size datagrams ~18 ms apart, so a FIXED train-split
    /// gap never sees a train, no delivery sample ever forms, and the
    /// rate can never earn its way back up. The gap must scale with
    /// the standing rate so paced-at-R spacing still reads as a train.
    func testClimbsBackFromTheFloorOnPacedEvidence() {
        let estimator = makeEstimator {
            // Retain the historical low-rate train-classification pin
            // below production's now-viable operational floor.
            $0.floorBitsPerSecond = 500_000
        }
        // Crash to the floor.
        for _ in 0..<8 {
            _ = estimator.applyIdrPacing(.halfStaleEstimate, now: 0)
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, 500_000)

        // Paced sends at the floor: 1152 B every ~18.4 ms — one train
        // to a rate-scaled gap, invisible to a fixed 2 ms one.
        var now: UInt64 = Self.ms
        var clientMicros: UInt64 = 1_000
        var seq = 0
        var sawUpshift = false
        for _ in 0..<40 {
            now += 60 * Self.ms
            clientMicros += 60_000
            let samples = train(
                estimator, seqStart: seq, count: 4,
                sendStartNS: now - 56 * Self.ms,
                sendSpacingNS: 18_400_000,
                bottleneckBitsPerSecond: 500e3
            )
            seq += 4
            if estimator.ingest(
                report(samples: samples, clientMicros: clientMicros),
                now: now, inRecovery: false
            ).newRateBitsPerSecond != nil {
                sawUpshift = true
            }
        }
        XCTAssertTrue(sawUpshift,
            """
                paced evidence at the floor must still form delivery \
                samples and let the rate climb
                """)
        XCTAssertGreaterThan(estimator.rateBitsPerSecond, 500_000)
    }

    func testRateNeverLeavesTheFloorCeilingBand() {
        let estimator = makeEstimator {
            $0.floorBitsPerSecond = 500_000
        }
        let driver = EstimatorDriver(self, estimator)
        var received: UInt32 = 100
        var missing: UInt32 = 0
        // Relentless 50% loss with paced trains — ledger-only loss no
        // longer moves the rate (sparse-evidence hold); the floor pin
        // still needs honest delivery freshness on every fall beat.
        // ~10 s of 25 ms reports covers ≥ the 500 ms fall limiter's
        // walk from the ceiling to the historical 500 kbps floor.
        for _ in 0..<400 {
            received += 50
            missing += 50
            driver.beat(
                bottleneckMbps: max(0.5, Double(estimator.rateBitsPerSecond) / 1e6),
                channels: lossLedger(received: received, missing: missing)
            )
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, 500_000,
                       "the floor holds — a paced IDR stays possible")
    }

    // MARK: - Queuing-delay inflation is overuse

    func testDelayInflationDownshiftsAnchoredToMeasuredDelivery() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)

        func beat(extraDelayMicros: UInt64) -> RateEstimatorVerdict {
            driver.beat(bottleneckMbps: 10, extraDelayMicros: extraDelayMicros)
        }

        // Baseline: clean delay for ten reports.
        for _ in 0..<10 {
            let verdict = beat(extraDelayMicros: 0)
            XCTAssertFalse(verdict.overuse)
        }
        XCTAssertEqual(estimator.queuingDelayMicroseconds, 0)

        // The queue grows 25 ms past baseline: the first inflated
        // report arms, the second fires the overuse verdict — which
        // the dwell deferral holds (loss-clean, inside the stall
        // ceiling: a drain would exonerate) until its ≤150 ms budget
        // expires — and the fall then lands anchored to 0.85 × the
        // measured delivery rate.
        XCTAssertFalse(beat(extraDelayMicros: 25_000).overuse,
                       "one inflated report must not fire (2 consecutive)")
        var verdict = beat(extraDelayMicros: 25_000)
        XCTAssertTrue(verdict.overuse)
        XCTAssertNil(verdict.newRateBitsPerSecond,
                     "the dwell deferral holds a dwell-shaped fall first")
        var deferredBeats = 0
        while verdict.newRateBitsPerSecond == nil, deferredBeats < 30 {
            verdict = beat(extraDelayMicros: 25_000)
            deferredBeats += 1
        }
        XCTAssertGreaterThanOrEqual(estimator.stats.fallDeferrals, 1)
        XCTAssertTrue(verdict.overuse)
        let newRate = verdict.newRateBitsPerSecond
        XCTAssertNotNil(newRate)
        XCTAssertEqual(verdict.change, .overuse)
        XCTAssertEqual(Double(newRate!), 10e6 * 0.85, accuracy: 0.6e6,
                       """
                           the overuse fall anchors to measured delivery, \
                           not to the configured rate
                           """)
        XCTAssertGreaterThanOrEqual(
            estimator.queuingDelayMicroseconds ?? 0, 20_000
        )
    }

    // MARK: - The baseline witness rule
    // The rolling delay floor is the lowest CORROBORATED report
    // minimum: one anomalously-fast report is a witness awaiting its
    // partner, never the baseline itself.

    /// A steady path whose delay floor sits 25 ms above nominal; ONE
    /// freak report arrives 25 ms fast (the lucky receive wake). The
    /// old raw-min baseline adopted it and read every later report as
    /// inflated — ~20 uncorroborated fall beats on a clean path. The
    /// witness rule shrugs it off: no overuse, rate never moves.
    func testLoneFastReportDoesNotPoisonTheDelayBaseline() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)

        func beat(extraDelayMicros: UInt64) -> RateEstimatorVerdict {
            driver.beat(bottleneckMbps: 10, extraDelayMicros: extraDelayMicros)
        }

        for _ in 0..<10 {
            XCTAssertFalse(beat(extraDelayMicros: 25_000).overuse)
        }
        // The freak: a whole report 25 ms faster than the standing
        // floor. Its own inflation is zero (it IS the new minimum),
        // and under the witness rule it must not become the baseline.
        XCTAssertFalse(beat(extraDelayMicros: 0).overuse)
        // Ten more reports at the standing floor: with a poisoned
        // baseline every one reads 25 ms inflated and the second
        // fires; the witness rule keeps them all quiet.
        for _ in 0..<10 {
            let verdict = beat(extraDelayMicros: 25_000)
            XCTAssertFalse(verdict.overuse,
                           "a lone fast report must not poison the floor")
            XCTAssertNil(verdict.newRateBitsPerSecond)
        }
        XCTAssertLessThanOrEqual(
            estimator.queuingDelayMicroseconds ?? 0, 1_000
        )
    }

    /// The control: TWO fast reports are corroboration — the floor
    /// re-baselines (one report later than the raw min did), and a
    /// path that then returns to the old delay genuinely reads
    /// inflated. Improvements still count; only loners don't.
    func testCorroboratedFasterFloorRebaselines() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)

        func beat(extraDelayMicros: UInt64) -> RateEstimatorVerdict {
            driver.beat(bottleneckMbps: 10, extraDelayMicros: extraDelayMicros)
        }

        for _ in 0..<10 {
            XCTAssertFalse(beat(extraDelayMicros: 25_000).overuse)
        }
        // Two witnesses: the improvement is real and the floor adopts it.
        XCTAssertFalse(beat(extraDelayMicros: 0).overuse)
        XCTAssertFalse(beat(extraDelayMicros: 0).overuse)
        // Back at the old delay: against the re-based floor this is
        // genuine 25 ms inflation — the second consecutive report
        // fires the overuse verdict.
        XCTAssertFalse(beat(extraDelayMicros: 25_000).overuse,
                       "one inflated report must not fire (2 consecutive)")
        XCTAssertTrue(beat(extraDelayMicros: 25_000).overuse,
                      "the corroborated floor must make real inflation visible")
    }

    // MARK: - The overuse anchor is a median
    // The anchor is the MEDIAN of the last few full-train samples, so
    // the freshest sample cannot decide the fall alone.

    /// The regression pin: a GENUINE sustained overuse — delivery truly
    /// drops to ~5 Mbps for the whole run — still falls fast and anchors
    /// to the measured delivery, exactly as the one-deep anchor did. By
    /// the time overuse fires (two consecutive inflated reports), two
    /// recent 5 Mbps samples already dominate the 3-median.
    func testGenuineSustainedOveruseStillFallsToMeasuredDelivery() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)

        func beat(mbps: Double, inflate: Bool) -> RateEstimatorVerdict {
            driver.beat(
                bottleneckMbps: mbps, extraDelayMicros: inflate ? 40_000 : 0)
        }

        // Baseline clean at the full 20 Mbps.
        for _ in 0..<10 { _ = beat(mbps: 20, inflate: false) }
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        // The squeeze: delivery genuinely drops to ~5 Mbps and the
        // queue inflates. Arm; the dwell deferral holds the loss-clean
        // bounded-peak beats until its ≤150 ms budget expires (the
        // honesty cost on a genuine squeeze that mimics a dwell); fire.
        XCTAssertFalse(beat(mbps: 5, inflate: true).overuse)
        var first = beat(mbps: 5, inflate: true)
        var deferredBeats = 0
        while first.newRateBitsPerSecond == nil, deferredBeats < 30 {
            XCTAssertTrue(first.overuse)
            first = beat(mbps: 5, inflate: true)
            deferredBeats += 1
        }
        XCTAssertTrue(first.overuse)
        XCTAssertEqual(first.change, .overuse)
        XCTAssertNotNil(first.newRateBitsPerSecond)
        XCTAssertEqual(Double(first.newRateBitsPerSecond!), 5e6 * 0.85,
            accuracy: 1.0e6,
            """
                genuine sustained overuse still anchors to the 5 Mbps the \
                path measurably delivers — the fast fall is intact
                """)

        // Sustained: it keeps falling under continued overuse (the
        // 500 ms limiter bounds cadence), never blunted by the median.
        var falls = 1
        for _ in 0..<80 where beat(mbps: 5, inflate: true)
            .newRateBitsPerSecond != nil { falls += 1 }
        XCTAssertGreaterThanOrEqual(falls, 2,
            "sustained overuse falls repeatedly")
        XCTAssertLessThanOrEqual(estimator.rateBitsPerSecond,
            Int(5e6 * 0.85) + 500_000,
            "the rate tracks the measured delivery down under the squeeze")
    }

    // MARK: - Only full trains vote on the anchor
    // Audio's 4+2 groups arrive as 2–3-packet micro-trains that measure
    // their own ~1 Mbps pacing, not the path. Short trains keep feeding
    // the ×0.5 windowed-max and evidence freshness; they get no anchor
    // vote.

    /// A clean 20 Mbps path, but the reports leading into the overuse
    /// fire carry only short audio-paced micro-trains: a MAJORITY of
    /// the anchor window would be garbage under a median alone. The fall
    /// must still anchor to the 20 Mbps the last full train measured.
    func testOveruseAnchorIgnoresMicroTrainMajority() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        // Ten clean 20 Mbps FULL trains: rate at the ceiling, anchor
        // window full of genuine samples.
        for _ in 0..<10 {
            now += 25 * Self.ms
            clientMicros += 25_000
            let samples = train(
                estimator, seqStart: seq, count: 12,
                sendStartNS: now - Self.ms,
                bottleneckBitsPerSecond: 20e6
            )
            seq += 12
            _ = estimator.ingest(
                report(samples: samples, clientMicros: clientMicros),
                now: now, inRecovery: false
            )
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        // Arm and fire on inflated reports whose ONLY delivery samples
        // are 4-packet micro-trains reading ~1 Mbps (the audio class
        // measuring its own pacing). Under a median alone the
        // window at fire time would hold [20M, 1M, 1M] — median 1 Mbps,
        // a crater to ~850 kbps. With the full-train gate the window
        // still holds the genuine 20 Mbps samples.
        now += 25 * Self.ms; clientMicros += 25_000
        let arm = train(
            estimator, seqStart: seq, count: 4,
            sendStartNS: now - Self.ms,
            bottleneckBitsPerSecond: 1e6, extraDelayMicros: 40_000
        )
        seq += 4
        XCTAssertFalse(estimator.ingest(
            report(samples: arm, clientMicros: clientMicros),
            now: now, inRecovery: false
        ).overuse)

        // The dwell deferral holds the dwell-shaped beats; the fall
        // bites on a micro-train report once the budget expires.
        var verdict: RateEstimatorVerdict
        var deferredBeats = 0
        repeat {
            now += 25 * Self.ms; clientMicros += 25_000
            let fire = train(
                estimator, seqStart: seq, count: 4,
                sendStartNS: now - Self.ms,
                bottleneckBitsPerSecond: 1e6, extraDelayMicros: 40_000
            )
            seq += 4
            verdict = estimator.ingest(
                report(samples: fire, clientMicros: clientMicros),
                now: now, inRecovery: false
            )
            deferredBeats += 1
        } while verdict.newRateBitsPerSecond == nil && deferredBeats < 30
        XCTAssertTrue(verdict.overuse)
        let newRate = verdict.newRateBitsPerSecond
        XCTAssertNotNil(newRate)
        XCTAssertEqual(Double(newRate!), 20e6 * 0.85, accuracy: 1.0e6,
            """
                a micro-train MAJORITY must not crater the rate — the \
                anchor votes are full trains only \
                (got \(newRate! / 1_000) kbps)
                """)
    }

    // MARK: - The self-reference gate
    // Under a squeezed pacer every multi-quantum frame drains as one
    // ≥8-packet train paced at exactly the standing rate — a FULL train
    // that measures our own pacing, not the path; a fall anchored on it
    // re-squeezes the pacer and spirals to the floor. With standing
    // backlog and an
    // anchor at ≈ (or above) the standing rate, an overuse verdict may
    // HOLD the rate (rises stay blocked), never anchor a fall — unless
    // corroborated by something a self-limited pacer cannot produce:
    // loss, post-FEC evidence, or queue growth across the streak.

    /// One simulated feedback cadence against an estimator: each beat
    /// advances the host and client clocks 25 ms, sends one 12-shard train
    /// paced at the bottleneck (plus any standing queue delay), and
    /// ingests the client's report — optionally with channel ledgers,
    /// NACKs, and the pacer backlog the host reports alongside.
    private final class EstimatorDriver {
        let estimator: RateEstimator
        private unowned let test: RateEstimatorGateTests
        var now: UInt64
        var clientMicros: UInt64
        var seq: Int

        init(
            _ test: RateEstimatorGateTests, _ estimator: RateEstimator,
            now: UInt64 = 0, clientMicros: UInt64 = 0, seq: Int = 0
        ) {
            self.test = test
            self.estimator = estimator
            self.now = now
            self.clientMicros = clientMicros
            self.seq = seq
        }

        @discardableResult
        func beat(
            bottleneckMbps: Double, extraDelayMicros: UInt64 = 0,
            backlogBytes: Int = 0,
            channels: [FeedbackReport.ChannelStats] = [],
            nacks: [FeedbackReport.NackEntry] = []
        ) -> RateEstimatorVerdict {
            now += 25 * RateEstimatorGateTests.ms
            clientMicros += 25_000
            let samples = test.train(
                estimator, seqStart: seq, count: 12,
                sendStartNS: now - RateEstimatorGateTests.ms,
                bottleneckBitsPerSecond: bottleneckMbps * 1e6,
                extraDelayMicros: extraDelayMicros
            )
            seq += 12
            return estimator.ingest(
                test.report(samples: samples, clientMicros: clientMicros,
                            channels: channels, nacks: nacks),
                now: now, inRecovery: false,
                pacerBacklogBytes: backlogBytes
            )
        }

        /// A beat whose report never reaches the host: the clocks move,
        /// nothing is sent or ingested.
        func loseReport() {
            now += 25 * RateEstimatorGateTests.ms
            clientMicros += 25_000
        }

        /// Clean beats at `bottleneckMbps`: the rate at the ceiling and
        /// the anchor window and delay baseline filled.
        func prime(bottleneckMbps: Double = 20, beats: Int = 10) {
            for _ in 0..<beats { beat(bottleneckMbps: bottleneckMbps) }
        }

        /// Repeats one beat shape until the rate moves, at most `limit`
        /// beats; returns the last verdict.
        func beatUntilFall(
            bottleneckMbps: Double, extraDelayMicros: UInt64,
            backlogBytes: Int = 0, limit: Int = 30
        ) -> RateEstimatorVerdict {
            var verdict: RateEstimatorVerdict
            var beats = 0
            repeat {
                verdict = beat(
                    bottleneckMbps: bottleneckMbps,
                    extraDelayMicros: extraDelayMicros,
                    backlogBytes: backlogBytes
                )
                beats += 1
            } while verdict.newRateBitsPerSecond == nil && beats <= limit
            return verdict
        }
    }

    /// Standing backlog, full trains measuring
    /// exactly the standing 20 Mbps, constant (non-growing) inflation,
    /// zero loss — the probe's floor-crash shape. A whole second of
    /// overuse verdicts must not move the rate ONCE: every fall is a
    /// self-reference hold, and the spiral (0.85ⁿ to the floor, which
    /// the old law walked within these same beats) is dead.
    func testSelfReferentialOveruseHoldsInsteadOfSpiraling() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)

        // Ten clean 20 Mbps trains: baseline delay, anchor window full
        // of ≈standing-rate samples.
        driver.prime()
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        // 40 beats (1 s) of inflated reports with standing backlog:
        // the trains still measure our own 20 Mbps pacing, inflation
        // sits flat at 40 ms (a burst bump, not a building queue).
        var overuseVerdicts = 0
        for _ in 0..<40 {
            let verdict = driver.beat(
                bottleneckMbps: 20,
                extraDelayMicros: 40_000,
                backlogBytes: 40_000
            )
            if verdict.overuse { overuseVerdicts += 1 }
            XCTAssertNil(verdict.newRateBitsPerSecond,
                "a self-referential overuse verdict must hold, not fall")
        }
        XCTAssertGreaterThanOrEqual(overuseVerdicts, 30,
            """
                the overuse verdicts genuinely fired — the gate held the \
                FALL, not the detector
                """)
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling,
            "the rate never moved — the 500 kbps spiral is dead")
        XCTAssertEqual(estimator.stats.downshifts, 0)
        XCTAssertGreaterThanOrEqual(estimator.stats.selfReferenceHolds, 1)
    }

    /// Real degradation whose capacity sits AT the standing rate: the
    /// anchor is self-shaped, but the queue GROWS across the streak —
    /// the deficit signature a self-limited pacer cannot produce. The
    /// fall must proceed, one report after the growth clears the
    /// threshold (inside the same 500 ms fall-limiter window).
    func testQueueGrowthCorroboratesARealSqueezeNearTheRate() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)

        driver.prime()

        // The streak opens at 25 ms of inflation…
        XCTAssertNil(driver.beat(
            bottleneckMbps: 20,
            extraDelayMicros: 25_000,
            backlogBytes: 40_000
        ).newRateBitsPerSecond)
        // …the second report shows the queue BUILT another 20 ms
        // (past the 15 ms overuse threshold): corroborated, but still
        // dwell-SHAPED (rising dwells mimic growth), so the deferral
        // holds while its budget lasts — and the queue keeps building
        // with NO drain, so the fall lands at 0.85 × the standing rate
        // despite the self-shaped anchor.
        var verdict = driver.beat(
            bottleneckMbps: 20,
            extraDelayMicros: 45_000,
            backlogBytes: 40_000
        )
        var extraDelay: UInt64 = 45_000
        var deferredBeats = 0
        while verdict.newRateBitsPerSecond == nil, deferredBeats < 30 {
            extraDelay += 3_000 // keeps growing, stays under the ceiling
            verdict = driver.beat(
                bottleneckMbps: 20,
                extraDelayMicros: extraDelay,
                backlogBytes: 40_000
            )
            deferredBeats += 1
        }
        XCTAssertTrue(verdict.overuse)
        XCTAssertEqual(verdict.change, .overuse)
        XCTAssertNotNil(verdict.newRateBitsPerSecond)
        XCTAssertEqual(Double(verdict.newRateBitsPerSecond!), 20e6 * 0.85,
            accuracy: 1.0e6,
            "a growing queue is a real squeeze — the gate must not mask it")
        XCTAssertEqual(estimator.stats.selfReferenceHolds, 0)
    }

    /// Real distress at the standing rate WITH loss: pacing at or under
    /// the path's capacity drops nothing, so any loss corroborates the
    /// fall even when the anchor is self-shaped and inflation is flat.
    func testLossCorroboratesDespiteSelfShapedAnchor() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)
        var received: UInt32 = 0
        var missing: UInt32 = 0

        for _ in 0..<10 {
            received += 100
            driver.beat(
                bottleneckMbps: 20,
                channels: lossLedger(received: received, missing: missing)
            )
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        // Two inflated reports, constant 40 ms, but the wire driver.now drops
        // 15 datagrams per beat — ~2.7% over the rolling 1 s window at
        // fire time, past the 2% clean bar (FEC's hold band for the
        // LOSS branch, but honest corroboration for the overuse one).
        received += 85; missing += 15
        XCTAssertNil(driver.beat(
            bottleneckMbps: 20,
            extraDelayMicros: 40_000,
            backlogBytes: 40_000,
            channels: lossLedger(received: received, missing: missing)
        ).newRateBitsPerSecond)
        received += 85; missing += 15
        let verdict = driver.beat(
            bottleneckMbps: 20,
            extraDelayMicros: 40_000,
            backlogBytes: 40_000,
            channels: lossLedger(received: received, missing: missing)
        )
        XCTAssertTrue(verdict.overuse)
        XCTAssertNotNil(verdict.newRateBitsPerSecond,
            "loss on the wire means the path is really hurting — fall")
        XCTAssertEqual(estimator.stats.selfReferenceHolds, 0)
    }

    /// The fast-fall regression pin WITH backlog: a genuine deep dip
    /// stretches every train, the anchor reads honestly low (far below
    /// the self band), and the fall anchors to measured delivery
    /// — standing backlog alone must never
    /// blind the estimator to a path that measurably slowed.
    func testGenuineDipWithBacklogStillFallsToMeasuredDelivery() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)

        driver.prime()

        // The path genuinely drops to 5 Mbps; the pacer (still at 20)
        // holds backlog the whole time. Arm, ride out the dwell
        // deferral's budget (the honesty cost), then fire.
        XCTAssertNil(driver.beat(
            bottleneckMbps: 5,
            extraDelayMicros: 40_000,
            backlogBytes: 40_000
        ).newRateBitsPerSecond)
        let verdict = driver.beatUntilFall(
            bottleneckMbps: 5, extraDelayMicros: 40_000,
            backlogBytes: 40_000
        )
        XCTAssertTrue(verdict.overuse)
        XCTAssertNotNil(verdict.newRateBitsPerSecond)
        XCTAssertEqual(Double(verdict.newRateBitsPerSecond!), 5e6 * 0.85,
            accuracy: 1.0e6,
            """
                an honestly low anchor falls to measured delivery — the \
                gate reads the evidence, it does not read the backlog
                """)
        XCTAssertEqual(estimator.stats.selfReferenceHolds, 0)
    }

    // MARK: - The stall gate
    // A Wi-Fi receiver dwell: the client's radio goes dark 70–100 ms,
    // the AP queues everything, then drains it in one compressed burst —
    // nothing lost, nothing slow, the path merely time-shifted. Host-side
    // that cycle is textbook overuse (two inflated reports, an anchor, a
    // fall twice a second forever). The gate
    // refuses the fall when the evidence spells a CLOSED HOLE: streak
    // peak ≤ 150 ms, a fresh full train at ≥ 1.25 × the standing rate
    // (only accumulated-then-released packets can read above our own
    // pace), and conservation (loss clean, zero post-FEC). Growth does
    // NOT defeat it — rising dwells mimic growth — but a hole past the
    // ceiling, a drain below the pace, or any loss falls as ever.

    /// Repeated sub-150 ms gap-burst cycles — the
    /// scan-stall cadence — must not move the rate ONCE. Each cycle:
    /// two dwell reports (80 ms of held delay, drain measured at
    /// 200 Mbps — far above the 20 Mbps pace), then clean beats.
    func testStallCyclesRideThroughWithoutAnchoringDown() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)

        driver.prime()
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        var overuseVerdicts = 0
        for _ in 0..<10 {
            for _ in 0..<2 {
                let verdict = driver.beat(
                    bottleneckMbps: 200,
                    extraDelayMicros: 80_000
                )
                if verdict.overuse { overuseVerdicts += 1 }
                XCTAssertNil(verdict.newRateBitsPerSecond,
                    "a closed hole must hold the rate, never anchor a fall")
            }
            for _ in 0..<6 {
                driver.beat(bottleneckMbps: 20)
            }
        }
        XCTAssertGreaterThanOrEqual(overuseVerdicts, 10,
            """
                the overuse verdicts genuinely fired — the gate held the \
                FALL, not the detector
                """)
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling,
            "the estimator rode through every stall cycle")
        XCTAssertEqual(estimator.stats.downshifts, 0)
        XCTAssertGreaterThanOrEqual(estimator.stats.stallHolds, 10)
    }

    /// A dwell TRAIN with rising peaks (70 → 90 ms) mimics queue
    /// growth report-to-report — the exact signature the self-reference
    /// gate treats as corroboration. The stall gate must not be
    /// defeated by it: the drain evidence (super-rate full trains) and
    /// the bounded peak are the stronger reading.
    func testRisingDwellTrainHoldsDespiteGrowthSignature() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)

        driver.prime()

        XCTAssertNil(driver.beat(
            bottleneckMbps: 200,
            extraDelayMicros: 70_000
        ).newRateBitsPerSecond)
        // +20 ms past the streak's opening — queueGrew reads true, and
        // without the gate this beat falls.
        let verdict = driver.beat(bottleneckMbps: 200, extraDelayMicros: 90_000)
        XCTAssertTrue(verdict.overuse)
        XCTAssertNil(verdict.newRateBitsPerSecond,
            """
                rising dwells are not a building queue — the drain says \
                the hole closed
                """)
        XCTAssertGreaterThanOrEqual(estimator.stats.stallHolds, 1)
        XCTAssertEqual(estimator.stats.downshifts, 0)
    }

    /// THE RAMP HUNT'S PIN (the dwell deferral): the stall gate's one
    /// blind spot was TIMING. The overuse verdict fires MID-dwell (two
    /// inflated reports, ~80 ms into the hole), but the compressed
    /// super-rate drain that proves the hole closed can only arrive on
    /// the report AFTER it closes — the verdict beat the evidence on
    /// every single dwell. The live books measured the bill: each fall
    /// minted a vbv-tighten + vbv-restore IDR pair, 7.09 IDR/min
    /// against the ≤1/min bar (10 induced dwells → exactly 10 pairs).
    /// A dwell-SHAPED fall (peak inside the stall ceiling, loss clean,
    /// post-FEC clean) is now deferred, report by report, for at most
    /// the stall ceiling's own 150 ms (a dwell is by definition no
    /// longer); the drain then arrives and the stall gate holds as it
    /// was designed to. Genuine squeezes that mimic the shape fall
    /// ≤150 ms later — inside the 500 ms fall limiter's granularity.
    func testFirstDwellFallDeferredUntilTheDrainTestifies() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)

        driver.prime()
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        // Mid-dwell: two inflated reports whose trains still measure
        // our own 20 Mbps pace — the hole has NOT closed, so no
        // super-rate drain exists yet. Pre-deferral, this beat fell.
        XCTAssertNil(driver.beat(
            bottleneckMbps: 20,
            extraDelayMicros: 80_000
        ).newRateBitsPerSecond)
        let midDwell = driver.beat(bottleneckMbps: 20, extraDelayMicros: 80_000)
        XCTAssertTrue(midDwell.overuse)
        XCTAssertNil(midDwell.newRateBitsPerSecond,
            """
                the verdict fired mid-dwell — the deferral holds the fall \
                so the drain can testify
                """)
        XCTAssertGreaterThanOrEqual(estimator.stats.fallDeferrals, 1)

        // The hole closes: the drain arrives compressed at 200 Mbps.
        // The stall gate reads the closed hole and holds as designed.
        let drained = driver.beat(bottleneckMbps: 200, extraDelayMicros: 80_000)
        XCTAssertNil(drained.newRateBitsPerSecond,
            "the drain proves the hole closed — stall hold, no fall")
        XCTAssertGreaterThanOrEqual(estimator.stats.stallHolds, 1)
        XCTAssertEqual(estimator.stats.downshifts, 0)
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling,
            """
                the dwell cost ZERO rate moves — and therefore zero \
                VBV-forced IDRs
                """)
    }

    /// A hole past the 150 ms ceiling is sustained degradation, not a
    /// dwell — the fall proceeds exactly as before the gate existed.
    func testHoleBeyondTheCeilingFallsAsEver() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)

        driver.prime()

        XCTAssertNil(driver.beat(
            bottleneckMbps: 200,
            extraDelayMicros: 400_000
        ).newRateBitsPerSecond)
        // The pressure never clears (a real outage, not a dwell that
        // drains), so invariant 2's persistence is satisfied within
        // one extra fall-limiter beat and the fall bites.
        let verdict = driver.beatUntilFall(
            bottleneckMbps: 200, extraDelayMicros: 400_000
        )
        XCTAssertEqual(verdict.change, .overuse)
        XCTAssertEqual(Double(verdict.newRateBitsPerSecond!),
                       20e6 * 0.85, accuracy: 1.0e6,
            "a 400 ms hole is an outage, not a scan dwell — bite")
        XCTAssertEqual(estimator.stats.stallHolds, 0)
    }

    /// Conservation is the third leg: a gap-burst shape WITH loss is a
    /// congested queue tail-dropping, not a hole that closed — the
    /// fall proceeds despite the bounded peak and the super-rate drain.
    func testLossDefeatsTheStallHold() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)
        var received: UInt32 = 0
        var missing: UInt32 = 0

        for _ in 0..<10 {
            received += 100
            driver.beat(
                bottleneckMbps: 20,
                channels: lossLedger(received: received, missing: missing)
            )
        }

        received += 85; missing += 15
        XCTAssertNil(driver.beat(
            bottleneckMbps: 200,
            extraDelayMicros: 80_000,
            channels: lossLedger(received: received, missing: missing)
        ).newRateBitsPerSecond)
        received += 85; missing += 15
        let verdict = driver.beat(
            bottleneckMbps: 200,
            extraDelayMicros: 80_000,
            channels: lossLedger(received: received, missing: missing)
        )
        XCTAssertTrue(verdict.overuse)
        XCTAssertNotNil(verdict.newRateBitsPerSecond,
            "packets died — the hole did not close, the queue dropped")
        XCTAssertEqual(estimator.stats.stallHolds, 0)
    }

    /// A closed hole ECHOES as a few NACKs: the client's completion
    /// presumption expires mid-dwell, moments before the drain makes
    /// the frame whole. Post-FEC evidence inside the regime ladder's
    /// own clean column (< 0.5%) must not defeat the hold.
    func testNackEchoInsideTheHoleStillHolds() throws {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)
        var received: UInt32 = 0

        for _ in 0..<10 {
            received += 400
            driver.beat(
                bottleneckMbps: 20,
                channels: lossLedger(received: received, missing: 0)
            )
        }

        // The dwell, echoing as one 2-shard NACK: 2 / ~4,800 attempted
        // ≈ 0.04% post-FEC — deep inside the clean column.
        received += 400
        XCTAssertNil(driver.beat(
            bottleneckMbps: 200,
            extraDelayMicros: 80_000,
            channels: lossLedger(received: received, missing: 0),
            nacks: [try FeedbackReport.NackEntry( frame: FrameNumber(rawValue: 7), missingShards: [3, 4] )]
        ).newRateBitsPerSecond)
        received += 400
        let verdict = driver.beat(
            bottleneckMbps: 200,
            extraDelayMicros: 80_000,
            channels: lossLedger(received: received, missing: 0)
        )
        XCTAssertTrue(verdict.overuse)
        XCTAssertNil(verdict.newRateBitsPerSecond,
            """
                a NACK echo inside the clean column is the hole's shadow, \
                not congestion
                """)
        XCTAssertGreaterThanOrEqual(estimator.stats.stallHolds, 1)
    }

    /// Feedback-direction loss: reports are unreliable by design (cumulative ledgers differenced across
    /// whatever arrives), so LOST reports must neither fabricate a
    /// verdict nor mask one. Half the reports of a clean run vanish —
    /// nothing fires; half the reports of a genuine squeeze vanish —
    /// the fall still lands.
    func testLostFeedbackReportsNeitherFabricateNorMask() {
        // Clean run, every other report lost: the surviving reports'
        // counters jump across the gaps (the differencing spans them),
        // arrivals show 50 ms seams — no loss is invented, no overuse
        // fires, no hold or fall moves the rate.
        let clean = EstimatorDriver(self, makeEstimator())
        var received: UInt32 = 0
        for beat in 0..<20 {
            received += 100
            if beat % 2 == 1 { // the odd reports never arrive
                clean.loseReport()
                continue
            }
            let verdict = clean.beat(
                bottleneckMbps: 20,
                channels: lossLedger(received: received, missing: 0)
            )
            XCTAssertFalse(verdict.overuse)
            XCTAssertEqual(verdict.lossFraction, 0, """
                a lost REPORT is not lost PACKETS — the cumulative \
                ledgers span the gap
                """)
        }
        XCTAssertEqual(clean.estimator.rateBitsPerSecond, Self.ceiling)
        XCTAssertEqual(clean.estimator.stats.downshifts, 0)
        XCTAssertEqual(clean.estimator.stats.stallHolds, 0)

        // Genuine squeeze, same 50% report loss: the ingested inflated
        // reports still make the streak and the fall still bites.
        let squeezed = EstimatorDriver(self, makeEstimator())
        for _ in 0..<10 { squeezed.beat(bottleneckMbps: 20) }
        var fell = false
        // Enough ingested beats to arm, ride out the dwell deferral's
        // ≤150 ms budget across the 50 ms report seams, and bite.
        for beat in 0..<32 {
            if beat % 2 == 1 {
                squeezed.loseReport()
                continue
            }
            let verdict = squeezed.beat(
                bottleneckMbps: 8,
                extraDelayMicros: 40_000
            )
            if verdict.newRateBitsPerSecond != nil { fell = true }
        }
        XCTAssertTrue(fell,
            "feedback loss must not launder a genuine squeeze")
        XCTAssertEqual(squeezed.estimator.stats.stallHolds, 0)
    }

    // MARK: - The capacity belief
    // A paced sender can never measure more than it sends — every
    // delivery sample is censored from above by our own rate — so the
    // ledger records the pace at each datagram's release, samples are
    // classified at production (censored / honest / compressed), and the
    // fall anchor answers to the CAPACITY BELIEF: raised by any delivery
    // above it, demoted only by fresh honest evidence. A censored
    // trickle can neither vote in a fall anchor nor age the belief down.

    /// Invariant 1's mechanics: censored samples (measuring ≈ our own
    /// recorded pace) RAISE the belief and never lower it — even a
    /// whole second of censored trickle below the belief leaves it
    /// standing — and the fall anchor then lands on honest evidence
    /// when it exists (demoting the belief to what the path proved).
    func testBeliefRisesOnCensoredDeliveryAndFallsOnlyOnHonestEvidence() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)

        // Ten censored beats at the standing 20 Mbps: the belief
        // rises to what delivery proved; nothing reads honest (the
        // trains measure our own pace).
        driver.prime()
        XCTAssertEqual(
            Double(estimator.capacityBeliefBitsPerSecond ?? 0),
            20e6, accuracy: 2e6
        )
        XCTAssertGreaterThanOrEqual(estimator.stats.censoredSamples, 5)
        XCTAssertEqual(estimator.stats.honestSamples, 0)

        // RECOVERY forces the pacer down to 10 Mbps and explicitly
        // re-anchors stale path belief there. A full second of
        // CENSORED trickle at the new pace follows —
        // with backlog and standing inflation. Invariant 1: after the
        // discontinuity re-anchor, censored samples must not move belief
        // again and no fall may anchor to the trickle.
        _ = estimator.applyIdrPacing(.halfStaleEstimate, now: driver.now)
        XCTAssertEqual(Double(estimator.rateBitsPerSecond), 10e6,
                       accuracy: 0.2e6)
        for _ in 0..<40 {
            let verdict = driver.beat(
                bottleneckMbps: 10,
                extraDelayMicros: 40_000,
                backlogBytes: 40_000
            )
            XCTAssertNotEqual(verdict.change, .overuse,
                "a censored trickle at half the belief must not anchor a fall")
        }
        XCTAssertEqual(Double(estimator.rateBitsPerSecond), 10e6,
                       accuracy: 0.5e6,
            "the rate rode the trickle without falling")
        XCTAssertEqual(
            Double(estimator.capacityBeliefBitsPerSecond ?? 0),
            10e6, accuracy: 1e6,
            """
                RECOVERY re-anchors belief; censored trickle then leaves \
                that new-path anchor standing
                """
        )
        XCTAssertEqual(estimator.stats.beliefDemotions, 0)

        // Honest evidence at last: the path measurably stretches the
        // trains to 4 Mbps (well under the 10 Mbps pace). The fall
        // executes and lands on measured delivery — and the belief
        // demotes to what the path proved, not a step sooner.
        let verdict = driver.beatUntilFall(
            bottleneckMbps: 4, extraDelayMicros: 60_000,
            backlogBytes: 40_000
        )
        XCTAssertNotNil(verdict.newRateBitsPerSecond)
        XCTAssertEqual(Double(verdict.newRateBitsPerSecond!), 4e6 * 0.85,
                       accuracy: 0.6e6,
            "honest evidence anchors the fall at measured delivery")
        XCTAssertGreaterThanOrEqual(estimator.stats.beliefDemotions, 1)
        XCTAssertEqual(
            Double(estimator.capacityBeliefBitsPerSecond ?? 0),
            4e6, accuracy: 0.6e6,
            "the belief follows the path down on honest evidence"
        )
    }

    /// A genuine loss episode falls honestly, then the fallen pacer can
    /// only produce censored trickle — while fresh compressed super-rate
    /// drains keep proving the path. The standing rate must ride the
    /// limbo WITHOUT ratcheting toward the floor and recover toward the
    /// belief when the weather clears.
    func testCensoredTrickleAfterAFallRecoversTowardTheBelief() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)
        var received: UInt32 = 0
        var missing: UInt32 = 0

        // Phase 1 — clean baseline: belief at the proven 20 Mbps.
        for _ in 0..<10 {
            received += 100
            driver.beat(
                bottleneckMbps: 20,
                channels: lossLedger(received: received, missing: missing)
            )
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        // Phase 2 — the genuine loss episode (the flood arrives): 25%
        // loss for 1.2 s. The loss branch falls exactly as ever.
        for _ in 0..<48 {
            received += 75; missing += 25
            driver.beat(
                bottleneckMbps: 20,
                channels: lossLedger(received: received, missing: missing)
            )
        }
        let afterEpisode = estimator.rateBitsPerSecond
        XCTAssertLessThan(afterEpisode, Self.ceiling,
            """
                genuine loss still falls — the honesty work must not \
                blunt the loss branch
                """)
        XCTAssertGreaterThanOrEqual(estimator.stats.lossDownshifts, 2)

        // Phase 3 — the limbo that killed the old law: 1.5 s of
        // censored trickle at the fallen pace, standing inflation,
        // standing backlog — and every 8th report a compressed drain
        // proving the path still flies. NO fall may anchor to the
        // trickle; the rate must not ratchet.
        let downshiftsBeforeLimbo = estimator.stats.downshifts
        for beat in 0..<60 {
            received += 100
            let paceMbps = Double(estimator.rateBitsPerSecond) / 1e6
            let verdict: RateEstimatorVerdict
            if beat % 8 == 7 {
                // The drain: a compressed super-rate full train, clean
                // delay (the hole closed — the streak resets).
                verdict = driver.beat(
                    bottleneckMbps: 300,
                    backlogBytes: 40_000,
                    channels: lossLedger(received: received, missing: missing)
                )
            } else {
                verdict = driver.beat(
                    bottleneckMbps: paceMbps,
                    extraDelayMicros: 40_000,
                    backlogBytes: 40_000,
                    channels: lossLedger(received: received, missing: missing)
                )
            }
            if let newRate = verdict.newRateBitsPerSecond,
               verdict.change == .overuse {
                XCTAssertGreaterThanOrEqual(
                    Double(newRate),
                    Double(estimator.rateBitsPerSecond) * 0.84,
                    """
                        an overuse fall in the limbo may be bounded \
                        multiplicative at worst — never a crater to \
                        0.85 × trickle
                        """
                )
            }
        }
        XCTAssertGreaterThanOrEqual(
            estimator.rateBitsPerSecond,
            Int(Double(afterEpisode) * 0.7),
            """
                the limbo must not ratchet the rate toward the floor \
                (the old law lived at 0.1–1.6 Mbps here)
                """
        )
        XCTAssertLessThanOrEqual(
            estimator.stats.downshifts - downshiftsBeforeLimbo, 2,
            "the trickle-fall cascade is dead"
        )
        XCTAssertGreaterThanOrEqual(
            estimator.capacityBeliefBitsPerSecond ?? 0, 20_000_000,
            "the drains kept the belief honest about the path"
        )

        // Phase 4 — the weather clears: clean reports, fresh evidence.
        // The rate recovers toward the belief instead of staying
        // pinned.
        let beforeRecovery = estimator.rateBitsPerSecond
        for _ in 0..<80 {
            received += 100
            let paceMbps = Double(estimator.rateBitsPerSecond) / 1e6
            driver.beat(
                bottleneckMbps: paceMbps,
                channels: lossLedger(received: received, missing: missing)
            )
        }
        XCTAssertGreaterThanOrEqual(
            Double(estimator.rateBitsPerSecond),
            Double(beforeRecovery) * 1.15,
            "clean air climbs toward the belief (10%/s), not a pin"
        )
    }

    /// The session's first report carries no attempt evidence (its ledger
    /// only seeds the differencing), so a NACK in it — a lost opening-IDR
    /// shard — is no denominator, not 100 % post-FEC loss.
    func testAFirstReportNackIsNotTotalPostFecLoss() throws {
        let estimator = makeEstimator()
        let samples = train(
            estimator, seqStart: 0, count: 20, sendStartNS: Self.ms,
            sendSpacingNS: 100_000, bottleneckBitsPerSecond: 20_000_000)
        let verdict = estimator.ingest(
            report(
                samples: Array(samples.dropFirst()), clientMicros: 30_000,
                channels: lossLedger(received: 19, missing: 1),
                nacks: [try FeedbackReport.NackEntry(
                    frame: FrameNumber(rawValue: 0), missingShards: [0])]),
            now: 30 * Self.ms, inRecovery: false)
        XCTAssertEqual(verdict.postFecLossFraction, 0)
        XCTAssertNil(verdict.newRateBitsPerSecond)
        XCTAssertNil(verdict.fecRegime)
        XCTAssertEqual(estimator.fecRegime, .clean)
    }

    /// A client may send reports at any rate. A storm of them — each with
    /// a train of dispersion, every tenth with six full NACK entries on
    /// fresh frames — must leave the estimator's memory bounded, not
    /// grown per report.
    func testReportStormKeepsEvidenceBounded() throws {
        let estimator = makeEstimator()
        var seq = 0
        var received: UInt32 = 0
        for n in 0..<2_100 {
            let now = Self.ms + UInt64(n) * 10_000
            let samples = train(
                estimator, seqStart: seq, count: 4, sendStartNS: now,
                sendSpacingNS: 1_000, bottleneckBitsPerSecond: 20_000_000)
            seq += 4
            received += 4
            let nacks = try (0..<(n % 10 == 0 ? 6 : 0)).map { entry in
                try FeedbackReport.NackEntry(
                    frame: FrameNumber(rawValue: UInt32(n * 6 + entry)),
                    missingShards: Array(0...254))
            }
            _ = estimator.ingest(
                report(samples: samples, clientMicros: now / 1_000,
                       channels: lossLedger(received: received, missing: 0),
                       nacks: nacks),
                now: now, inRecovery: false)
        }
        XCTAssertLessThanOrEqual(
            estimator.retainedEvidenceCount,
            2 * 256 + 2_048 + 4_096 + 1_024)
        XCTAssertGreaterThanOrEqual(
            estimator.rateBitsPerSecond, estimator.config.floorBitsPerSecond)
    }

    /// Self-inflicted evidence recuses itself: NACKs against frames
    /// whose shards are still queued in our own pacer (the client's
    /// completion presumption expiring mid-drain) feed neither the
    /// post-FEC fractions nor the regime ladder. The same storm
    /// unrecused still bites.
    func testRecusedNackShardsAreNotPathEvidence() throws {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)
        var received: UInt32 = 0

        for _ in 0..<10 {
            received += 400
            driver.beat(
                bottleneckMbps: 20,
                channels: lossLedger(received: received, missing: 0)
            )
        }

        func storm(_ frames: Range<UInt32>) throws
            -> [FeedbackReport.NackEntry] {
            try frames.map {
                try FeedbackReport.NackEntry(
                    frame: FrameNumber(rawValue: $0),
                    missingShards: Array(0...30)
                )
            }
        }

        // A rung-3-scale storm, every frame still draining in our own
        // pacer: recused whole. No post-FEC fraction, no rung-3 fall,
        // no regime step — the evidence measured our drain, not the
        // path.
        driver.now += 25 * Self.ms; driver.clientMicros += 25_000
        received += 400
        let recused = estimator.ingest(
            report(samples: [], clientMicros: driver.clientMicros,
                   channels: lossLedger(received: received, missing: 0),
                   nacks: try storm(100..<106)),
            now: driver.now, inRecovery: false,
            recusedNackFrames: Set(100..<106)
        )
        XCTAssertEqual(recused.postFecLossFraction, 0)
        XCTAssertNil(recused.newRateBitsPerSecond)
        XCTAssertNil(recused.fecRegime)
        XCTAssertEqual(estimator.fecRegime, .clean)
        XCTAssertEqual(estimator.stats.nackShardsRecused, 6 * 31)
        XCTAssertEqual(estimator.stats.nackShardsCounted, 0)

        // The same storm against frames the pacer has long released:
        // honest path evidence — rung 3 bites and the regime steps.
        driver.now += 500 * Self.ms; driver.clientMicros += 500_000
        received += 400
        let honest = estimator.ingest(
            report(samples: [], clientMicros: driver.clientMicros,
                   channels: lossLedger(received: received, missing: 0),
                   nacks: try storm(200..<206)),
            now: driver.now, inRecovery: false
        )
        XCTAssertEqual(honest.change, .postFecLoss,
            """
                unrecused NACK storms still bite — the recusal is \
                surgical, not a muzzle
                """)
        XCTAssertEqual(honest.fecRegime, .lossy)
    }

    /// The first live leg-B rerun's confession, pinned: a Wi-Fi hole
    /// stretches mid-dwell trains into honest-LOOKING low readings,
    /// and the compressed drain that proves the hole closed arrives
    /// in the SAME report (`honest 8316 kbps … full-train 98429 kbps
    /// 0 ms ago`). The drain must purge the mid-hole votes — they
    /// measured the hole, not the path — so the fall-check finds no
    /// honest evidence and holds instead of demoting the belief to
    /// the hole's trickle.
    func testDrainPurgesMidHoleStretchReadings() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)

        driver.prime()
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        // 30 beats of the live shape: every report carries a
        // mid-hole STRETCHED train (3 Mbps — honest-looking) AND a
        // compressed 200 Mbps drain, all under held delay (the hole
        // chain never lets the streak reset, so persistence IS
        // reached — the purge is the only thing standing between the
        // belief and the 3 Mbps trickle).
        for _ in 0..<30 {
            driver.now += 25 * Self.ms
            driver.clientMicros += 25_000
            let stretched = train(
                estimator, seqStart: driver.seq, count: 12,
                sendStartNS: driver.now - 20 * Self.ms,
                bottleneckBitsPerSecond: 3e6, extraDelayMicros: 80_000
            )
            driver.seq += 12
            let drain = train(
                estimator, seqStart: driver.seq, count: 12,
                sendStartNS: driver.now - Self.ms,
                bottleneckBitsPerSecond: 200e6, extraDelayMicros: 80_000
            )
            driver.seq += 12
            let verdict = estimator.ingest(
                report(samples: stretched + drain,
                       clientMicros: driver.clientMicros),
                now: driver.now, inRecovery: false,
                pacerBacklogBytes: 40_000
            )
            XCTAssertNil(verdict.newRateBitsPerSecond,
                """
                    a hole whose own drain testifies in the same report \
                    must not anchor a fall
                    """)
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling,
            "the belief never demoted to the mid-hole trickle")
        XCTAssertEqual(estimator.stats.downshifts, 0)
        // The drains protect (votes purged, no fall, rate held) but do
        // not raise the belief to their burst rate: the belief stays ≈
        // the pace the drains proved, and never drops below it.
        XCTAssertGreaterThanOrEqual(
            estimator.capacityBeliefBitsPerSecond ?? 0, Self.ceiling - 1_000_000,
            "the hole cost the belief — the drains stopped protecting it"
        )
        XCTAssertLessThanOrEqual(
            estimator.capacityBeliefBitsPerSecond ?? 0, 30_000_000,
            """
                the drains raised the belief toward their burst rate
                """
        )
    }

    /// The other live confession: a 41 ms streak crashed to the floor
    /// because ~1% post-FEC NACK echo read as INSTANT corroboration.
    /// Post-FEC between the clean column and rung 3 is a closed
    /// hole's shadow (frames already drained, presumption expired) —
    /// it must wait for persistence like any other pressure; only
    /// rung-3 scale is instant (and rung 3's own branch still falls).
    func testPostFecEchoBelowRungThreeNeedsPersistence() throws {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)
        var received: UInt32 = 0

        for _ in 0..<10 {
            received += 1_200
            driver.beat(
                bottleneckMbps: 20,
                channels: lossLedger(received: received, missing: 0)
            )
        }

        // One NACK-echo burst: 4 frames × 31 shards ≈ 1% of the
        // rolling window's attempted — past the clean column, well
        // under rung 3.
        let echo = try (0..<4).map {
            try FeedbackReport.NackEntry(
                frame: FrameNumber(rawValue: UInt32(50 + $0)),
                missingShards: Array(0...30)
            )
        }
        received += 1_200
        XCTAssertNil(driver.beat(
            bottleneckMbps: 20,
            extraDelayMicros: 60_000,
            channels: lossLedger(received: received, missing: 0),
            nacks: echo
        ).newRateBitsPerSecond)

        // Ten more inflated beats inside the persistence span: the
        // echo must NOT act as instant corroboration (the old law
        // fell here on a 41 ms streak).
        for _ in 0..<10 {
            received += 1_200
            let verdict = driver.beat(
                bottleneckMbps: 20,
                extraDelayMicros: 60_000,
                channels: lossLedger(received: received, missing: 0)
            )
            XCTAssertNil(verdict.newRateBitsPerSecond,
                "a sub-rung-3 NACK echo is a shadow, not instant corroboration")
        }

        // Pressure that outlives the persistence still falls — and
        // bounded multiplicative (no honest votes), never anchored
        // to the echo.
        var verdict = driver.beat(
            bottleneckMbps: 20,
            extraDelayMicros: 60_000,
            channels: lossLedger(received: received, missing: 0)
        )
        var beats = 0
        while verdict.newRateBitsPerSecond == nil, beats < 20 {
            received += 1_200
            verdict = driver.beat(
                bottleneckMbps: 20,
                extraDelayMicros: 60_000,
                channels: lossLedger(received: received, missing: 0)
            )
            beats += 1
        }
        XCTAssertNotNil(verdict.newRateBitsPerSecond)
        XCTAssertGreaterThanOrEqual(verdict.newRateBitsPerSecond!,
                                    16_000_000,
            """
                the persisted fall is bounded multiplicative — the echo \
                never became an anchor
                """)
    }

    /// Mild residual post-FEC (clean column < x ≤ rung 3) must not pin
    /// the climb after a fall. The ~3 Mbps settle under 1% netem was
    /// this seam: residual NACK echo blocked every evidence rise while
    /// never itself warranting a rung-3 fall. lastGoodRate and regime
    /// step-down stay on the stricter clean column.
    func testMildPostFecResidualDoesNotPinTheClimb() throws {
        let startRate = 3_000_000
        let estimator = makeEstimator {
            $0.initialRateBitsPerSecond = startRate
        }
        let driver = EstimatorDriver(self, estimator)
        var received: UInt32 = 0
        var frame: UInt32 = 100

        // Prime totals + paced evidence at the depressed standing rate.
        // A little probe-headroom climb during the clean prime is fine;
        // the residual phase must keep climbing from that settle point.
        for _ in 0..<12 {
            received += 1_200
            driver.beat(
                bottleneckMbps: Double(startRate) / 1e6,
                channels: lossLedger(received: received, missing: 0)
            )
        }
        let settlePoint = estimator.rateBitsPerSecond
        XCTAssertLessThan(settlePoint, startRate + 250_000,
            "prime must stay near the depressed settle, not race the ceiling")

        // Continuous ~1% post-FEC residual with clean pre-FEC ledgers:
        // 12 fresh NACK shards against ~1,200 attempted per beat.
        var climbs = 0
        let mildBefore = estimator.stats.upshiftsUnderMildPostFec
        for _ in 0..<160 {
            received += 1_200
            let residual = try FeedbackReport.NackEntry(
                frame: FrameNumber(rawValue: frame),
                missingShards: Array(0..<12)
            )
            frame &+= 1
            let before = estimator.rateBitsPerSecond
            let verdict = driver.beat(
                bottleneckMbps: Double(before) / 1e6,
                channels: lossLedger(received: received, missing: 0),
                nacks: [residual]
            )
            XCTAssertNotEqual(verdict.change, .postFecLoss,
                "sub-rung-3 residual must not itself fall the rate")
            if let rate = verdict.newRateBitsPerSecond, rate > before {
                climbs += 1
            }
        }

        XCTAssertGreaterThan(climbs, 0,
            "mild post-FEC residual must admit evidence climbs")
        XCTAssertGreaterThan(estimator.rateBitsPerSecond, settlePoint,
            "the climb must leave the depressed settle point")
        XCTAssertGreaterThan(
            estimator.stats.upshiftsUnderMildPostFec, mildBefore,
            "the mild-residual climb book must fire")
        XCTAssertLessThan(
            estimator.stats.postFecDownshifts, 1,
            "residual below rung 3 must not mint rung-3 falls")
    }

    /// Rung-3 post-FEC still falls and blocks climbs — the mild-residual
    /// climb gate must not open past the downshift threshold.
    func testRungThreePostFecStillBlocksTheClimb() throws {
        let estimator = makeEstimator {
            $0.initialRateBitsPerSecond = 6_000_000
        }
        let driver = EstimatorDriver(self, estimator)
        var received: UInt32 = 0
        var frame: UInt32 = 200

        for _ in 0..<8 {
            received += 400
            driver.beat(
                bottleneckMbps: 6,
                channels: lossLedger(received: received, missing: 0)
            )
        }
        let beforeFall = estimator.rateBitsPerSecond

        // ~5% post-FEC: well past rung 3 against the rolling attempts.
        received += 400
        let heavy = try (0..<4).map {
            try FeedbackReport.NackEntry(
                frame: FrameNumber(rawValue: frame &+ UInt32($0)),
                missingShards: Array(0..<20)
            )
        }
        let fall = driver.beat(
            bottleneckMbps: 6,
            channels: lossLedger(received: received, missing: 0),
            nacks: heavy
        )
        XCTAssertEqual(fall.change, .postFecLoss)
        XCTAssertLessThan(estimator.rateBitsPerSecond, beforeFall)

        let rateAfterFall = estimator.rateBitsPerSecond
        var climbs = 0
        for _ in 0..<40 {
            received += 400
            let keepHeavy = try FeedbackReport.NackEntry(
                frame: FrameNumber(rawValue: frame),
                missingShards: Array(0..<20)
            )
            frame &+= 1
            let before = estimator.rateBitsPerSecond
            let verdict = driver.beat(
                bottleneckMbps: Double(max(before, 2_000_000)) / 1e6,
                channels: lossLedger(received: received, missing: 0),
                nacks: [keepHeavy]
            )
            if let rate = verdict.newRateBitsPerSecond, rate > before {
                climbs += 1
            }
        }
        XCTAssertEqual(climbs, 0,
            "rung-3 post-FEC must keep blocking evidence climbs")
        XCTAssertLessThanOrEqual(
            estimator.rateBitsPerSecond, rateAfterFall,
            "sustained rung-3 evidence must not raise the rate")
        XCTAssertEqual(estimator.stats.upshiftsUnderMildPostFec, 0)
    }

    /// Quiet-static / sparse keepalive under impairment must not
    /// one-way ratchet the standing rate. Climb already needs a fresh
    /// delivery train; falls share that freshness bar so thin traffic
    /// freezes rather than inventing a descent the climb path cannot
    /// reverse (doctrine: no padding a blank desktop to probe).
    func testSparseKeepaliveLossDoesNotRatchetWithoutDeliveryEvidence() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)
        var received: UInt32 = 0

        // One clean full train primes delivery freshness + belief.
        received += 1_200
        driver.beat(
            bottleneckMbps: 20,
            channels: lossLedger(received: received, missing: 0)
        )
        let primed = estimator.rateBitsPerSecond
        XCTAssertEqual(primed, Self.ceiling)

        // Age past the climb freshness window with no new trains —
        // the quiet-desktop shape after the opening IDR drains.
        driver.now += 3_000 * Self.ms
        driver.clientMicros += 3_000_000

        let holdsBefore = estimator.stats.sparseEvidenceHolds
        var receivedSparse: UInt32 = received
        var missingSparse: UInt32 = 0
        for _ in 0..<40 {
            // ~20% ledger loss on a trickle of packets, no dispersion
            // trains — enough to fire the old loss fall every limiter
            // beat, and exactly the sparse ratchet the live static
            // harsh-path walk showed (50 → 13.8 Mbps, 0 upshifts).
            receivedSparse += 8
            missingSparse += 2
            let verdict = estimator.ingest(
                report(
                    samples: [],
                    clientMicros: driver.clientMicros,
                    channels: lossLedger(
                        received: receivedSparse, missing: missingSparse)
                ),
                now: driver.now, inRecovery: false
            )
            driver.now += 25 * Self.ms
            driver.clientMicros += 25_000
            XCTAssertNil(verdict.newRateBitsPerSecond,
                "stale delivery evidence must freeze the standing rate")
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, primed,
            "sparse keepalive loss must not ratchet without trains")
        XCTAssertEqual(estimator.stats.lossDownshifts, 0)
        XCTAssertEqual(estimator.stats.upshifts, 0,
            "no trains → no climbs (content-driven; no padding)")
        XCTAssertGreaterThan(
            estimator.stats.sparseEvidenceHolds, holdsBefore,
            "the sparse-hold book must fire")

        // Fresh paced trains reopen the loss fall — motion returns.
        let beforeMotion = estimator.rateBitsPerSecond
        var fell = false
        for _ in 0..<8 {
            receivedSparse += 960
            missingSparse += 240
            let verdict = driver.beat(
                bottleneckMbps: Double(beforeMotion) / 1e6,
                channels: lossLedger( received: receivedSparse, missing: missingSparse)
            )
            if verdict.change == .loss { fell = true }
        }
        XCTAssertTrue(fell,
            "paced multi-packet trains must still admit loss falls")
        XCTAssertLessThan(estimator.rateBitsPerSecond, beforeMotion)
    }

    /// Stale overuse pressure on an empty path (netem delay on
    /// keepalive) must hold, not walk the rate down with a 25 s-old
    /// full-train forensic and no climb path back.
    func testSparseOveruseDoesNotFallWithoutFreshDeliveryEvidence() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)

        for _ in 0..<8 {
            driver.beat(bottleneckMbps: 20)
        }
        let primed = estimator.rateBitsPerSecond

        // Age the delivery window past freshness, then apply sustained
        // inflation with no new trains and no backlog — the live
        // static overuse shape (`full-train … 25560 ms ago`).
        driver.now += 3_000 * Self.ms
        driver.clientMicros += 3_000_000
        let holdsBefore = estimator.stats.sparseEvidenceHolds
        var overuseBeats = 0
        for _ in 0..<40 {
            // Ledger-only reports still need *some* matched samples to
            // move the delay detector. Two short video packets are
            // enough for inflation bookkeeping but never form a
            // delivery train (≥3), so freshness stays stale.
            let samples = train(
                estimator, seqStart: driver.seq, count: 2,
                frameNumber: UInt32(driver.seq),
                sendStartNS: driver.now - Self.ms,
                bottleneckBitsPerSecond: 20e6,
                extraDelayMicros: 40_000
            )
            driver.seq += 2
            let verdict = estimator.ingest(
                report(samples: samples, clientMicros: driver.clientMicros),
                now: driver.now, inRecovery: false, pacerBacklogBytes: 0
            )
            if verdict.overuse { overuseBeats += 1 }
            XCTAssertNil(verdict.newRateBitsPerSecond)
            driver.now += 25 * Self.ms
            driver.clientMicros += 25_000
        }
        XCTAssertGreaterThan(overuseBeats, 0,
            "overuse must still detect — the gate holds the FALL")
        XCTAssertEqual(estimator.rateBitsPerSecond, primed)
        XCTAssertEqual(estimator.stats.downshifts, 0)
        XCTAssertGreaterThan(
            estimator.stats.sparseEvidenceHolds, holdsBefore)
    }

    // MARK: - The machine's numbers

    func testIdrPacingNumbers() {
        let estimator = makeEstimator()
        // Before any evidence: halfStale halves the standing rate,
        // lastGoodRate is the standing rate.
        XCTAssertEqual(
            estimator.applyIdrPacing(.halfStaleEstimate, now: Self.ms),
            Self.ceiling / 2
        )
        // Applying the policy moved the standing rate there.
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling / 2)

        // Seed a measured 8 Mbps delivery estimate.
        let samples = train(
            estimator, seqStart: 0, count: 40,
            sendStartNS: 100 * Self.ms,
            bottleneckBitsPerSecond: 8e6
        )
        _ = estimator.ingest(
            report(samples: samples, clientMicros: 200_000),
            now: 200 * Self.ms, inRecovery: false
        )

        // WAKE: min(btlRate, lastGoodRate).
        XCTAssertEqual(
            estimator.applyIdrPacing(.lastGoodRate, now: 300 * Self.ms),
            8_000_000, accuracy: 400_000
        )
        // RECOVERY: max(floor, ½ × stale estimate).
        XCTAssertEqual(
            estimator.applyIdrPacing(.halfStaleEstimate, now: 400 * Self.ms),
            4_000_000, accuracy: 200_000
        )
    }

    /// RECOVERY halves what the path last proved, not a burst. Trains
    /// that arrive compressed (a drained Wi-Fi queue) can read several
    /// times the path's rate; the capacity belief never exceeds what
    /// was paced, so the half-stale restart answers to it.
    func testHalfStaleIgnoresACompressedDeliveryBurst() {
        let estimator = makeEstimator()
        let samples = train(
            estimator, seqStart: 0, count: 40,
            sendStartNS: 100 * Self.ms,
            bottleneckBitsPerSecond: 480e6)
        _ = estimator.ingest(
            report(samples: samples, clientMicros: 200_000),
            now: 200 * Self.ms, inRecovery: false)
        let belief = try! XCTUnwrap(estimator.capacityBeliefBitsPerSecond)
        XCTAssertLessThanOrEqual(belief, Self.ceiling)
        XCTAssertEqual(
            estimator.applyIdrPacing(.halfStaleEstimate, now: 300 * Self.ms),
            belief / 2, accuracy: belief / 20,
            "RECOVERY restarted from a compressed burst, not the proven path")
    }

    /// Reports still in flight at a path change describe datagrams sent on
    /// the old path. A fast old path (0 ms standing delay) followed by a
    /// slower new one (30 ms): if those reports seeded the new path's
    /// baseline, every new-path report would read 30 ms inflated and fall.
    func testReportsOfOldPathSendsDoNotSeedTheNewPathsBaseline() {
        let estimator = makeEstimator()
        let driver = EstimatorDriver(self, estimator)
        for _ in 0..<10 { driver.beat(bottleneckMbps: 10) }

        var inFlight: [FeedbackReport] = []
        for index in 0..<3 {
            let sendStart = driver.now + UInt64(index) * 5 * Self.ms
            let samples = train(
                estimator, seqStart: 10_000 + index * 12, count: 12,
                sendStartNS: sendStart, bottleneckBitsPerSecond: 10e6)
            inFlight.append(report(
                samples: samples, clientMicros: sendStart / 1_000 + 1_000))
        }
        let promotion = driver.now + 20 * Self.ms
        estimator.notePathChanged(now: promotion)
        for (index, late) in inFlight.enumerated() {
            let verdict = estimator.ingest(
                late, now: promotion + UInt64(index + 1) * Self.ms,
                inRecovery: false)
            XCTAssertFalse(verdict.overuse)
        }
        XCTAssertEqual(estimator.stats.dispersionSamplesFromOldPath, 36)

        driver.now = promotion + 10 * Self.ms
        for beat in 0..<20 {
            let verdict = driver.beat(
                bottleneckMbps: 10, extraDelayMicros: 30_000)
            XCTAssertFalse(verdict.overuse, "new-path beat \(beat)")
            XCTAssertNotEqual(verdict.change, .overuse)
        }
        XCTAssertLessThanOrEqual(estimator.queuingDelayMicroseconds ?? 0, 1_000)
    }

    func testRecoveryReanchorsNinetyMegabitBeliefBeforeFiveMegabitPath() {
        let estimator = RateEstimator(config: RateEstimatorConfig(
            ceilingBitsPerSecond: 100_000_000,
            initialRateBitsPerSecond: 90_000_000
        ), now: 0)

        let oldPath = train(
            estimator, seqStart: 0, count: 16,
            sendStartNS: 10 * Self.ms,
            bottleneckBitsPerSecond: 90e6
        )
        _ = estimator.ingest(
            report(samples: oldPath, clientMicros: 20_000),
            now: 20 * Self.ms, inRecovery: false
        )
        XCTAssertEqual(
            Double(estimator.capacityBeliefBitsPerSecond ?? 0),
            90e6, accuracy: 3e6
        )

        let recoveryRate = estimator.applyIdrPacing(
            .halfStaleEstimate, now: 30 * Self.ms
        )
        XCTAssertEqual(Double(recoveryRate), 45e6, accuracy: 2e6)
        XCTAssertEqual(estimator.capacityBeliefBitsPerSecond, recoveryRate,
            "the half-stale pace is the new path's sole starting belief")
        XCTAssertNil(estimator.deliveryRateBitsPerSecond,
            "old-path delivery samples must not survive migration")

        var now = 50 * Self.ms
        var seq = 100
        func beat(_ extraDelay: UInt64) -> RateEstimatorVerdict {
            let samples = train(
                estimator, seqStart: seq, count: 16,
                sendStartNS: now - Self.ms,
                bottleneckBitsPerSecond: 5e6,
                extraDelayMicros: extraDelay
            )
            seq += 16
            let verdict = estimator.ingest(
                report(samples: samples, clientMicros: now / 1_000),
                now: now, inRecovery: false
            )
            now += 300 * Self.ms
            return verdict
        }
        _ = beat(0)
        _ = beat(0)
        _ = beat(30_000)
        _ = beat(30_000)
        let fall = beat(30_000)
        XCTAssertEqual(fall.change, .overuse)
        XCTAssertEqual(
            Double(estimator.capacityBeliefBitsPerSecond ?? 0),
            5e6, accuracy: 0.7e6,
            """
                fresh uniformly-stretched evidence demotes the re-anchored \
                belief on the 5 Mbps tether
                """
        )
        XCTAssertLessThan(estimator.rateBitsPerSecond, 6_000_000)
    }

    func testFrameByteCeilingTracksTheLiveEstimate() {
        let estimator = makeEstimator()
        // At 20 Mbps and 60 fps, the 25 ms budget leaves 59,937 wire
        // bytes after protected traffic: 52 complete datagrams. Clean
        // FEC fits k=47 + m=5, each carrying 1,095 encoded bytes under
        // the production connection-id + last-input overhead.
        let atCeiling = estimator.frameByteCeiling(fps: 60)
        XCTAssertEqual(atCeiling, 47 * 1_095,
                       "the ceiling charges clean FEC wire overhead")
        // 30 fps: B stays 25 ms (min(66 ms, 25 ms)); 120 fps: B =
        // 16.6 ms.
        XCTAssertEqual(estimator.frameByteCeiling(fps: 30), atCeiling)
        XCTAssertLessThan(estimator.frameByteCeiling(fps: 120), atCeiling)

        // The ceiling tracks the estimate down…
        _ = estimator.applyIdrPacing(.halfStaleEstimate, now: Self.ms)
        let atHalf = estimator.frameByteCeiling(fps: 60)
        XCTAssertEqual(atHalf, 20 * 1_095,
            "24 wire shards fit k=20 + m=3; k=21 + m=4 does not")
        // …and reaches the production floor, which can still pace a
        // complete protected frame inside the same budget.
        for _ in 0..<8 {
            _ = estimator.applyIdrPacing(
                .halfStaleEstimate, now: 2 * Self.ms
            )
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, 2_000_000)
        XCTAssertEqual(estimator.frameByteCeiling(fps: 60), 2 * 1_095,
            "the clean floor fits k=2 + m=1 in three wire datagrams")
    }

    func testProductionFloorPaysProtectedTrafficAndWorstFecFlight() {
        let config = RateEstimatorConfig(
            ceilingBitsPerSecond: Self.ceiling)
        XCTAssertEqual(config.floorBitsPerSecond, 2_000_000)

        let budgetSeconds = Double(
            RateEstimator.frameBudgetNS(fps: 60)) / 1e9
        let grossWireBytes = Int(
            Double(config.floorBitsPerSecond) * budgetSeconds / 8)
        let protectedBytes = Int(Double(
            RateEstimator.audioReserveBitsPerSecond
                + RateEstimator.controlReserveBitsPerSecond
        ) * budgetSeconds / 8)
        let worstMinimumFlightBytes =
            3 * WireBudget.maxDatagramByteCount // k=1 + lossy m=2

        XCTAssertGreaterThanOrEqual(
            grossWireBytes - protectedBytes,
            worstMinimumFlightBytes,
            "the operational floor must not command an impossible recovery")
    }

    func testLossyFecStepTightensTheEncodedCeilingAtTheFloor() throws {
        let estimator = makeEstimator {
            $0.initialRateBitsPerSecond = 2_000_000
        }
        XCTAssertEqual(estimator.frameByteCeiling(fps: 60), 2 * 1_095,
            "clean k=2 + m=1 consumes the three-shard wire allowance")

        _ = estimator.ingest(
            report(
                samples: [], clientMicros: 1_000,
                channels: lossLedger(received: 1_000, missing: 0)),
            now: Self.ms, inRecovery: false)
        let nack = try FeedbackReport.NackEntry(
            frame: FrameNumber(rawValue: 7),
            missingShards: [0, 1, 2])
        let verdict = estimator.ingest(
            report(
                samples: [], clientMicros: 2_000,
                channels: lossLedger(received: 1_100, missing: 0),
                nacks: [nack]),
            now: 2 * Self.ms, inRecovery: false)

        XCTAssertEqual(verdict.fecRegime, .lossy)
        XCTAssertEqual(estimator.frameByteCeiling(fps: 60), 1_095,
            "lossy k=1 + m=2 consumes the same three-shard allowance")
    }

    // MARK: - RECOVERY verdicts through the whole session

    /// An insecure-mode session (machine armed from init, passthrough
    /// seal) driven with real chan-3 FeedbackReports: the estimator's
    /// verdicts decide graduation, and loss
    /// inside a window honestly holds RECOVERY.
    func testRecoveryGraduatesOnEstimatorVerdictsNotMerePresence() throws {
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                rateBitsPerSecond: Self.ceiling,
                beaconIntervalNS: 1 << 62
            ),
            passthroughTo: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x1616)
        ) { sent.append($0) }

        var received: UInt32 = 0
        var missing: UInt32 = 0
        func feedback(
            tMicros: UInt64, newReceived: UInt32, newMissing: UInt32
        ) -> [SessionEvent] {
            received += newReceived
            missing += newMissing
            let body = try! FeedbackReport(
                clientTimestamp: ClientTimestamp(microseconds: tMicros),
                channels: lossLedger(received: received, missing: missing)
            ).encode()
            let envelope = Envelope(
                channel: .feedback,
                seq: ChannelSeq(rawValue: UInt16(truncatingIfNeeded: tMicros / 25_000)),
                frame: FrameNumber(rawValue: 0),
                timestamp: tMicros,
                fec: 0
            )
            let datagram = try! envelope.encode(payload: body)
            return session.receive(
                datagram, from: Self.tupleA,
                now: tMicros * 1_000, hostMicroseconds: tMicros
            )
        }

        // Healthy, then 400 ms of silence: FROZEN.
        _ = feedback(tMicros: 100_000, newReceived: 100, newMissing: 0)
        var t: UInt64 = 520_000
        _ = session.advance(now: t * 1_000, hostMicroseconds: t)
        XCTAssertEqual(session.lifecycleState, .frozen)

        // Evidence returns: RECOVERY, and the estimator paced the
        // machine's halfStaleEstimate IDR onto the shared pacer.
        t += 30_000
        let recoveryEvents = feedback(
            tMicros: t, newReceived: 10, newMissing: 0
        )
        XCTAssertEqual(session.lifecycleState, .recovery)
        XCTAssertTrue(recoveryEvents.contains(.rateChanged(
            bitsPerSecond: Self.ceiling / 2,
            reason: .idrPacing(.halfStaleEstimate)
        )), "RECOVERY's IDR rides at the half-stale rate, applied live")
        XCTAssertEqual(session.pacerRateBitsPerSecond, Self.ceiling / 2)
        XCTAssertTrue(session.takeFreshKeyframeRequest())

        // LOSSY windows: 300 ms of feedback presence that the stub
        // would have graduated — the estimator refuses every window.
        for _ in 0..<10 {
            t += 30_000
            _ = feedback(tMicros: t, newReceived: 95, newMissing: 5)
            XCTAssertEqual(session.lifecycleState, .recovery,
                           "loss inside the window must hold RECOVERY")
        }

        // Clean windows: two graduate it.
        t += 30_000
        _ = feedback(tMicros: t, newReceived: 100, newMissing: 0)
        t += 30_000
        _ = feedback(tMicros: t, newReceived: 100, newMissing: 0)
        XCTAssertEqual(session.lifecycleState, .active)
    }

    // MARK: - Malformed feedback is counted, never fed

    func testMalformedFeedbackIsDroppedLoudAndFeedsNothing() {
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                rateBitsPerSecond: Self.ceiling,
                beaconIntervalNS: 1 << 62
            ),
            passthroughTo: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0xBAD)
        ) { sent.append($0) }
        let envelope = Envelope(
            channel: .feedback,
            seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0),
            timestamp: 1_000,
            fec: 0
        )
        let datagram = try! envelope.encode(payload: [0x00, 0x01, 0x02])
        let events = session.receive(
            datagram, from: Self.tupleA, now: Self.ms, hostMicroseconds: 1_000
        )
        XCTAssertTrue(events.contains(.dropped(.malformedFeedback)))
        XCTAssertEqual(session.counters.feedbackDatagrams, 1)
        XCTAssertEqual(session.counters.feedbackReportsMalformed, 1)
        XCTAssertEqual(session.counters.feedbackReportsParsed, 0)
        XCTAssertEqual(session.estimatorStats.reportsIngested, 0)
    }

    // MARK: - Audio cadence under a rate crash

    /// With the estimator live: 6 s at
    /// 20 Mbps — 5 ms audio, 60 fps damage, a worst-case IDR every
    /// 2 s, REAL feedback reports every 25 ms whose dispersion samples
    /// name actually-sent datagrams — then a 900 ms 20%-loss burst
    /// (over FEC's hold band) crashes the rate and clean evidence
    /// climbs it back. Audio inter-send must hold 5 ms ± 2 ms at p99
    /// THROUGH the crash: setRate re-caps video, never audio's
    /// cadence.
    func testGateAudioCadenceHoldsThroughRateCrash() throws {
        final class Box {
            var audioSends: [(at: UInt64, envelope: Envelope)] = []
            var videoSends: [(at: UInt64, seq: UInt16, bytes: Int)] = []
            var sendInstant: UInt64 = 0
        }
        let box = Box()
        let session = Session(
            config: SessionConfig(
                rateBitsPerSecond: Self.ceiling
            ),
            passthroughTo: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x1620)
        ) { datagram in
            switch datagram.pacerClass {
            case .audio:
                let (envelope, _) = try! Envelope.decode(datagram.bytes)
                box.audioSends.append((box.sendInstant, envelope))
            case .freshVideo:
                box.videoSends.append((
                    box.sendInstant, datagram.seq.rawValue,
                    datagram.bytes.count
                ))
            default:
                break
            }
        }

        let ms = Self.ms
        let horizonNS = 6_000 * ms
        let lossyRange = (2_000 * ms)..<(3_600 * ms)

        enum Arrival { case audio, damage, idr, feedback }
        var events: [(at: UInt64, what: Arrival)] = []
        var t: UInt64 = 0
        while t < horizonNS { events.append((t, .audio)); t += 5 * ms }
        t = 8 * ms
        while t < horizonNS { events.append((t, .damage)); t += 16_666_667 }
        t = 100 * ms
        while t < horizonNS { events.append((t, .idr)); t += 2_000 * ms }
        t = 25 * ms
        while t < horizonNS { events.append((t, .feedback)); t += 25 * ms }
        events.sort { $0.at < $1.at }

        func opusPacket(_ n: Int) -> [UInt8] {
            (0..<80).map { UInt8(truncatingIfNeeded: n &* 31 &+ $0) }
        }

        var audioPacketNumber = 0
        var reportedVideoSends = 0
        var received: UInt32 = 0
        var missing: UInt32 = 0
        var feedbackSeq: UInt16 = 0
        var rates: [(at: UInt64, rate: Int)] = []
        var now: UInt64 = 0

        for event in events {
            while let wake = session.nextWake(now: now), wake < event.at {
                now = max(now &+ 1, wake)
                box.sendInstant = now
                _ = session.advance(now: now, hostMicroseconds: now / 1_000)
                session.pump(now: now)
            }
            now = event.at
            box.sendInstant = now
            switch event.what {
            case .audio:
                _ = try session.ingestAudioPacket(
                    opusPacket(audioPacketNumber),
                    captureTimestampMicroseconds: now / 1_000, now: now
                )
                audioPacketNumber += 1
            case .damage:
                _ = try session.ingestVideoFrame(
                    syntheticFrame(byteCount: 4_000),
                    captureTimestampMicroseconds: now / 1_000,
                    isKeyframe: false, now: now
                )
            case .idr:
                _ = try session.ingestVideoFrame(
                    syntheticFrame(byteCount: 59_904, irap: true),
                    captureTimestampMicroseconds: now / 1_000,
                    isKeyframe: true, now: now
                )
            case .feedback:
                // Report every video datagram the wire carried since
                // the last beat: arrivals at a constant offset — the
                // path delivers what we pace (clean), and the ledger
                // carries the scripted loss regime.
                let window = box.videoSends[reportedVideoSends...]
                reportedVideoSends = box.videoSends.count
                let lossy = lossyRange.contains(now)
                var samples: [FeedbackReport.Dispersion.Sample] = []
                var sampleArrivals: [UInt64] = []
                for send in window.suffix(FeedbackBounds.maxDispersionSamples) {
                    samples.append(FeedbackReport.Dispersion.Sample(
                        channel: .videoActive,
                        seq: ChannelSeq(rawValue: send.seq),
                        arrivalDeltaMicroseconds: 0
                    ))
                    sampleArrivals.append(
                        Self.clockOffsetMicros + send.at / 1_000 + 400
                    )
                }
                received += lossy ? 80 : 100
                if lossy { missing += 20 }
                var dispersion: FeedbackReport.Dispersion?
                if !samples.isEmpty {
                    let base = sampleArrivals.min()!
                    dispersion = FeedbackReport.Dispersion(
                        base: ClientTimestamp(microseconds: base),
                        samples: zip(samples, sampleArrivals).map {
                            FeedbackReport.Dispersion.Sample(
                                channel: $0.0.channel, seq: $0.0.seq,
                                arrivalDeltaMicroseconds: UInt32($0.1 - base)
                            )
                        }
                    )
                }
                let body = try FeedbackReport(
                    clientTimestamp: ClientTimestamp(microseconds: now / 1_000),
                    channels: lossLedger(received: received, missing: missing),
                    dispersion: dispersion
                ).encode()
                let envelope = Envelope(
                    channel: .feedback,
                    seq: ChannelSeq(rawValue: feedbackSeq),
                    frame: FrameNumber(rawValue: 0),
                    timestamp: now / 1_000,
                    fec: 0
                )
                feedbackSeq &+= 1
                for e in session.receive(
                    try envelope.encode(payload: body),
                    from: Self.tupleA, now: now, hostMicroseconds: now / 1_000
                ) {
                    if case .rateChanged(let bps, _) = e {
                        rates.append((now, bps))
                    }
                }
            }
            session.pump(now: now)
        }
        while let wake = session.nextWake(now: now), wake < horizonNS {
            now = max(now &+ 1, wake)
            box.sendInstant = now
            _ = session.advance(now: now, hostMicroseconds: now / 1_000)
            session.pump(now: now)
        }

        // ── The rate crashed and re-converged ───────────────────────
        let minRate = rates.map(\.rate).min() ?? Self.ceiling
        XCTAssertLessThanOrEqual(minRate, 14_600_000,
            "the loss burst must force at least three multiplicative falls")
        XCTAssertGreaterThanOrEqual(session.estimatorStats.lossDownshifts, 3)
        XCTAssertGreaterThan(session.pacerRateBitsPerSecond, minRate,
            "clean evidence must climb the rate back off the crash floor")
        XCTAssertGreaterThanOrEqual(session.estimatorStats.upshifts, 1)

        // ── The cadence held THROUGH it (audio-continuity §4.1) ─────
        let dataSends = try box.audioSends.filter {
            let field = try FecField.decode($0.envelope.fec)
            guard case .reedSolomon(let index, _) = field else { return false }
            return index < 4
        }
        XCTAssertEqual(dataSends.count, audioPacketNumber,
                       "every 5 ms packet reached the wire")
        var deviations: [UInt64] = []
        for i in 1..<dataSends.count {
            let delta = dataSends[i].at - dataSends[i - 1].at
            deviations.append(delta > 5 * ms ? delta - 5 * ms : 5 * ms - delta)
        }
        deviations.sort()
        let p99 = deviations[Int(Double(deviations.count - 1) * 0.99)]
        XCTAssertLessThanOrEqual(p99, 2 * ms,
            """
                audio inter-send p99 deviation \(Double(p99) / 1e6) ms > 2 ms \
                through the rate crash
                """)
    }

    // MARK: - Cap-aware probe damping

    /// With the belief parked at ~20 Mbps and a 50 Mbps configured cap,
    /// the climb stops at belief × headroom instead of probing on
    /// toward a cap the belief says the air cannot honor (probing there
    /// buys loss and IDRs). Five virtual seconds of clean evidence
    /// beats: the rate must park at ~22 Mbps, damped, with zero falls.
    func testProbeCeilingDampsClimbAtBeliefHeadroom() {
        let estimator = makeEstimator {
            $0.ceilingBitsPerSecond = 50_000_000
            $0.initialRateBitsPerSecond = 20_000_000
        }
        let driver = EstimatorDriver(self, estimator)

        // Establish the belief at ~20 Mbps: censored beats at pace.
        driver.prime()
        let belief = Double(estimator.capacityBeliefBitsPerSecond ?? 0)
        XCTAssertEqual(belief, 20e6, accuracy: 2.5e6)

        // 200 clean beats (5 s): the air still delivers only ~20 —
        // trains keep measuring ≈20 whatever the pace wants. The climb
        // must park at belief × 1.1, not walk to the 50 Mbps cap.
        for _ in 0..<200 {
            driver.beat(bottleneckMbps: 20)
        }
        let parked = Double(estimator.rateBitsPerSecond)
        let ceiling = (estimator.capacityBeliefBitsPerSecond
            .map { Double($0) * 1.10 }) ?? 0
        XCTAssertLessThanOrEqual(parked, ceiling + 0.1e6,
            "the climb crossed belief × headroom — probe damping is dead")
        XCTAssertGreaterThanOrEqual(parked, belief,
            "the climb never used its headroom over the belief")
        XCTAssertGreaterThanOrEqual(estimator.stats.upshiftsDamped, 1,
            "the damped-climb counter never fired")
        XCTAssertEqual(estimator.stats.downshifts, 0,
            "damping must come from the probe ceiling, not from falls")
    }

    /// THE OSSIFICATION GUARD: the belief must still grow when the air
    /// improves. Capacity step 20 → 45 Mbps: censored samples above the
    /// belief RAISE it (invariant 1), each raise lifts the probe
    /// ceiling, and the climb walks up geometrically — the standing
    /// rate must reach ≥ 40 Mbps within a bounded window (upshift
    /// ≤10%/s ⇒ 20 → 40 needs ~7.3 s; allow 12).
    func testCapacityStepTheBeliefWalksUpUnderHeadroom() {
        let estimator = makeEstimator {
            $0.ceilingBitsPerSecond = 50_000_000
            $0.initialRateBitsPerSecond = 20_000_000
        }
        let driver = EstimatorDriver(self, estimator)
        driver.prime()

        // The air steps to 45: from here every train drains at the
        // pace we offer (self-limited against generous air), so each
        // beat's sample tracks the risen rate and drags the belief up.
        var beats = 0
        while estimator.rateBitsPerSecond < 40_000_000, beats < 480 {
            let paceMbps = Double(estimator.rateBitsPerSecond) / 1e6
            driver.beat(bottleneckMbps: min(paceMbps, 45))
            beats += 1
        }
        XCTAssertGreaterThanOrEqual(estimator.rateBitsPerSecond, 40_000_000,
            """
                the belief ossified: 12 virtual seconds of improved air \
                never walked the rate up — headroom probing is dead
                """)
        XCTAssertLessThanOrEqual(beats, 480)
        XCTAssertGreaterThanOrEqual(
            estimator.capacityBeliefBitsPerSecond ?? 0, 36_000_000,
            "the belief did not follow the walk up")
    }

    // MARK: - Burst-vs-sustainable belief and probe cadence

    /// A compressed drain may not set the probe ceiling: a queue
    /// emptying at 300 Mbps proves the path carried our PACE through
    /// the hole, not that the air offers 300 Mbps.
    func testDrainRaisesTheBeliefOnlyToThePaceItDrainedBehind() {
        let estimator = makeEstimator {
            $0.ceilingBitsPerSecond = 50_000_000
            $0.initialRateBitsPerSecond = 20_000_000
        }
        let driver = EstimatorDriver(self, estimator)
        driver.prime()
        let before = estimator.capacityBeliefBitsPerSecond ?? 0
        // A hole closes: one compressed drain at 300 Mbps (≫ pace ×
        // stallBurstRateFactor). The belief may rise to ≈pace, never
        // to the drain's instantaneous rate.
        driver.beat(bottleneckMbps: 300)
        let after = estimator.capacityBeliefBitsPerSecond ?? 0
        XCTAssertLessThanOrEqual(after, Int(25e6),
            """
                a 300 Mbps drain burst set the belief to \(after) — burst \
                pollution is back
                """)
        XCTAssertGreaterThanOrEqual(after, before,
            "the drain may never LOWER the belief")
    }

    /// A fall inside the belief's headroom band arms the probe
    /// cadence: the recover-climb parks BELOW the band until the
    /// cadence expires, then probes again — instead of re-slamming
    /// the wall every recovery cycle.
    func testFailedProbeWaitsItsCadenceBeforeReenteringTheBand() {
        let estimator = makeEstimator {
            $0.ceilingBitsPerSecond = 50_000_000
            $0.initialRateBitsPerSecond = 20_000_000
        }
        let driver = EstimatorDriver(self, estimator)
        driver.prime()
        // Probe into the wall: honest stretched trains + growing queue
        // until the fall executes (invariant-2 persistence).
        var fell = false
        var delay: UInt64 = 30_000
        for _ in 0..<60 where !fell {
            let verdict = driver.beat(
                bottleneckMbps: 15,
                extraDelayMicros: delay,
                backlogBytes: 60_000
            )
            delay += 8_000
            fell = verdict.change == .overuse
        }
        XCTAssertTrue(fell, "the wall never produced a fall")
        let bandFloor = Double(estimator.capacityBeliefBitsPerSecond ?? 0)
            / 1.10
        // Clean beats follow: the climb recovers but must PARK below
        // the band floor while the cadence holds.
        for _ in 0..<80 {
            driver.beat(bottleneckMbps: 20)
        }
        XCTAssertLessThanOrEqual(
            Double(estimator.rateBitsPerSecond), bandFloor + 0.1e6,
            "the climb re-entered the failed band inside the cadence")
        XCTAssertGreaterThanOrEqual(estimator.stats.upshiftsCadenceHeld, 1)
        // The cadence expires (10 s): the next probe fires and the rate
        // re-enters the band.
        for _ in 0..<360 {
            driver.beat(bottleneckMbps: 20)
        }
        XCTAssertGreaterThan(
            Double(estimator.rateBitsPerSecond), bandFloor,
            "the probe never fired after the cadence expired")
    }

    func testRecoveryClearsFailedProbeBandFromTheOldPath() {
        let estimator = makeEstimator {
            $0.ceilingBitsPerSecond = 50_000_000
            $0.initialRateBitsPerSecond = 20_000_000
        }
        let driver = EstimatorDriver(self, estimator)

        // Establish the 20 Mbps belief, then drive into its headroom
        // band and make that probe fail so the old path owns a live
        // cadence hold and finite band floor.
        for _ in 0..<12 {
            driver.beat(bottleneckMbps: 20)
        }
        for _ in 0..<80 {
            driver.beat(bottleneckMbps: 20)
        }
        var delay: UInt64 = 20_000
        var fell = false
        for _ in 0..<40 where !fell {
            let verdict = driver.beat(
                bottleneckMbps: 12,
                extraDelayMicros: delay,
                backlogBytes: 60_000
            )
            delay += 8_000
            fell = verdict.change == .overuse
        }
        XCTAssertTrue(fell)

        _ = estimator.applyIdrPacing(.halfStaleEstimate, now: driver.now)
        let heldBefore = estimator.stats.upshiftsCadenceHeld
        let rateBefore = estimator.rateBitsPerSecond
        // Fresh new-path evidence may climb immediately once the normal
        // one-second queue-drain hold passes; the old failed-probe band
        // must not impose the remaining ten-second cadence.
        for _ in 0..<60 {
            driver.beat(bottleneckMbps: 30)
        }
        XCTAssertGreaterThan(estimator.rateBitsPerSecond, rateBefore)
        XCTAssertEqual(estimator.stats.upshiftsCadenceHeld, heldBefore,
            "RECOVERY carried an old-path cadence band into the new path")
    }

    // MARK: - A transient Wi-Fi spike
    // One radio episode on an otherwise clean 50 Mbps path: the queue
    // climbs to ~230 ms and drains again inside ~600 ms, nothing is
    // lost, and every full train measured inside the episode reads
    // ~4 Mbps. A draining queue is the path outrunning what we offer,
    // so the episode must not crater the rate, and the rate must be
    // back near the pre-spike level within a few seconds.

    /// Queuing delay per 25 ms report through the episode, µs: it opens
    /// at 42 ms, peaks at 231 ms, and is back to 51 ms 500 ms after the
    /// streak opened (the fall instant of the base law).
    private static let wifiSpikeDelaysMicros: [UInt64] = [
        42_000, 80_000, 120_000, 160_000, 200_000, 231_000, 225_000,
        215_000, 200_000, 185_000, 170_000, 155_000, 140_000, 125_000,
        110_000, 95_000, 85_000, 75_000, 65_000, 58_000, 51_000,
        45_000, 35_000, 25_000, 10_000,
    ]

    /// What one spike scenario did to the standing rate.
    private struct SpikeOutcome {
        var preSpikeRate: Int
        var minimumRate: Int
        /// From the report that opened the spike until the rate stood
        /// at ≥ 90% of the pre-spike rate again (nil: never, or never
        /// left it).
        var recoveryNS: UInt64?
        var overuseFalls: Int
    }

    /// Primes a 50 Mbps path, plays the spike (trains read
    /// `spikeTrainMbps` throughout), then `afterBeats` clean reports.
    private func playWifiSpike(
        spikeTrainMbps: Double = 3.9,
        afterBeats: Int = 1_200
    ) -> SpikeOutcome {
        let estimator = makeEstimator { $0.ceilingBitsPerSecond = 50_000_000 }
        let driver = EstimatorDriver(self, estimator)
        driver.prime(bottleneckMbps: 50, beats: 40)
        let pre = estimator.rateBitsPerSecond
        let spikeStart = driver.now + 25 * Self.ms
        var minimum = pre
        var left = false
        var recovered: UInt64?
        var falls = 0
        func track(_ verdict: RateEstimatorVerdict) {
            if verdict.change == .overuse { falls += 1 }
            minimum = min(minimum, estimator.rateBitsPerSecond)
            if estimator.rateBitsPerSecond * 10 < pre * 9 {
                left = true
                recovered = nil
            } else if left, recovered == nil {
                recovered = driver.now - spikeStart
            }
        }
        for delay in Self.wifiSpikeDelaysMicros {
            track(driver.beat(
                bottleneckMbps: spikeTrainMbps, extraDelayMicros: delay,
                backlogBytes: 19_558))
        }
        for _ in 0..<afterBeats {
            track(driver.beat(bottleneckMbps: 50))
        }
        return SpikeOutcome(
            preSpikeRate: pre, minimumRate: minimum,
            recoveryNS: left ? recovered : 0, overuseFalls: falls)
    }

    /// The live episode: a transient spike whose trains read ~4 Mbps
    /// must not take a 50 Mbps rate below half, and whatever it costs
    /// must be repaid within 3 s of the spike opening.
    func testTransientWifiSpikeNeitherCratersNorLingers() {
        let outcome = playWifiSpike()
        XCTAssertEqual(outcome.preSpikeRate, 50_000_000)
        XCTAssertGreaterThanOrEqual(
            outcome.minimumRate, outcome.preSpikeRate / 2,
            """
                one transient spike took the rate from \
                \(outcome.preSpikeRate / 1_000) to \
                \(outcome.minimumRate / 1_000) kbps
                """)
        let recovery = outcome.recoveryNS ?? .max
        XCTAssertLessThanOrEqual(
            recovery, 3_000 * Self.ms,
            """
                back to ≥ 90% after \
                \(outcome.recoveryNS.map { "\($0 / Self.ms) ms" } ?? "never")
                """)
    }

    /// A GENUINE dip: the path really delivers 5 Mbps for 1.5 s under a
    /// standing queue, then the air clears back to 50 Mbps. The fall
    /// must still land on measured delivery (the safeguard), and once
    /// the air clears the rate must be back at ≥ 90% within 4 s — a
    /// crash is not a failed probe, and the climb back to a rate the
    /// path carried moments ago need not creep at 10%/s.
    func testGenuineWifiDipFallsThenRecoversWithinSeconds() {
        let estimator = makeEstimator { $0.ceilingBitsPerSecond = 50_000_000 }
        let driver = EstimatorDriver(self, estimator)
        driver.prime(bottleneckMbps: 50, beats: 40)
        let pre = estimator.rateBitsPerSecond
        var minimum = pre
        for _ in 0..<60 {
            driver.beat(bottleneckMbps: 5, extraDelayMicros: 40_000,
                        backlogBytes: 19_558)
            minimum = min(minimum, estimator.rateBitsPerSecond)
        }
        XCTAssertLessThanOrEqual(minimum, Int(5e6),
            "a genuine 1.5 s dip to 5 Mbps must fall to measured delivery")
        let clearedAt = driver.now
        var recovered: UInt64?
        for _ in 0..<1_200 where recovered == nil {
            driver.beat(bottleneckMbps: 50)
            if estimator.rateBitsPerSecond * 10 >= pre * 9 {
                recovered = driver.now - clearedAt
            }
        }
        XCTAssertLessThanOrEqual(recovered ?? .max, 4_000 * Self.ms,
            """
                back to ≥ 90% \
                \(recovered.map { "\($0 / Self.ms) ms" } ?? "never") after \
                the air cleared
                """)
    }

    /// A spike that is still RISING when invariant 2's clock expires
    /// (40 → 230 ms over 500 ms, trains at 3.9 Mbps) is, at that
    /// instant, indistinguishable from a real squeeze and falls. The
    /// queue then drains in 100 ms and the air is clean again: the rate
    /// must be back at ≥ 90% within 5 s of the spike opening (the
    /// spike, the 1 s drain hold every fall owes, then the climb).
    func testRisingSpikeFallsButRecoversWithinSeconds() {
        let estimator = makeEstimator { $0.ceilingBitsPerSecond = 50_000_000 }
        let driver = EstimatorDriver(self, estimator)
        driver.prime(bottleneckMbps: 50, beats: 40)
        let pre = estimator.rateBitsPerSecond
        let opened = driver.now
        var fell = false
        for step in 0..<24 {
            let delay = UInt64(40_000 + step * 8_000)
            let verdict = driver.beat(
                bottleneckMbps: 3.9, extraDelayMicros: delay,
                backlogBytes: 19_558)
            fell = fell || verdict.change == .overuse
        }
        XCTAssertTrue(fell, "a queue rising for 600 ms is a squeeze until proven otherwise")
        for delay: UInt64 in [180_000, 120_000, 60_000, 10_000] {
            driver.beat(bottleneckMbps: 50, extraDelayMicros: delay)
        }
        var recovered: UInt64?
        for _ in 0..<1_200 where recovered == nil {
            driver.beat(bottleneckMbps: 50)
            if estimator.rateBitsPerSecond * 10 >= pre * 9 {
                recovered = driver.now - opened
            }
        }
        XCTAssertLessThanOrEqual(recovered ?? .max, 5_000 * Self.ms,
            """
                back to ≥ 90% \
                \(recovered.map { "\($0 / Self.ms) ms" } ?? "never") after \
                the spike opened
                """)
    }

    /// Live Wi-Fi's common case: the rate sits at the ceiling, where the
    /// belief sits too, and a 1.2 s radio episode (a flat 150 ms queue)
    /// stretches the trains to ~30 Mbps. The fall lands on that honest
    /// evidence — but the rate was not probing above anything it knew,
    /// so no wall was located and no cadence may park the climb at the
    /// demoted band for 10 s once the air clears.
    func testFallFromTheBeliefIsNotAFailedProbe() {
        let estimator = makeEstimator { $0.ceilingBitsPerSecond = 50_000_000 }
        let driver = EstimatorDriver(self, estimator)
        driver.prime(bottleneckMbps: 50, beats: 40)
        let pre = estimator.rateBitsPerSecond
        XCTAssertEqual(estimator.capacityBeliefBitsPerSecond, pre)
        var fell = false
        for _ in 0..<48 {
            fell = driver.beat(
                bottleneckMbps: 30, extraDelayMicros: 150_000,
                backlogBytes: 19_558
            ).change == .overuse || fell
        }
        XCTAssertTrue(fell, "a 1.2 s standing queue with honest trains falls")
        let clearedAt = driver.now
        var recovered: UInt64?
        for _ in 0..<1_200 where recovered == nil {
            driver.beat(bottleneckMbps: 50)
            if estimator.rateBitsPerSecond * 10 >= pre * 9 {
                recovered = driver.now - clearedAt
            }
        }
        XCTAssertEqual(estimator.stats.upshiftsCadenceHeld, 0,
            "a fall from the belief armed the failed-probe cadence")
        XCTAssertLessThanOrEqual(recovered ?? .max, 4_000 * Self.ms,
            """
                back to ≥ 90% \
                \(recovered.map { "\($0 / Self.ms) ms" } ?? "never") after \
                the air cleared
                """)
    }

    /// A full train is evidence for the sample window, not forever. A
    /// static desktop sends only micro-train frames for minutes; the
    /// reporting anchor and a fall's forensic anchor must then read
    /// "none", never the last full train from minutes ago.
    func testStaleFullTrainsNeitherReportNorAnchor() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0
        func beat(count: Int, mbps: Double, delay: UInt64 = 0)
            -> RateEstimatorVerdict {
            now += 25 * Self.ms
            clientMicros += 25_000
            let samples = train(
                estimator, seqStart: seq, count: count,
                sendStartNS: now - Self.ms,
                bottleneckBitsPerSecond: mbps * 1e6,
                extraDelayMicros: delay)
            seq += count
            return estimator.ingest(
                report(samples: samples, clientMicros: clientMicros),
                now: now, inRecovery: false)
        }
        for _ in 0..<10 { _ = beat(count: 12, mbps: 20) }
        XCTAssertNotNil(estimator.measuredDeliveryRateBitsPerSecond)
        // Twelve seconds of micro-train frames only.
        for _ in 0..<480 { _ = beat(count: 4, mbps: 20) }
        XCTAssertNil(estimator.measuredDeliveryRateBitsPerSecond,
            "a full train from 12 s ago still reports as measured delivery")
        // A persisted streak with no backlog falls (bounded
        // multiplicative); its forensics must not cite the stale train.
        var fell = false
        for _ in 0..<40 where !fell {
            fell = beat(count: 4, mbps: 20, delay: 40_000).change == .overuse
        }
        XCTAssertTrue(fell)
        XCTAssertNil(estimator.lastOveruseFall?.anchorBitsPerSecond,
            "the fall's anchor cited a full train from 12 s ago")
    }

    /// The fast climb's safeguard: when the path STAYS low after a
    /// crash, trains keep measuring it, the belief stays there, and the
    /// climb parks at belief × headroom — it never races back toward the
    /// pre-crash rate on the strength of a memory.
    func testRecoveryClimbParksWhenThePathStaysLow() {
        let estimator = makeEstimator { $0.ceilingBitsPerSecond = 50_000_000 }
        let driver = EstimatorDriver(self, estimator)
        driver.prime(bottleneckMbps: 50, beats: 40)
        let fall = driver.beatUntilFall(
            bottleneckMbps: 5, extraDelayMicros: 40_000,
            backlogBytes: 19_558)
        XCTAssertEqual(fall.change, .overuse)
        // The queue clears (we now send below the path) but the path
        // still delivers only 5 Mbps: every train measures ≤ 5.
        for _ in 0..<400 {
            let paceMbps = Double(estimator.rateBitsPerSecond) / 1e6
            driver.beat(bottleneckMbps: min(paceMbps, 5))
            XCTAssertLessThanOrEqual(estimator.rateBitsPerSecond,
                Int(5e6 * 1.10) + 100_000,
                "the climb outran what the path proved")
        }
    }
}

private func XCTAssertEqual(
    _ value: Int, _ expected: Int, accuracy: Int,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertLessThanOrEqual(
        abs(value - expected), accuracy,
        "\(value) not within \(accuracy) of \(expected)",
        file: file, line: line
    )
}
