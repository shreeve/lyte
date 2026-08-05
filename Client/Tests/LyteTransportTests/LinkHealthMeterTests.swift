import XCTest
@testable import LyteTransport

/// The link-health verdict laws: quiet link → good (and the UI shows
/// nothing); one stall → degraded with its magnitude; frequent or
/// deep stalls → poor; episodes coalesce and age out; the connect
/// ramp gets a warmup grace; a recorder reset (ordinals restart)
/// restarts the window but the sitting's books survive roams.
///
/// Every test anchors its epoch with a clean frame at t=0 — the
/// warmup grace (10 s) swallows anything earlier by design.
final class LinkHealthMeterTests: XCTestCase {
    private func micros(_ seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000)
    }

    private func assessment(
        _ meter: LinkHealthMeter,
        at seconds: TimeInterval
    ) -> LinkHealthAssessment {
        meter.assessment(nowMicroseconds: micros(seconds))
    }

    private func feedClean(
        _ meter: LinkHealthMeter, ordinals: Range<UInt64>,
        at time: TimeInterval
    ) {
        for o in ordinals {
            meter.observe(
                ordinal: o, transitStretchMilliseconds: 0.5,
                queueWaitMilliseconds: 0.05,
                enqueueMilliseconds: 0.03,
                eventMicroseconds: micros(time))
        }
    }

    private func feedStall(
        _ meter: LinkHealthMeter, ordinal: UInt64,
        transit: Double, at time: TimeInterval
    ) {
        meter.observe(
            ordinal: ordinal, transitStretchMilliseconds: transit,
            queueWaitMilliseconds: 0.05,
            enqueueMilliseconds: 0.03,
            eventMicroseconds: micros(time))
    }

    func testQuietLinkIsGoodAndBlamesNobody() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<120, at: 0)
        let verdict = assessment(meter, at: 0)
        XCTAssertEqual(verdict.level, .good)
        XCTAssertEqual(verdict.stallsLastMinute, 0)
        XCTAssertEqual(verdict.dominantStage, "none")
    }

    func testWarmupGraceSwallowsTheConnectRamp() {
        // The first seconds of every epoch spike while the pipeline
        // fills — no episodes, no books, no pill.
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        feedStall(meter, ordinal: 2, transit: 115, at: 3)
        feedStall(meter, ordinal: 3, transit: 90, at: 9)
        var verdict = assessment(meter, at: 9)
        XCTAssertEqual(verdict.level, .good)
        XCTAssertEqual(verdict.sessionStallCount, 0)
        // Past the grace, stalls count normally.
        feedStall(meter, ordinal: 4, transit: 88, at: 15)
        verdict = assessment(meter, at: 15)
        XCTAssertEqual(verdict.level, .degraded)
        XCTAssertEqual(verdict.sessionStallCount, 1)
    }

    func testWarmupGraceAppliesAfreshAfterARoamRedial() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        feedStall(meter, ordinal: 2, transit: 88, at: 20)
        XCTAssertEqual(assessment(meter, at: 20).sessionStallCount, 1)
        meter.resetEpochKeepingSessionBooks()
        // Roam re-dial: its own connect ramp gets the same grace while the
        // sitting-wide count remains intact.
        feedStall(meter, ordinal: 1, transit: 115, at: 100)
        XCTAssertEqual(assessment(meter, at: 100).sessionStallCount, 1)
        feedStall(meter, ordinal: 2, transit: 90, at: 115)
        XCTAssertEqual(assessment(meter, at: 115).sessionStallCount, 2)
    }

    func testExplicitEpochResetHandlesEqualAndLeapfroggedOrdinals() {
        for firstNewOrdinal: UInt64 in [1, 500] {
            let meter = LinkHealthMeter()
            feedClean(meter, ordinals: 1..<2, at: 0)
            feedStall(meter, ordinal: 2, transit: 88, at: 20)
            XCTAssertEqual(assessment(meter, at: 20).sessionStallCount, 1)

            meter.resetEpochKeepingSessionBooks()
            feedStall(
                meter, ordinal: firstNewOrdinal,
                transit: 115, at: 100)

            let reconnectRamp = assessment(meter, at: 100)
            XCTAssertEqual(reconnectRamp.level, .good)
            XCTAssertEqual(reconnectRamp.stallsLastMinute, 0)
            XCTAssertEqual(reconnectRamp.sessionStallCount, 1)
        }
    }

    func testOneTransitStallIsDegradedWithItsMagnitude() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<60, at: 0)
        feedStall(meter, ordinal: 60, transit: 88, at: 15)
        let verdict = assessment(meter, at: 15)
        XCTAssertEqual(verdict.level, .degraded)
        XCTAssertEqual(verdict.worstStallMilliseconds, 88)
        XCTAssertEqual(verdict.dominantStage, "network")
        XCTAssertEqual(verdict.stallsLastMinute, 1)
    }

    func testDeepOrFrequentStallsArePoor() {
        // Deep: one ≥100 ms freeze is poor on its own.
        let deep = LinkHealthMeter()
        feedClean(deep, ordinals: 1..<2, at: 0)
        feedStall(deep, ordinal: 2, transit: 115, at: 15)
        XCTAssertEqual(assessment(deep, at: 15).level, .poor)

        // Frequent: three separated 30 ms stalls are poor too —
        // the 2026-08-01 Wi-Fi comb shape.
        let frequent = LinkHealthMeter()
        feedClean(frequent, ordinals: 1..<2, at: 0)
        for (i, t) in [15.0, 25.0, 35.0].enumerated() {
            feedStall(frequent, ordinal: UInt64(i + 2), transit: 30,
                      at: t)
        }
        let verdict = assessment(frequent, at: 35)
        XCTAssertEqual(verdict.level, .poor)
        XCTAssertEqual(verdict.stallsLastMinute, 3)
    }

    func testBurstCoalescesToOneEpisodeAndPeakWins() {
        // One deaf-window smears across adjacent frames — the user
        // felt ONE hitch, the meter counts ONE episode at its peak.
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        for (i, stretch) in [40.0, 115.0, 60.0].enumerated() {
            feedStall(meter, ordinal: UInt64(i + 2), transit: stretch,
                      at: 15 + Double(i) * 0.02)
        }
        let verdict = assessment(meter, at: 15.04)
        XCTAssertEqual(verdict.stallsLastMinute, 1)
        XCTAssertEqual(verdict.worstStallMilliseconds, 115)
        XCTAssertEqual(verdict.level, .poor)
    }

    func testEpisodesAgeOutBackToGood() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        feedStall(meter, ordinal: 2, transit: 90, at: 15)
        XCTAssertEqual(assessment(meter, at: 15).level, .degraded)
        // The live verdict clock moves it past the stall even if a quiet,
        // damage-driven desktop emits no more frames.
        XCTAssertEqual(assessment(meter, at: 75).level, .good)
    }

    func testStageAttributionPicksTheGuiltyParty() {
        // Source-capture gaps are deliberately NOT a stage: portal
        // capture is damage-driven, so an idle desktop with a seconds
        // clock produces 1000 ms gaps by design (the 2026-08-01
        // "Host capture stalls — worst 1,002 ms" false alarm). The
        // meter no longer accepts them as evidence at all — clean
        // transit on a quiet desktop stays good however sparse the
        // frames.
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        feedClean(meter, ordinals: 2..<3, at: 15)
        feedClean(meter, ordinals: 3..<4, at: 16)
        XCTAssertEqual(assessment(meter, at: 16).level, .good)
        XCTAssertEqual(assessment(meter, at: 16).dominantStage, "none")

        let renderer = LinkHealthMeter()
        feedClean(renderer, ordinals: 1..<2, at: 0)
        renderer.observe(
            ordinal: 2, transitStretchMilliseconds: nil,
            queueWaitMilliseconds: 9,
            enqueueMilliseconds: 3,
            eventMicroseconds: micros(15))
        XCTAssertEqual(
            assessment(renderer, at: 15).dominantStage, "renderer")
    }

    func testRecorderResetRestartsTheWindowButKeepsTheBooks() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        feedStall(meter, ordinal: 500, transit: 115, at: 15)
        XCTAssertEqual(assessment(meter, at: 15).level, .poor)
        // A roam re-dial explicitly starts a new epoch: the window must not
        // carry old episodes, but the sitting's totals survive.
        meter.resetEpochKeepingSessionBooks()
        feedClean(meter, ordinals: 1..<2, at: 16)
        let after = assessment(meter, at: 16)
        XCTAssertEqual(after.level, .good)
        XCTAssertEqual(after.sessionStallCount, 1)
        XCTAssertEqual(after.sessionWorstMilliseconds, 115)
        // Only the sitting's end clears the books.
        meter.resetSessionBooks()
        XCTAssertEqual(assessment(meter, at: 16).sessionStallCount, 0)
    }

    func testSessionBooksOutliveTheWindowAndDieWithTheSession() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        feedStall(meter, ordinal: 2, transit: 39, at: 15)
        feedStall(meter, ordinal: 3, transit: 27, at: 25)
        // Two minutes of clean frames later the window has forgotten
        // both; the session books have not — "2 total, worst 39 ms"
        // still true.
        feedClean(meter, ordinals: 4..<5, at: 140)
        let verdict = assessment(meter, at: 140)
        XCTAssertEqual(verdict.level, .good)
        XCTAssertEqual(verdict.sessionStallCount, 2)
        XCTAssertEqual(verdict.sessionWorstMilliseconds, 39)
        // A roam re-dial keeps the books; only the sitting's end clears them.
        meter.resetEpochKeepingSessionBooks()
        feedClean(meter, ordinals: 1..<2, at: 150)
        XCTAssertEqual(assessment(meter, at: 150).sessionStallCount, 2)
        meter.resetSessionBooks()
        let fresh = assessment(meter, at: 150)
        XCTAssertEqual(fresh.sessionStallCount, 0)
        XCTAssertEqual(fresh.sessionWorstMilliseconds, 0)
    }

    func testDuplicateOrdinalsFoldOnce() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        for _ in 0..<5 {
            feedStall(meter, ordinal: 7, transit: 80, at: 15)
        }
        // Re-fed frames (the 1 Hz scan overlaps the ring) count once.
        XCTAssertEqual(assessment(meter, at: 15).stallsLastMinute, 1)
        // A later distinct stall past the coalesce window is a second.
        feedStall(meter, ordinal: 8, transit: 80, at: 17)
        XCTAssertEqual(assessment(meter, at: 17).stallsLastMinute, 2)
    }

    func testOneSecondBucketCountsEveryDistinctEpisode() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        feedStall(meter, ordinal: 2, transit: 40, at: 15.00)
        feedStall(meter, ordinal: 3, transit: 45, at: 15.75)

        let verdict = assessment(meter, at: 15.99)
        XCTAssertEqual(verdict.stallsLastMinute, 2)
        XCTAssertEqual(verdict.sessionStallCount, 2)
        XCTAssertEqual(verdict.worstStallMilliseconds, 45)
    }

    func testExactlySixtyOneSecondBucketsRollAtTheBoundary() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        feedStall(meter, ordinal: 2, transit: 40, at: 15)
        feedStall(meter, ordinal: 3, transit: 45, at: 16)

        XCTAssertEqual(
            assessment(meter, at: 74.999).stallsLastMinute, 2)
        XCTAssertEqual(assessment(meter, at: 75).stallsLastMinute, 1)
        XCTAssertEqual(assessment(meter, at: 76).stallsLastMinute, 0)
    }

    func testRingSlotReuseCannotResurrectTheOldMinute() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        feedStall(meter, ordinal: 2, transit: 40, at: 15)
        feedStall(meter, ordinal: 3, transit: 45, at: 75)

        let verdict = assessment(meter, at: 75)
        XCTAssertEqual(verdict.stallsLastMinute, 1)
        XCTAssertEqual(verdict.sessionStallCount, 2)
        XCTAssertEqual(verdict.worstStallMilliseconds, 45)
    }
}
