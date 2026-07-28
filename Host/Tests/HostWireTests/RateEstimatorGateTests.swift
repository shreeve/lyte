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
        // report arms, the second fires the overuse verdict and the
        // fall anchors to 0.85 × the measured delivery rate.
        XCTAssertFalse(beat(extraDelayMicros: 25_000).overuse,
                       "one inflated report must not fire (2 consecutive)")
        let verdict = beat(extraDelayMicros: 25_000)
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

        // Fire: the second inflated report — and its ONLY delivery
        // sample is a garbage short train that measures ~2 Mbps. The
        // one-deep anchor of old would fall to 0.85 × 2 Mbps = 1.7 Mbps
        // (a crater); the median of the last three raw samples is still
        // 20 Mbps (garbage outvoted 2-to-1), so the fall lands at
        // 0.85 × 20 Mbps.
        now += 25 * Self.ms; clientMicros += 25_000
        let garbage = train(
            estimator, seqStart: seq, count: 4,
            sendStartNS: now - Self.ms,
            bottleneckBitsPerSecond: 2e6, extraDelayMicros: 40_000
        )
        seq += 4
        let verdict = estimator.ingest(
            report(samples: garbage, clientMicros: clientMicros),
            now: now, inRecovery: false
        )
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
        // queue inflates. Arm, then fire.
        XCTAssertFalse(beat(mbps: 5, inflate: true).overuse)
        let first = beat(mbps: 5, inflate: true)
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

        now += 25 * Self.ms; clientMicros += 25_000
        let fire = train(
            estimator, seqStart: seq, count: 4,
            sendStartNS: now - Self.ms,
            bottleneckBitsPerSecond: 1e6, extraDelayMicros: 40_000
        )
        seq += 4
        let verdict = estimator.ingest(
            report(samples: fire, clientMicros: clientMicros),
            now: now, inRecovery: false
        )
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
        // …and the second report shows the queue BUILT another 20 ms
        // (past the 15 ms overuse threshold): corroborated — the fall
        // lands at 0.85 × the standing rate despite the self-shaped
        // anchor.
        let verdict = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 20, extraDelayMicros: 45_000,
            backlogBytes: 40_000
        )
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
        // holds backlog the whole time. Arm, then fire.
        XCTAssertNil(selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 5, extraDelayMicros: 40_000,
            backlogBytes: 40_000
        ).newRateBitsPerSecond)
        let verdict = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 5, extraDelayMicros: 40_000,
            backlogBytes: 40_000
        )
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
        let verdict = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 200, extraDelayMicros: 400_000,
            backlogBytes: 0
        )
        XCTAssertTrue(verdict.overuse)
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
        let verdict = selfRefBeat(
            &now, &clientMicros, &seq, on: estimator,
            bottleneckMbps: 8, extraDelayMicros: 40_000,
            backlogBytes: 0
        )
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
        for beat in 0..<4 {
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
