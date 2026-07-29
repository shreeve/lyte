import XCTest
import HostCore
import HostWire
import LyteWire
import LyteWireTestKit

// THE GATE (build plan HS-16 row: "congestion estimator — delivery rate,
// queuing delay, RECOVERY verdicts, IdrPacing numbers"). Pinned
// behaviors, each a leg below:
//
//   • delivery rate is MEASURED from dispersion trains matched against
//     the send ledger (resiliency §2.2's packet-train reading), and
//     short trains are weighted down, not trusted;
//   • the rate falls fast on loss (multiplicative, rate-limited to one
//     downshift per 500 ms, never below the 500 kbps floor) and on
//     queuing-delay inflation (anchored to the measured delivery rate),
//     and rises only on evidence (fresh delivery samples), ≤10%/s,
//     never above the negotiated ceiling;
//   • the estimator owns W4b's RECOVERY window verdicts now (the HS-11
//     25 ms stub is retired): loss inside a window honestly holds
//     RECOVERY where the stub would have graduated on mere presence;
//   • the machine's IdrPacing policies get numbers: WAKE at
//     min(btlRate, lastGoodRate), RECOVERY at max(floor, ½ × stale
//     estimate), applied to the shared pacer the moment the machine
//     demands them;
//   • frameByteCeiling tracks the LIVE estimate (the HS-6 math:
//     R×B/8 − higherClassBytes, B = min(2/fps, 25 ms));
//   • THE CADENCE GATE, HS-15's R-G8 shape under a rate crash: a loss
//     burst crashes the send rate mid-stream and audio inter-send
//     stays 5 ms ± 2 ms at p99 throughout — rate changes re-cap
//     video, never audio's cadence (structural, proven here).

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
                channel: .videoActive, seq: seq, bytes: bytes, now: sendNS
            )
            let arrival = Self.clockOffsetMicros
                + sendStartNS / 1_000
                + UInt64(Double(i) * arrivalSpacing)
                + extraDelayMicros
            samples.append(FeedbackReport.Dispersion.Sample(
                channel: .videoActive, seq: seq,
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

    // MARK: Leg 1 — delivery rate is measured, not hoped

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
                     "one clean report must not move the standing rate "
                     + "already at the ceiling")
        let measured = estimator.deliveryRateBitsPerSecond
        XCTAssertNotNil(measured)
        XCTAssertEqual(Double(measured!), 8e6, accuracy: 0.4e6,
                       "delivery rate must read the arrival spacing")
        XCTAssertEqual(estimator.stats.deliverySamples, 1)
        XCTAssertEqual(estimator.stats.dispersionSamplesMatched, 40)
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
                             "the max window keeps the burst sample — "
                             + "the control law's probe is untouched")
        let reported = estimator.measuredDeliveryRateBitsPerSecond
        XCTAssertNotNil(reported)
        XCTAssertEqual(Double(reported!), 8e6, accuracy: 0.4e6,
                       "the reported delivery is the full-train median "
                       + "— a lone clumped burst cannot print as the "
                       + "session's delivery rate")
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

    // MARK: Leg 2 — falls fast on loss, floors, re-rises on evidence

    func testLossBurstFallsMultiplicativelyAndReconverges() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var received: UInt32 = 0
        var missing: UInt32 = 0
        var seq = 0

        func beat(lossPerHundred: UInt32) -> RateEstimatorVerdict {
            now += 25 * Self.ms
            clientMicros += 25_000
            received += 100 - lossPerHundred
            missing += lossPerHundred
            let samples = train(
                estimator, seqStart: seq, count: 12,
                sendStartNS: now - Self.ms,
                bottleneckBitsPerSecond: 18e6
            )
            seq += 12
            return estimator.ingest(
                report(samples: samples, clientMicros: clientMicros,
                       channels: lossLedger(received: received, missing: missing)),
                now: now, inRecovery: false
            )
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
                        "falls after the 1 s loss window drained "
                        + "would be invented loss")
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

        print("HS-16 gate (loss): 5% HELD at \(Self.ceiling / 1_000) kbps "
            + "(FEC's band); 20% burst → "
            + "\(downshiftRates.map { "\($0 / 1_000)" }.joined(separator: " → "))"
            + " kbps; re-converged to \(lastRate / 1_000) kbps "
            + "after \(estimator.stats.upshifts) evidence climbs")
    }

    /// The floor-deadlock the live gate caught: at 500 kbps the pacer
    /// spaces full-size datagrams ~18 ms apart, so a FIXED train-split
    /// gap never sees a train, no delivery sample ever forms, and the
    /// rate can never earn its way back up. The gap must scale with
    /// the standing rate so paced-at-R spacing still reads as a train.
    func testClimbsBackFromTheFloorOnPacedEvidence() {
        let estimator = makeEstimator()
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
            "paced evidence at the floor must still form delivery "
            + "samples and let the rate climb")
        XCTAssertGreaterThan(estimator.rateBitsPerSecond, 500_000)
    }

    func testRateNeverLeavesTheFloorCeilingBand() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var received: UInt32 = 100
        var missing: UInt32 = 0
        // Prime totals.
        _ = estimator.ingest(
            report(samples: [], clientMicros: 1_000,
                   channels: lossLedger(received: received, missing: missing)),
            now: Self.ms, inRecovery: false
        )
        // Relentless 50% loss for a minute of virtual time.
        for _ in 0..<120 {
            now += 500 * Self.ms
            clientMicros += 500_000
            received += 50
            missing += 50
            _ = estimator.ingest(
                report(samples: [], clientMicros: clientMicros,
                       channels: lossLedger(received: received, missing: missing)),
                now: now, inRecovery: false
            )
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, 500_000,
                       "the floor holds — a paced IDR stays possible")
    }

    // MARK: Leg 3 — queuing-delay inflation is overuse

    func testDelayInflationDownshiftsAnchoredToMeasuredDelivery() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        func beat(extraDelayMicros: UInt64) -> RateEstimatorVerdict {
            now += 25 * Self.ms
            clientMicros += 25_000
            let samples = train(
                estimator, seqStart: seq, count: 12,
                sendStartNS: now - Self.ms,
                bottleneckBitsPerSecond: 10e6,
                extraDelayMicros: extraDelayMicros
            )
            seq += 12
            return estimator.ingest(
                report(samples: samples, clientMicros: clientMicros),
                now: now, inRecovery: false
            )
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
                       "the overuse fall anchors to measured delivery, "
                       + "not to the configured rate")
        XCTAssertGreaterThanOrEqual(
            estimator.queuingDelayMicroseconds ?? 0, 20_000
        )

        print("HS-16 gate (overuse): 25 ms inflation over baseline → "
            + "\(newRate! / 1_000) kbps (0.85 × the 10 Mbps the path "
            + "measurably delivered)")
    }

    // MARK: Leg 3b — HS-21: the overuse anchor is robust to one garbage
    // delivery sample (the HS-20 live finding: a lone garbage short-train
    // sample anchored an overuse fall and cratered a clean 20 Mbps path to
    // 810 kbps in a single step). The anchor is now the MEDIAN of the last
    // few raw samples, so the freshest sample cannot decide the fall alone.

    /// A clean 20 Mbps path, overuse fires on a report whose ONLY
    /// delivery sample is garbage-low — the fall must anchor to the
    /// clean median the window still holds, never to the lone outlier.
    func testOveruseAnchorRejectsOneGarbageDeliverySample() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        // Ten clean 20 Mbps reports: the standing rate stays at the
        // ceiling and the raw-delivery window fills with 20 Mbps
        // samples (and the delay baseline is established).
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

        // Arm: one inflated report, still a clean 20 Mbps train.
        now += 25 * Self.ms; clientMicros += 25_000
        let arm = train(
            estimator, seqStart: seq, count: 12,
            sendStartNS: now - Self.ms,
            bottleneckBitsPerSecond: 20e6, extraDelayMicros: 40_000
        )
        seq += 12
        XCTAssertFalse(estimator.ingest(
            report(samples: arm, clientMicros: clientMicros),
            now: now, inRecovery: false
        ).overuse)

        // Fire: inflated reports whose ONLY delivery samples are
        // garbage short trains measuring ~2 Mbps. The one-deep anchor
        // of old would fall to 0.85 × 2 Mbps = 1.7 Mbps (a crater);
        // the median of the last three raw samples is still 20 Mbps
        // (garbage outvoted), so when the dwell deferral's budget
        // expires the fall lands at 0.85 × 20 Mbps.
        var verdict: RateEstimatorVerdict
        var deferredBeats = 0
        repeat {
            now += 25 * Self.ms; clientMicros += 25_000
            let garbage = train(
                estimator, seqStart: seq, count: 4,
                sendStartNS: now - Self.ms,
                bottleneckBitsPerSecond: 2e6, extraDelayMicros: 40_000
            )
            seq += 4
            verdict = estimator.ingest(
                report(samples: garbage, clientMicros: clientMicros),
                now: now, inRecovery: false
            )
            deferredBeats += 1
        } while verdict.newRateBitsPerSecond == nil && deferredBeats < 30
        XCTAssertGreaterThanOrEqual(estimator.stats.fallDeferrals, 1,
            "the persistence held the uncorroborated beats first")
        XCTAssertTrue(verdict.overuse)
        XCTAssertEqual(verdict.change, .overuse)
        let newRate = verdict.newRateBitsPerSecond
        XCTAssertNotNil(newRate)
        XCTAssertGreaterThan(Double(newRate!), 10e6,
            "one garbage delivery sample must not crater the rate — "
            + "the anchor is the clean median, not the lone outlier "
            + "(got \(newRate! / 1_000) kbps)")
        XCTAssertEqual(Double(newRate!), 20e6 * 0.85, accuracy: 1.0e6,
            "the fall anchors to the 20 Mbps the median still measures")

        print("HS-21 gate (garbage anchor): lone 2 Mbps sample at the "
            + "overuse fire → \(newRate! / 1_000) kbps (median-anchored "
            + "to 20 Mbps; the one-deep anchor would have cratered to "
            + "~1,700 kbps)")
    }

    /// The regression pin: a GENUINE sustained overuse — delivery truly
    /// drops to ~5 Mbps for the whole run — still falls fast and anchors
    /// to the measured delivery, exactly as the one-deep anchor did. By
    /// the time overuse fires (two consecutive inflated reports), two
    /// recent 5 Mbps samples already dominate the 3-median.
    func testGenuineSustainedOveruseStillFallsToMeasuredDelivery() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        func beat(mbps: Double, inflate: Bool) -> RateEstimatorVerdict {
            now += 25 * Self.ms; clientMicros += 25_000
            let samples = train(
                estimator, seqStart: seq, count: 12,
                sendStartNS: now - Self.ms,
                bottleneckBitsPerSecond: mbps * 1e6,
                extraDelayMicros: inflate ? 40_000 : 0
            )
            seq += 12
            return estimator.ingest(
                report(samples: samples, clientMicros: clientMicros),
                now: now, inRecovery: false
            )
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
            "genuine sustained overuse still anchors to the 5 Mbps the "
            + "path measurably delivers — the fast fall is intact")

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

        print("HS-21 gate (genuine fall): sustained 5 Mbps squeeze → "
            + "first fall \(first.newRateBitsPerSecond! / 1_000) kbps "
            + "(0.85 × measured), \(falls) falls total, settled at "
            + "\(estimator.rateBitsPerSecond / 1_000) kbps")
    }

    // MARK: Leg 3c — HS-22: only FULL trains vote on the anchor (the
    // live clean-path crater: audio's 4+2 groups arrive as 2–3-packet
    // micro-trains that measure their own ~1 Mbps pacing, not the path,
    // and TWO of them in the 3-sample window outvoted the genuine
    // 20 Mbps sample — the HS-21 median fell exactly where it promised
    // not to. Short trains keep feeding the ×0.5 windowed-max and
    // evidence freshness; they just get no anchor vote.)

    /// A clean 20 Mbps path, but the reports leading into the overuse
    /// fire carry only short audio-paced micro-trains: a MAJORITY of
    /// the anchor window would be garbage under HS-21 alone. The fall
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
        // measuring its own pacing). Under the HS-21 median alone the
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
            "a micro-train MAJORITY must not crater the rate — the "
            + "anchor votes are full trains only "
            + "(got \(newRate! / 1_000) kbps)")

        print("HS-22 gate (micro-train majority): two 4-packet ~1 Mbps "
            + "audio-paced samples at the overuse fire → "
            + "\(newRate! / 1_000) kbps (full-train-anchored to 20 Mbps; "
            + "the HS-21 median alone would have cratered to ~850 kbps)")
    }

    // MARK: Leg 3d — HS-22c: the self-reference gate (finding (ii)).
    // Under a squeezed pacer every multi-quantum frame drains as one
    // ≥8-packet train paced at exactly the standing rate — a FULL train
    // that measures our own pacing, not the path. The live probe: an
    // overuse verdict anchored 0.85 × self, the fall re-squeezed the
    // pacer, the next train measured the new self, and a 90 Mbps wire
    // spiraled to the 500 kbps floor. With standing backlog and an
    // anchor at ≈ (or above) the standing rate, an overuse verdict may
    // HOLD the rate (rises stay blocked), never anchor a fall — unless
    // corroborated by something a self-limited pacer cannot produce:
    // loss, post-FEC evidence, or queue growth across the streak.

    /// One beat of the self-reference shape: a full train at
    /// `bottleneckMbps`, `extraDelayMicros` of standing queue, the
    /// given backlog, optional loss.
    private func selfRefBeat(
        _ now: inout UInt64, _ clientMicros: inout UInt64,
        _ seq: inout Int, on estimator: RateEstimator,
        bottleneckMbps: Double, extraDelayMicros: UInt64,
        backlogBytes: Int,
        channels: [FeedbackReport.ChannelStats] = [],
        nacks: [FeedbackReport.NackEntry] = []
    ) -> RateEstimatorVerdict {
        now += 25 * Self.ms
        clientMicros += 25_000
        let samples = train(
            estimator, seqStart: seq, count: 12,
            sendStartNS: now - Self.ms,
            bottleneckBitsPerSecond: bottleneckMbps * 1e6,
            extraDelayMicros: extraDelayMicros
        )
        seq += 12
        return estimator.ingest(
            report(samples: samples, clientMicros: clientMicros,
                   channels: channels, nacks: nacks),
            now: now, inRecovery: false,
            pacerBacklogBytes: backlogBytes
        )
    }

    /// THE HS-22c HEADLINE: standing backlog, full trains measuring
    /// exactly the standing 20 Mbps, constant (non-growing) inflation,
    /// zero loss — the probe's floor-crash shape. A whole second of
    /// overuse verdicts must not move the rate ONCE: every fall is a
    /// self-reference hold, and the spiral (0.85ⁿ to the floor, which
    /// the old law walked within these same beats) is dead.
    func testSelfReferentialOveruseHoldsInsteadOfSpiraling() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        // Ten clean 20 Mbps trains: baseline delay, anchor window full
        // of ≈standing-rate samples.
        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        // 40 beats (1 s) of inflated reports with standing backlog:
        // the trains still measure our own 20 Mbps pacing, inflation
        // sits flat at 40 ms (a burst bump, not a building queue).
        var overuseVerdicts = 0
        for _ in 0..<40 {
            let verdict = selfRefBeat(
                &now, &clientMicros, &seq, on: estimator,
                bottleneckMbps: 20, extraDelayMicros: 40_000,
                backlogBytes: 40_000
            )
            if verdict.overuse { overuseVerdicts += 1 }
            XCTAssertNil(verdict.newRateBitsPerSecond,
                "a self-referential overuse verdict must hold, not fall")
        }
        XCTAssertGreaterThanOrEqual(overuseVerdicts, 30,
            "the overuse verdicts genuinely fired — the gate held the "
            + "FALL, not the detector")
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling,
            "the rate never moved — the 500 kbps spiral is dead")
        XCTAssertEqual(estimator.stats.downshifts, 0)
        XCTAssertGreaterThanOrEqual(estimator.stats.selfReferenceHolds, 1)

        print("HS-22c gate (self-reference): \(overuseVerdicts) overuse "
            + "verdicts over 1 s at anchor ≈ standing rate with backlog "
            + "→ 0 falls, \(estimator.stats.selfReferenceHolds) holds, "
            + "rate pinned at \(estimator.rateBitsPerSecond / 1_000) kbps "
            + "(the old law reached the floor in these beats)")
    }

    /// Real degradation whose capacity sits AT the standing rate: the
    /// anchor is self-shaped, but the queue GROWS across the streak —
    /// the deficit signature a self-limited pacer cannot produce. The
    /// fall must proceed, one report after the growth clears the
    /// threshold (inside the same 500 ms fall-limiter window).
    func testQueueGrowthCorroboratesARealSqueezeNearTheRate() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }

        // The streak opens at 25 ms of inflation…
        XCTAssertNil(selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 20, extraDelayMicros: 25_000,
            backlogBytes: 40_000
        ).newRateBitsPerSecond)
        // …the second report shows the queue BUILT another 20 ms
        // (past the 15 ms overuse threshold): corroborated, but still
        // dwell-SHAPED (rising dwells mimic growth), so the deferral
        // holds while its budget lasts — and the queue keeps building
        // with NO drain, so the fall lands at 0.85 × the standing rate
        // despite the self-shaped anchor.
        var verdict = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 20, extraDelayMicros: 45_000,
            backlogBytes: 40_000
        )
        var extraDelay: UInt64 = 45_000
        var deferredBeats = 0
        while verdict.newRateBitsPerSecond == nil, deferredBeats < 30 {
            extraDelay += 3_000 // keeps growing, stays under the ceiling
            verdict = selfRefBeat(
                &now, &clientMicros, &seq, on: estimator,
                bottleneckMbps: 20, extraDelayMicros: extraDelay,
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
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0
        var received: UInt32 = 0
        var missing: UInt32 = 0

        for _ in 0..<10 {
            received += 100
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0,
                            channels: lossLedger(received: received,
                                                 missing: missing))
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        // Two inflated reports, constant 40 ms, but the wire now drops
        // 15 datagrams per beat — ~2.7% over the rolling 1 s window at
        // fire time, past the 2% clean bar (FEC's hold band for the
        // LOSS branch, but honest corroboration for the overuse one).
        received += 85; missing += 15
        XCTAssertNil(selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 20, extraDelayMicros: 40_000,
            backlogBytes: 40_000,
            channels: lossLedger(received: received, missing: missing)
        ).newRateBitsPerSecond)
        received += 85; missing += 15
        let verdict = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 20, extraDelayMicros: 40_000,
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
    /// exactly as HS-21 pinned — standing backlog alone must never
    /// blind the estimator to a path that measurably slowed.
    func testGenuineDipWithBacklogStillFallsToMeasuredDelivery() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }

        // The path genuinely drops to 5 Mbps; the pacer (still at 20)
        // holds backlog the whole time. Arm, ride out the dwell
        // deferral's budget (the honesty cost), then fire.
        XCTAssertNil(selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 5, extraDelayMicros: 40_000,
            backlogBytes: 40_000
        ).newRateBitsPerSecond)
        var verdict = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 5, extraDelayMicros: 40_000,
            backlogBytes: 40_000
        )
        var deferredBeats = 0
        while verdict.newRateBitsPerSecond == nil, deferredBeats < 30 {
            verdict = selfRefBeat(
                &now, &clientMicros, &seq, on: estimator,
                bottleneckMbps: 5, extraDelayMicros: 40_000,
                backlogBytes: 40_000
            )
            deferredBeats += 1
        }
        XCTAssertTrue(verdict.overuse)
        XCTAssertNotNil(verdict.newRateBitsPerSecond)
        XCTAssertEqual(Double(verdict.newRateBitsPerSecond!), 5e6 * 0.85,
            accuracy: 1.0e6,
            "an honestly low anchor falls to measured delivery — the "
            + "gate reads the evidence, it does not read the backlog")
        XCTAssertEqual(estimator.stats.selfReferenceHolds, 0)

        print("HS-22c gate (honest dip under backlog): 20 → 5 Mbps path "
            + "with standing backlog → fall to "
            + "\(verdict.newRateBitsPerSecond! / 1_000) kbps "
            + "(0.85 × measured), zero self-reference holds")
    }

    // MARK: Leg 3e — HS-23: the stall gate (the Wi-Fi study's receiver
    // dwells). The client's radio goes dark 70–100 ms, the AP queues
    // everything, then drains it in one compressed burst — nothing
    // lost, nothing slow, the path merely time-shifted. Host-side that
    // cycle is textbook overuse (two inflated reports, an anchor, a
    // fall twice a second forever — the 13–17 Mbps pin). The gate
    // refuses the fall when the evidence spells a CLOSED HOLE: streak
    // peak ≤ 150 ms, a fresh full train at ≥ 1.25 × the standing rate
    // (only accumulated-then-released packets can read above our own
    // pace), and conservation (loss clean, zero post-FEC). Growth does
    // NOT defeat it — rising dwells mimic growth — but a hole past the
    // ceiling, a drain below the pace, or any loss falls as ever.

    /// THE HS-23 HEADLINE: repeated sub-150 ms gap-burst cycles — the
    /// scan-stall cadence — must not move the rate ONCE. Each cycle:
    /// two dwell reports (80 ms of held delay, drain measured at
    /// 200 Mbps — far above the 20 Mbps pace), then clean beats.
    func testStallCyclesRideThroughWithoutAnchoringDown() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        var overuseVerdicts = 0
        for _ in 0..<10 {
            for _ in 0..<2 {
                let verdict = selfRefBeat(
                    &now, &clientMicros, &seq, on: estimator,
                    bottleneckMbps: 200, extraDelayMicros: 80_000,
                    backlogBytes: 0
                )
                if verdict.overuse { overuseVerdicts += 1 }
                XCTAssertNil(verdict.newRateBitsPerSecond,
                    "a closed hole must hold the rate, never anchor a fall")
            }
            for _ in 0..<6 {
                _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                                bottleneckMbps: 20, extraDelayMicros: 0,
                                backlogBytes: 0)
            }
        }
        XCTAssertGreaterThanOrEqual(overuseVerdicts, 10,
            "the overuse verdicts genuinely fired — the gate held the "
            + "FALL, not the detector")
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling,
            "the estimator rode through every stall cycle")
        XCTAssertEqual(estimator.stats.downshifts, 0)
        XCTAssertGreaterThanOrEqual(estimator.stats.stallHolds, 10)

        print("HS-23 gate (stall ride-through): 10 gap-burst cycles "
            + "(80 ms holes, 200 Mbps drains) → \(overuseVerdicts) "
            + "overuse verdicts, \(estimator.stats.stallHolds) stall "
            + "holds, 0 falls, rate pinned at "
            + "\(estimator.rateBitsPerSecond / 1_000) kbps (the old law "
            + "fell twice a second on this shape, forever)")
    }

    /// A dwell TRAIN with rising peaks (70 → 90 ms) mimics queue
    /// growth report-to-report — the exact signature the self-reference
    /// gate treats as corroboration. The stall gate must not be
    /// defeated by it: the drain evidence (super-rate full trains) and
    /// the bounded peak are the stronger reading.
    func testRisingDwellTrainHoldsDespiteGrowthSignature() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }

        XCTAssertNil(selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 200, extraDelayMicros: 70_000,
            backlogBytes: 0
        ).newRateBitsPerSecond)
        // +20 ms past the streak's opening — queueGrew reads true, and
        // pre-HS-23 this beat fell.
        let verdict = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 200, extraDelayMicros: 90_000,
            backlogBytes: 0
        )
        XCTAssertTrue(verdict.overuse)
        XCTAssertNil(verdict.newRateBitsPerSecond,
            "rising dwells are not a building queue — the drain says "
            + "the hole closed")
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
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        // Mid-dwell: two inflated reports whose trains still measure
        // our own 20 Mbps pace — the hole has NOT closed, so no
        // super-rate drain exists yet. Pre-deferral, this beat fell.
        XCTAssertNil(selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 20, extraDelayMicros: 80_000,
            backlogBytes: 0
        ).newRateBitsPerSecond)
        let midDwell = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 20, extraDelayMicros: 80_000,
            backlogBytes: 0
        )
        XCTAssertTrue(midDwell.overuse)
        XCTAssertNil(midDwell.newRateBitsPerSecond,
            "the verdict fired mid-dwell — the deferral holds the fall "
            + "so the drain can testify")
        XCTAssertGreaterThanOrEqual(estimator.stats.fallDeferrals, 1)

        // The hole closes: the drain arrives compressed at 200 Mbps.
        // The stall gate reads the closed hole and holds as designed.
        let drained = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 200, extraDelayMicros: 80_000,
            backlogBytes: 0
        )
        XCTAssertNil(drained.newRateBitsPerSecond,
            "the drain proves the hole closed — stall hold, no fall")
        XCTAssertGreaterThanOrEqual(estimator.stats.stallHolds, 1)
        XCTAssertEqual(estimator.stats.downshifts, 0)
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling,
            "the dwell cost ZERO rate moves — and therefore zero "
            + "VBV-forced IDRs")

        print("ramp-hunt gate (dwell deferral): mid-dwell verdict "
            + "deferred, drain testified one report later → "
            + "\(estimator.stats.fallDeferrals) deferral, "
            + "\(estimator.stats.stallHolds) stall hold(s), 0 falls, "
            + "rate pinned at \(estimator.rateBitsPerSecond / 1_000) kbps")
    }

    /// A hole past the 150 ms ceiling is sustained degradation, not a
    /// dwell — the fall proceeds exactly as before the gate existed.
    func testHoleBeyondTheCeilingFallsAsEver() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }

        XCTAssertNil(selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 200, extraDelayMicros: 400_000,
            backlogBytes: 0
        ).newRateBitsPerSecond)
        // The pressure never clears (a real outage, not a dwell that
        // drains), so invariant 2's persistence is satisfied within
        // one extra fall-limiter beat and the fall bites.
        var verdict = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 200, extraDelayMicros: 400_000,
            backlogBytes: 0
        )
        XCTAssertTrue(verdict.overuse)
        var beats = 0
        while verdict.newRateBitsPerSecond == nil, beats < 30 {
            verdict = selfRefBeat(
                &now, &clientMicros, &seq, on: estimator,
                bottleneckMbps: 200, extraDelayMicros: 400_000,
                backlogBytes: 0
            )
            beats += 1
        }
        XCTAssertEqual(verdict.change, .overuse)
        XCTAssertEqual(Double(verdict.newRateBitsPerSecond!),
                       20e6 * 0.85, accuracy: 1.0e6,
            "a 400 ms hole is an outage, not a scan dwell — bite")
        XCTAssertEqual(estimator.stats.stallHolds, 0)
    }

    /// Sustained rate reduction in the stall gate's own terms: the
    /// "drain" measures BELOW the pace (8 Mbps under a 20 Mbps rate) —
    /// a capacity-limited bottleneck spaces arrivals at capacity, and
    /// no super-rate train exists to plead a closed hole. Falls to
    /// measured delivery exactly as HS-21 pinned.
    func testDrainBelowThePaceIsARealSqueezeAndFalls() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }

        XCTAssertNil(selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 8, extraDelayMicros: 40_000,
            backlogBytes: 0
        ).newRateBitsPerSecond)
        // The verdict beats are deferred (dwell-shaped); the sub-pace
        // drain never improves, so the budget expires and the fall
        // bites.
        var verdict = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 8, extraDelayMicros: 40_000,
            backlogBytes: 0
        )
        var deferredBeats = 0
        while verdict.newRateBitsPerSecond == nil, deferredBeats < 30 {
            verdict = selfRefBeat(
                &now, &clientMicros, &seq, on: estimator,
                bottleneckMbps: 8, extraDelayMicros: 40_000,
                backlogBytes: 0
            )
            deferredBeats += 1
        }
        XCTAssertNotNil(verdict.newRateBitsPerSecond)
        XCTAssertEqual(Double(verdict.newRateBitsPerSecond!),
                       8e6 * 0.85, accuracy: 1.0e6)
        XCTAssertEqual(estimator.stats.stallHolds, 0)
    }

    /// Conservation is the third leg: a gap-burst shape WITH loss is a
    /// congested queue tail-dropping, not a hole that closed — the
    /// fall proceeds despite the bounded peak and the super-rate drain.
    func testLossDefeatsTheStallHold() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0
        var received: UInt32 = 0
        var missing: UInt32 = 0

        for _ in 0..<10 {
            received += 100
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0,
                            channels: lossLedger(received: received,
                                                 missing: missing))
        }

        received += 85; missing += 15
        XCTAssertNil(selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 200, extraDelayMicros: 80_000,
            backlogBytes: 0,
            channels: lossLedger(received: received, missing: missing)
        ).newRateBitsPerSecond)
        received += 85; missing += 15
        let verdict = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 200, extraDelayMicros: 80_000,
            backlogBytes: 0,
            channels: lossLedger(received: received, missing: missing)
        )
        XCTAssertTrue(verdict.overuse)
        XCTAssertNotNil(verdict.newRateBitsPerSecond,
            "packets died — the hole did not close, the queue dropped")
        XCTAssertEqual(estimator.stats.stallHolds, 0)
    }

    /// A closed hole ECHOES as a few NACKs: the client's completion
    /// presumption expires mid-dwell, moments before the drain makes
    /// the frame whole (the first live gate judged 30 of 35 NACK
    /// entries stale). Post-FEC evidence inside the regime ladder's
    /// own clean column (< 0.5%) must not defeat the hold — but a
    /// rung-3-scale NACK storm still bites through its own ungated
    /// branch.
    func testNackEchoInsideTheHoleStillHolds() throws {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0
        var received: UInt32 = 0

        for _ in 0..<10 {
            received += 400
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0,
                            channels: lossLedger(received: received,
                                                 missing: 0))
        }

        // The dwell, echoing as one 2-shard NACK: 2 / ~4,800 attempted
        // ≈ 0.04% post-FEC — deep inside the clean column.
        received += 400
        XCTAssertNil(selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 200, extraDelayMicros: 80_000,
            backlogBytes: 0,
            channels: lossLedger(received: received, missing: 0),
            nacks: [try FeedbackReport.NackEntry(
                frame: FrameNumber(rawValue: 7), missingShards: [3, 4]
            )]
        ).newRateBitsPerSecond)
        received += 400
        let verdict = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 200, extraDelayMicros: 80_000,
            backlogBytes: 0,
            channels: lossLedger(received: received, missing: 0)
        )
        XCTAssertTrue(verdict.overuse)
        XCTAssertNil(verdict.newRateBitsPerSecond,
            "a NACK echo inside the clean column is the hole's shadow, "
            + "not congestion")
        XCTAssertGreaterThanOrEqual(estimator.stats.stallHolds, 1)

        // A rung-3-scale storm through the same shape: > 2% post-FEC
        // falls on its own branch, gate or no gate.
        var stormNacks: [FeedbackReport.NackEntry] = []
        for frame in 0..<6 {
            stormNacks.append(try FeedbackReport.NackEntry(
                frame: FrameNumber(rawValue: UInt32(100 + frame)),
                missingShards: Array(0...30)
            ))
        }
        received += 400
        let storm = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 200, extraDelayMicros: 0,
            backlogBytes: 0,
            channels: lossLedger(received: received, missing: 0),
            nacks: stormNacks
        )
        XCTAssertEqual(storm.change, .postFecLoss,
            "loss FEC could not absorb still bites — rung 3 is ungated")
        XCTAssertNotNil(storm.newRateBitsPerSecond)
    }

    /// The 1.7% feedback-direction loss the study measured: reports
    /// are unreliable by design (cumulative ledgers differenced across
    /// whatever arrives), so LOST reports must neither fabricate a
    /// verdict nor mask one. Half the reports of a clean run vanish —
    /// nothing fires; half the reports of a genuine squeeze vanish —
    /// the fall still lands.
    func testLostFeedbackReportsNeitherFabricateNorMask() {
        // Clean run, every other report lost: the surviving reports'
        // counters jump across the gaps (the differencing spans them),
        // arrivals show 50 ms seams — no loss is invented, no overuse
        // fires, no hold or fall moves the rate.
        let clean = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0
        var received: UInt32 = 0
        for beat in 0..<20 {
            received += 100
            if beat % 2 == 1 { // the odd reports never arrive
                now += 25 * Self.ms
                clientMicros += 25_000
                continue
            }
            let verdict = selfRefBeat(
                &now, &clientMicros, &seq, on: clean,
                bottleneckMbps: 20, extraDelayMicros: 0,
                backlogBytes: 0,
                channels: lossLedger(received: received, missing: 0)
            )
            XCTAssertFalse(verdict.overuse)
            XCTAssertEqual(verdict.lossFraction, 0,
                "a lost REPORT is not lost PACKETS — the cumulative "
                + "ledgers span the gap")
        }
        XCTAssertEqual(clean.rateBitsPerSecond, Self.ceiling)
        XCTAssertEqual(clean.stats.downshifts, 0)
        XCTAssertEqual(clean.stats.stallHolds, 0)

        // Genuine squeeze, same 50% report loss: the ingested inflated
        // reports still make the streak and the fall still bites.
        let squeezed = makeEstimator()
        now = 0; clientMicros = 0; seq = 0
        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: squeezed,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }
        var fell = false
        // Enough ingested beats to arm, ride out the dwell deferral's
        // ≤150 ms budget across the 50 ms report seams, and bite.
        for beat in 0..<32 {
            if beat % 2 == 1 {
                now += 25 * Self.ms
                clientMicros += 25_000
                continue
            }
            let verdict = selfRefBeat(
                &now, &clientMicros, &seq, on: squeezed,
                bottleneckMbps: 8, extraDelayMicros: 40_000,
                backlogBytes: 0
            )
            if verdict.newRateBitsPerSecond != nil { fell = true }
        }
        XCTAssertTrue(fell,
            "feedback loss must not launder a genuine squeeze")
        XCTAssertEqual(squeezed.stats.stallHolds, 0)
    }

    // MARK: Leg 3g — HS-28: the estimator-honesty reformulation. A
    // paced sender can never measure more than it sends — every
    // delivery sample is censored from above by our own rate — so the
    // ledger now records the pace at each datagram's release, samples
    // are classified at production (censored / honest / compressed),
    // and the fall anchor answers to the CAPACITY BELIEF: raised by
    // any delivery above it, demoted only by fresh honest evidence.
    // The truth-probe's conviction (a session pinned at 0.1–1.6 Mbps
    // while 30 Mbps flowed through the same air) dies by construction:
    // a censored trickle can neither vote in a fall anchor nor age
    // the belief down.

    /// Invariant 1's mechanics: censored samples (measuring ≈ our own
    /// recorded pace) RAISE the belief and never lower it — even a
    /// whole second of censored trickle below the belief leaves it
    /// standing — and the fall anchor then lands on honest evidence
    /// when it exists (demoting the belief to what the path proved).
    func testBeliefRisesOnCensoredDeliveryAndFallsOnlyOnHonestEvidence() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        // Ten censored beats at the standing 20 Mbps: the belief
        // rises to what delivery proved; nothing reads honest (the
        // trains measure our own pace).
        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }
        XCTAssertEqual(
            Double(estimator.capacityBeliefBitsPerSecond ?? 0),
            20e6, accuracy: 2e6
        )
        XCTAssertGreaterThanOrEqual(estimator.stats.censoredSamples, 5)
        XCTAssertEqual(estimator.stats.honestSamples, 0)

        // The pacer is forced down to 10 Mbps (an IDR-pacing move) and
        // a full second of CENSORED trickle at the new pace follows —
        // samples at half the belief, with backlog and standing
        // inflation. Invariant 1: the belief must not move a bit, and
        // no fall may anchor to the trickle.
        _ = estimator.applyIdrPacing(.halfStaleEstimate, now: now)
        XCTAssertEqual(Double(estimator.rateBitsPerSecond), 10e6,
                       accuracy: 0.2e6)
        for _ in 0..<40 {
            let verdict = selfRefBeat(
                &now, &clientMicros, &seq, on: estimator,
                bottleneckMbps: 10, extraDelayMicros: 40_000,
                backlogBytes: 40_000
            )
            XCTAssertNotEqual(verdict.change, .overuse,
                "a censored trickle at half the belief must not anchor "
                + "a fall")
        }
        XCTAssertEqual(Double(estimator.rateBitsPerSecond), 10e6,
                       accuracy: 0.5e6,
            "the rate rode the trickle without falling")
        XCTAssertEqual(
            Double(estimator.capacityBeliefBitsPerSecond ?? 0),
            20e6, accuracy: 2e6,
            "censored samples may raise the belief, never lower it — "
            + "one second of half-belief trickle left it standing"
        )
        XCTAssertEqual(estimator.stats.beliefDemotions, 0)

        // Honest evidence at last: the path measurably stretches the
        // trains to 4 Mbps (well under the 10 Mbps pace). The fall
        // executes and lands on measured delivery — and the belief
        // demotes to what the path proved, not a step sooner.
        var verdict = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 4, extraDelayMicros: 60_000,
            backlogBytes: 40_000
        )
        var beats = 0
        while verdict.newRateBitsPerSecond == nil, beats < 30 {
            verdict = selfRefBeat(
                &now, &clientMicros, &seq, on: estimator,
                bottleneckMbps: 4, extraDelayMicros: 60_000,
                backlogBytes: 40_000
            )
            beats += 1
        }
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

        print("HS-28 gate (belief): 1 s of censored 10 Mbps trickle "
            + "left the 20 Mbps belief standing; honest 4 Mbps "
            + "evidence demoted it to "
            + "\((estimator.capacityBeliefBitsPerSecond ?? 0) / 1_000) kbps "
            + "and the fall landed at "
            + "\(verdict.newRateBitsPerSecond! / 1_000) kbps")
    }

    /// THE LEG-B REPLAY GATE (the truth-probe's shape, virtual time):
    /// a genuine loss episode falls honestly, then the fallen pacer
    /// can only produce censored trickle — while fresh compressed
    /// super-rate drains keep proving the path. The standing rate must
    /// ride the limbo WITHOUT ratcheting toward the floor and recover
    /// toward the belief when the weather clears. The live probe
    /// measured the old law here: 9 falls in 90 s, a 0.1–1.6 Mbps
    /// limit cycle against a wire carrying 30 Mbps at 0% loss.
    func testLegBReplayCensoredTrickleRecoversTowardTheBelief() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0
        var received: UInt32 = 0
        var missing: UInt32 = 0

        // Phase 1 — clean baseline: belief at the proven 20 Mbps.
        for _ in 0..<10 {
            received += 100
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0,
                            channels: lossLedger(received: received,
                                                 missing: missing))
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        // Phase 2 — the genuine loss episode (the flood arrives): 25%
        // loss for 1.2 s. The loss branch falls exactly as ever.
        for _ in 0..<48 {
            received += 75; missing += 25
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0,
                            channels: lossLedger(received: received,
                                                 missing: missing))
        }
        let afterEpisode = estimator.rateBitsPerSecond
        XCTAssertLessThan(afterEpisode, Self.ceiling,
            "genuine loss still falls — the honesty work must not "
            + "blunt the loss branch")
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
                // delay (the hole closed — the streak resets, exactly
                // the cadence the live forensics recorded).
                verdict = selfRefBeat(
                    &now, &clientMicros, &seq, on: estimator,
                    bottleneckMbps: 300, extraDelayMicros: 0,
                    backlogBytes: 40_000,
                    channels: lossLedger(received: received,
                                         missing: missing)
                )
            } else {
                verdict = selfRefBeat(
                    &now, &clientMicros, &seq, on: estimator,
                    bottleneckMbps: paceMbps, extraDelayMicros: 40_000,
                    backlogBytes: 40_000,
                    channels: lossLedger(received: received,
                                         missing: missing)
                )
            }
            if let newRate = verdict.newRateBitsPerSecond,
               verdict.change == .overuse {
                XCTAssertGreaterThanOrEqual(
                    Double(newRate),
                    Double(estimator.rateBitsPerSecond) * 0.84,
                    "an overuse fall in the limbo may be bounded "
                    + "multiplicative at worst — never a crater to "
                    + "0.85 × trickle"
                )
            }
        }
        XCTAssertGreaterThanOrEqual(
            estimator.rateBitsPerSecond,
            Int(Double(afterEpisode) * 0.7),
            "the limbo must not ratchet the rate toward the floor "
            + "(the old law lived at 0.1–1.6 Mbps here)"
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
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: paceMbps, extraDelayMicros: 0,
                            backlogBytes: 0,
                            channels: lossLedger(received: received,
                                                 missing: missing))
        }
        XCTAssertGreaterThanOrEqual(
            Double(estimator.rateBitsPerSecond),
            Double(beforeRecovery) * 1.15,
            "clean air climbs toward the belief (10%/s), not a pin"
        )

        print("HS-28 gate (leg-B replay): loss episode "
            + "\(Self.ceiling / 1_000) → \(afterEpisode / 1_000) kbps; "
            + "1.5 s censored limbo held "
            + "\(beforeRecovery / 1_000) kbps (0 crater falls, belief "
            + "\((estimator.capacityBeliefBitsPerSecond ?? 0) / 1_000) "
            + "kbps); recovery reached "
            + "\(estimator.rateBitsPerSecond / 1_000) kbps")
    }

    /// The persistence twin the brief demands beside the replay: a
    /// GENUINE capacity drop — honest stretched trains, a building
    /// queue, standing backlog — still falls within ~1 s of onset,
    /// anchored at measured delivery.
    func testGenuineCapacityDropFallsWithinOneSecondOfOnset() {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }

        // The squeeze: the path drops to 6 Mbps, the queue builds
        // +10 ms per beat, the pacer holds backlog. Count beats to
        // the first fall.
        var extraDelay: UInt64 = 30_000
        var fell: RateEstimatorVerdict?
        var beats = 0
        while fell?.newRateBitsPerSecond == nil, beats < 40 {
            extraDelay += 10_000
            let verdict = selfRefBeat(
                &now, &clientMicros, &seq, on: estimator,
                bottleneckMbps: 6, extraDelayMicros: extraDelay,
                backlogBytes: 40_000
            )
            if verdict.newRateBitsPerSecond != nil { fell = verdict }
            beats += 1
        }
        XCTAssertNotNil(fell?.newRateBitsPerSecond,
            "a genuine capacity drop must fall")
        XCTAssertLessThanOrEqual(beats, 40,
            "within ~1 s of onset (the pillar's fast fall, at most one "
            + "limiter beat later than the old law)")
        XCTAssertEqual(Double(fell!.newRateBitsPerSecond!), 6e6 * 0.85,
                       accuracy: 1.0e6,
            "anchored at measured delivery — the belief followed the "
            + "path down")

        print("HS-28 gate (persistence twin): 20 → 6 Mbps genuine drop "
            + "fell in \(beats) beats (\(beats * 25) ms) to "
            + "\(fell!.newRateBitsPerSecond! / 1_000) kbps")
    }

    /// Self-inflicted evidence recuses itself: NACKs against frames
    /// whose shards are still queued in our own pacer (the client's
    /// completion presumption expiring mid-drain — the deep-floor
    /// starvation seam) feed neither the post-FEC fractions nor the
    /// regime ladder. The same storm unrecused still bites.
    func testRecusedNackShardsAreNotPathEvidence() throws {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0
        var received: UInt32 = 0

        for _ in 0..<10 {
            received += 400
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0,
                            channels: lossLedger(received: received,
                                                 missing: 0))
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
        now += 25 * Self.ms; clientMicros += 25_000
        received += 400
        let recused = estimator.ingest(
            report(samples: [], clientMicros: clientMicros,
                   channels: lossLedger(received: received, missing: 0),
                   nacks: try storm(100..<106)),
            now: now, inRecovery: false,
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
        now += 500 * Self.ms; clientMicros += 500_000
        received += 400
        let honest = estimator.ingest(
            report(samples: [], clientMicros: clientMicros,
                   channels: lossLedger(received: received, missing: 0),
                   nacks: try storm(200..<206)),
            now: now, inRecovery: false
        )
        XCTAssertEqual(honest.change, .postFecLoss,
            "unrecused NACK storms still bite — the recusal is "
            + "surgical, not a muzzle")
        XCTAssertEqual(honest.fecRegime, .lossy)

        print("HS-28 gate (recusal): 186 NACK shards against draining "
            + "frames → 0 path evidence; the same storm against "
            + "released frames → rung-3 fall + regime step")
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
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling)

        // 30 beats of the live shape: every report carries a
        // mid-hole STRETCHED train (3 Mbps — honest-looking) AND a
        // compressed 200 Mbps drain, all under held delay (the hole
        // chain never lets the streak reset, so persistence IS
        // reached — the purge is the only thing standing between the
        // belief and the 3 Mbps trickle).
        for _ in 0..<30 {
            now += 25 * Self.ms
            clientMicros += 25_000
            let stretched = train(
                estimator, seqStart: seq, count: 12,
                sendStartNS: now - 20 * Self.ms,
                bottleneckBitsPerSecond: 3e6, extraDelayMicros: 80_000
            )
            seq += 12
            let drain = train(
                estimator, seqStart: seq, count: 12,
                sendStartNS: now - Self.ms,
                bottleneckBitsPerSecond: 200e6, extraDelayMicros: 80_000
            )
            seq += 12
            let verdict = estimator.ingest(
                report(samples: stretched + drain,
                       clientMicros: clientMicros),
                now: now, inRecovery: false,
                pacerBacklogBytes: 40_000
            )
            XCTAssertNil(verdict.newRateBitsPerSecond,
                "a hole whose own drain testifies in the same report "
                + "must not anchor a fall")
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, Self.ceiling,
            "the belief never demoted to the mid-hole trickle")
        XCTAssertEqual(estimator.stats.downshifts, 0)
        // HS-30 amended this pin: the drains PROTECT (votes purged, no
        // fall, rate held — the assertions above, unchanged) but no
        // longer raise the belief to their burst rate — that was
        // row ⁴'s pollution. The belief stays ≈ the pace the drains
        // proved, and must never have dropped below it.
        XCTAssertGreaterThanOrEqual(
            estimator.capacityBeliefBitsPerSecond ?? 0, Self.ceiling - 1_000_000,
            "the hole cost the belief — the drains stopped protecting it"
        )
        XCTAssertLessThanOrEqual(
            estimator.capacityBeliefBitsPerSecond ?? 0, 30_000_000,
            "the drains raised the belief toward their burst rate again "
            + "— HS-30's sustainable cap is dead"
        )

        print("HS-28 gate (drain purge): 30 mid-hole reports (3 Mbps "
            + "stretch + 200 Mbps drain, held delay) → 0 falls, belief "
            + "\((estimator.capacityBeliefBitsPerSecond ?? 0) / 1_000) "
            + "kbps, rate pinned at "
            + "\(estimator.rateBitsPerSecond / 1_000) kbps")
    }

    /// The other live confession: a 41 ms streak crashed to the floor
    /// because ~1% post-FEC NACK echo read as INSTANT corroboration.
    /// Post-FEC between the clean column and rung 3 is a closed
    /// hole's shadow (frames already drained, presumption expired) —
    /// it must wait for persistence like any other pressure; only
    /// rung-3 scale is instant (and rung 3's own branch still falls).
    func testPostFecEchoBelowRungThreeNeedsPersistence() throws {
        let estimator = makeEstimator()
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0
        var received: UInt32 = 0

        for _ in 0..<10 {
            received += 1_200
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0,
                            channels: lossLedger(received: received,
                                                 missing: 0))
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
        XCTAssertNil(selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 20, extraDelayMicros: 60_000,
            backlogBytes: 0,
            channels: lossLedger(received: received, missing: 0),
            nacks: echo
        ).newRateBitsPerSecond)

        // Ten more inflated beats inside the persistence span: the
        // echo must NOT act as instant corroboration (the old law
        // fell here on a 41 ms streak).
        for _ in 0..<10 {
            received += 1_200
            let verdict = selfRefBeat(
                &now, &clientMicros, &seq, on: estimator,
                bottleneckMbps: 20, extraDelayMicros: 60_000,
                backlogBytes: 0,
                channels: lossLedger(received: received, missing: 0)
            )
            XCTAssertNil(verdict.newRateBitsPerSecond,
                "a sub-rung-3 NACK echo is a shadow, not instant "
                + "corroboration")
        }

        // Pressure that outlives the persistence still falls — and
        // bounded multiplicative (no honest votes), never anchored
        // to the echo.
        var verdict = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 20, extraDelayMicros: 60_000,
            backlogBytes: 0,
            channels: lossLedger(received: received, missing: 0)
        )
        var beats = 0
        while verdict.newRateBitsPerSecond == nil, beats < 20 {
            received += 1_200
            verdict = selfRefBeat(
                &now, &clientMicros, &seq, on: estimator,
                bottleneckMbps: 20, extraDelayMicros: 60_000,
                backlogBytes: 0,
                channels: lossLedger(received: received, missing: 0)
            )
            beats += 1
        }
        XCTAssertNotNil(verdict.newRateBitsPerSecond)
        XCTAssertGreaterThanOrEqual(verdict.newRateBitsPerSecond!,
                                    16_000_000,
            "the persisted fall is bounded multiplicative — the echo "
            + "never became an anchor")

        print("HS-28 gate (echo persistence): 0.8% post-FEC echo + "
            + "young streak → 0 instant falls; persisted pressure "
            + "fell bounded to "
            + "\(verdict.newRateBitsPerSecond! / 1_000) kbps")
    }

    // MARK: Leg 4 — the machine's numbers

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

    func testFrameByteCeilingTracksTheLiveEstimate() {
        let estimator = makeEstimator()
        // At the 20 Mbps ceiling, 60 fps: B = min(2/60 s, 25 ms) =
        // 25 ms → 62,500 B gross − (820 kbps of audio + control
        // reserves × 25 ms / 8) ≈ 2,562 B → the HS-6 figure.
        let atCeiling = estimator.frameByteCeiling(fps: 60)
        XCTAssertEqual(atCeiling, 59_937,
                       "the HS-6 derivation at the live rate")
        // 30 fps: B stays 25 ms (min(66 ms, 25 ms)); 120 fps: B =
        // 16.6 ms.
        XCTAssertEqual(estimator.frameByteCeiling(fps: 30), atCeiling)
        XCTAssertLessThan(estimator.frameByteCeiling(fps: 120), atCeiling)

        // The ceiling tracks the estimate down…
        _ = estimator.applyIdrPacing(.halfStaleEstimate, now: Self.ms)
        let atHalf = estimator.frameByteCeiling(fps: 60)
        XCTAssertEqual(
            Double(atHalf),
            Double(10_000_000) * 0.025 / 8 - 820_000.0 * 0.025 / 8,
            accuracy: 2
        )
        // …and never below one datagram, even at the floor.
        for _ in 0..<8 {
            _ = estimator.applyIdrPacing(
                .halfStaleEstimate, now: 2 * Self.ms
            )
        }
        XCTAssertEqual(estimator.rateBitsPerSecond, 500_000)
        XCTAssertGreaterThanOrEqual(
            estimator.frameByteCeiling(fps: 60),
            WireBudget.maxDatagramByteCount
        )
    }

    // MARK: Leg 5 — RECOVERY verdicts through the whole session

    /// An insecure-mode session (machine armed from init, passthrough
    /// seal) driven with real chan-3 FeedbackReports: the estimator —
    /// not the retired 25 ms stub — now decides graduation, and loss
    /// inside a window honestly holds RECOVERY.
    func testRecoveryGraduatesOnEstimatorVerdictsNotMerePresence() throws {
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .insecure, rateBitsPerSecond: Self.ceiling,
                beaconIntervalNS: 1 << 62
            ),
            clientTuple: Self.tupleA,
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

        // Clean windows: two graduate it (W4b's count).
        t += 30_000
        _ = feedback(tMicros: t, newReceived: 100, newMissing: 0)
        t += 30_000
        _ = feedback(tMicros: t, newReceived: 100, newMissing: 0)
        XCTAssertEqual(session.lifecycleState, .active)

        print("HS-16 gate (recovery): FROZEN → RECOVERY at "
            + "\(Self.ceiling / 2_000) kbps (half-stale, on the pacer) → "
            + "10 lossy windows HELD → 2 clean windows → ACTIVE")
    }

    // MARK: Leg 6 — malformed feedback is counted, never fed

    func testMalformedFeedbackIsDroppedLoudAndFeedsNothing() {
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .insecure, rateBitsPerSecond: Self.ceiling,
                beaconIntervalNS: 1 << 62
            ),
            clientTuple: Self.tupleA,
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

    // MARK: Leg 7 — THE CADENCE GATE under a rate crash (R-G8 + HS-16)

    /// HS-15's virtual-time R-G8 shape with the estimator live: 6 s at
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
                crypto: .insecure, rateBitsPerSecond: Self.ceiling
            ),
            clientTuple: Self.tupleA,
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

        func syntheticFrame(byteCount: Int, irap: Bool = false) -> [UInt8] {
            [0, 0, 0, 1, irap ? 0x26 : 0x02, 0x01]
                + [UInt8](repeating: 0xAA, count: byteCount - 6)
        }
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
            "audio inter-send p99 deviation \(Double(p99) / 1e6) ms > 2 ms "
            + "through the rate crash")

        print("HS-16 gate (R-G8 + crash) @6 s virtual: rate "
            + "\(Self.ceiling / 1_000) → \(minRate / 1_000) kbps under the "
            + "loss burst, back to \(session.pacerRateBitsPerSecond / 1_000) "
            + "kbps on evidence (\(session.estimatorStats.downshifts) down / "
            + "\(session.estimatorStats.upshifts) up); "
            + "\(dataSends.count) audio packets, inter-send deviation "
            + "p99 \(Double(p99) / 1e6) ms, worst "
            + "\(Double(deviations.last!) / 1e6) ms; audio max queue delay "
            + "\(Double(session.pacerTelemetry[.audio].maxQueueDelayNS) / 1e6) ms")
    }

    // MARK: HS-29 — cap-aware probe damping (row ³'s shared cause)

    /// THE HS-29 HEADLINE: with the belief parked at ~20 Mbps and a
    /// 50 Mbps configured cap, the climb stops at belief × headroom
    /// instead of probing on toward a cap the belief says the air
    /// cannot honor (row ³: that probing bought 102 lost datagrams and
    /// the residual IDR spend). Five virtual seconds of clean evidence
    /// beats: the rate must park at ~22 Mbps, damped, with zero falls.
    func testProbeCeilingDampsClimbAtBeliefHeadroom() {
        let estimator = makeEstimator {
            $0.ceilingBitsPerSecond = 50_000_000
            $0.initialRateBitsPerSecond = 20_000_000
        }
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0

        // Establish the belief at ~20 Mbps: censored beats at pace.
        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }
        let belief = Double(estimator.capacityBeliefBitsPerSecond ?? 0)
        XCTAssertEqual(belief, 20e6, accuracy: 2.5e6)

        // 200 clean beats (5 s): the air still delivers only ~20 —
        // trains keep measuring ≈20 whatever the pace wants. The climb
        // must park at belief × 1.1, not walk to the 50 Mbps cap.
        for _ in 0..<200 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
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

        print("HS-29 gate (damping): belief "
            + "\(Int(belief) / 1_000) kbps, 50 Mbps cap — climb parked at "
            + "\(Int(parked) / 1_000) kbps "
            + "(\(estimator.stats.upshiftsDamped) damped rises, 0 falls)")
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
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0
        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }

        // The air steps to 45: from here every train drains at the
        // pace we offer (self-limited against generous air), so each
        // beat's sample tracks the risen rate and drags the belief up.
        var beats = 0
        while estimator.rateBitsPerSecond < 40_000_000, beats < 480 {
            let paceMbps = Double(estimator.rateBitsPerSecond) / 1e6
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: min(paceMbps, 45),
                            extraDelayMicros: 0, backlogBytes: 0)
            beats += 1
        }
        XCTAssertGreaterThanOrEqual(estimator.rateBitsPerSecond, 40_000_000,
            "the belief ossified: 12 virtual seconds of improved air "
            + "never walked the rate up — headroom probing is dead")
        XCTAssertLessThanOrEqual(beats, 480)
        XCTAssertGreaterThanOrEqual(
            estimator.capacityBeliefBitsPerSecond ?? 0, 36_000_000,
            "the belief did not follow the walk up")

        print("HS-29 gate (capacity step): 20 → 45 Mbps air — rate "
            + "reached \(estimator.rateBitsPerSecond / 1_000) kbps in "
            + "\(beats) beats (\(Double(beats) * 0.025) s), belief "
            + "\((estimator.capacityBeliefBitsPerSecond ?? 0) / 1_000) kbps")
    }

    // MARK: HS-30 — burst-vs-sustainable belief + probe cadence

    /// A compressed drain may not set the probe ceiling: a queue
    /// emptying at 300 Mbps proves the path carried our PACE through
    /// the hole, not that the air offers 300 Mbps (row ⁴: drain-raised
    /// beliefs of 207 Mbps–1.18 Gbps neutered HS-29's damping).
    func testDrainRaisesTheBeliefOnlyToThePaceItDrainedBehind() {
        let estimator = makeEstimator {
            $0.ceilingBitsPerSecond = 50_000_000
            $0.initialRateBitsPerSecond = 20_000_000
        }
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0
        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }
        let before = estimator.capacityBeliefBitsPerSecond ?? 0
        // A hole closes: one compressed drain at 300 Mbps (≫ pace ×
        // stallBurstRateFactor). The belief may rise to ≈pace, never
        // to the drain's instantaneous rate.
        _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                        bottleneckMbps: 300, extraDelayMicros: 0,
                        backlogBytes: 0)
        let after = estimator.capacityBeliefBitsPerSecond ?? 0
        XCTAssertLessThanOrEqual(after, Int(25e6),
            "a 300 Mbps drain burst set the belief to \(after) — burst "
            + "pollution is back")
        XCTAssertGreaterThanOrEqual(after, before,
            "the drain may never LOWER the belief")

        print("HS-30 gate (drain cap): belief \(before / 1_000) → "
            + "\(after / 1_000) kbps through a 300 Mbps drain burst")
    }

    /// A fall inside the belief's headroom band arms the probe
    /// cadence: the recover-climb parks BELOW the band until the
    /// cadence expires, then probes again — instead of re-slamming
    /// the wall every recovery cycle (row ⁴: 12 slams / 150 s).
    func testFailedProbeWaitsItsCadenceBeforeReenteringTheBand() {
        let estimator = makeEstimator {
            $0.ceilingBitsPerSecond = 50_000_000
            $0.initialRateBitsPerSecond = 20_000_000
            $0.probeCadenceNS = 5_000_000_000
        }
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0
        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }
        // Probe into the wall: honest stretched trains + growing queue
        // until the fall executes (invariant-2 persistence).
        var fell = false
        var delay: UInt64 = 30_000
        for _ in 0..<60 where !fell {
            let verdict = selfRefBeat(&now, &clientMicros, &seq,
                                      on: estimator, bottleneckMbps: 15,
                                      extraDelayMicros: delay,
                                      backlogBytes: 60_000)
            delay += 8_000
            fell = verdict.change == .overuse
        }
        XCTAssertTrue(fell, "the wall never produced a fall")
        let bandFloor = Double(estimator.capacityBeliefBitsPerSecond ?? 0)
            / 1.10
        // Clean beats follow: the climb recovers but must PARK below
        // the band floor while the cadence holds.
        for _ in 0..<80 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }
        XCTAssertLessThanOrEqual(
            Double(estimator.rateBitsPerSecond), bandFloor + 0.1e6,
            "the climb re-entered the failed band inside the cadence")
        XCTAssertGreaterThanOrEqual(estimator.stats.upshiftsCadenceHeld, 1)
        // The cadence expires (5 s): the next probe fires and the rate
        // re-enters the band.
        for _ in 0..<130 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }
        XCTAssertGreaterThan(
            Double(estimator.rateBitsPerSecond), bandFloor,
            "the probe never fired after the cadence expired")

        print("HS-30 gate (cadence): fall at the wall parked the climb "
            + "below \(Int(bandFloor) / 1_000) kbps for the cadence "
            + "(\(estimator.stats.upshiftsCadenceHeld) held rises), "
            + "then re-probed to \(estimator.rateBitsPerSecond / 1_000) kbps")
    }

    /// The headroom knob is honored: factor 1.5 parks the climb at
    /// belief × 1.5 instead of the default 1.1.
    func testProbeHeadroomKnobHonored() {
        let estimator = makeEstimator {
            $0.ceilingBitsPerSecond = 50_000_000
            $0.initialRateBitsPerSecond = 20_000_000
            $0.probeHeadroomFactor = 1.5
        }
        var now: UInt64 = 0
        var clientMicros: UInt64 = 0
        var seq = 0
        for _ in 0..<10 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }
        for _ in 0..<400 {
            _ = selfRefBeat(&now, &clientMicros, &seq, on: estimator,
                            bottleneckMbps: 20, extraDelayMicros: 0,
                            backlogBytes: 0)
        }
        let belief = Double(estimator.capacityBeliefBitsPerSecond ?? 0)
        let parked = Double(estimator.rateBitsPerSecond)
        XCTAssertLessThanOrEqual(parked, belief * 1.5 + 0.1e6)
        XCTAssertGreaterThanOrEqual(parked, belief * 1.3,
            "factor 1.5 should park the climb well past the 1.1 default")

        print("HS-29 gate (knob): factor 1.5 parked the climb at "
            + "\(Int(parked) / 1_000) kbps over a "
            + "\(Int(belief) / 1_000) kbps belief")
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
