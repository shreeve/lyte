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
    private func feedClean(
        _ meter: LinkHealthMeter, ordinals: Range<UInt64>,
        at time: TimeInterval
    ) {
        for o in ordinals {
            meter.observe(
                ordinal: o, transitStretchMilliseconds: 0.5,
                sourceGapMilliseconds: 16.7,
                queueWaitMilliseconds: 0.05,
                enqueueMilliseconds: 0.03, frameSeconds: time)
        }
    }

    private func feedStall(
        _ meter: LinkHealthMeter, ordinal: UInt64,
        transit: Double, at time: TimeInterval
    ) {
        meter.observe(
            ordinal: ordinal, transitStretchMilliseconds: transit,
            sourceGapMilliseconds: 16.7, queueWaitMilliseconds: 0.05,
            enqueueMilliseconds: 0.03, frameSeconds: time)
    }

    func testQuietLinkIsGoodAndBlamesNobody() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<120, at: 0)
        let verdict = meter.assessment()
        XCTAssertEqual(verdict.level, .good)
        XCTAssertEqual(verdict.stallsPerMinute, 0)
        XCTAssertEqual(verdict.dominantStage, "none")
    }

    func testWarmupGraceSwallowsTheConnectRamp() {
        // The first seconds of every epoch spike while the pipeline
        // fills — no episodes, no books, no pill.
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        feedStall(meter, ordinal: 2, transit: 115, at: 3)
        feedStall(meter, ordinal: 3, transit: 90, at: 9)
        var verdict = meter.assessment()
        XCTAssertEqual(verdict.level, .good)
        XCTAssertEqual(verdict.sessionStallCount, 0)
        // Past the grace, stalls count normally.
        feedStall(meter, ordinal: 4, transit: 88, at: 15)
        verdict = meter.assessment()
        XCTAssertEqual(verdict.level, .degraded)
        XCTAssertEqual(verdict.sessionStallCount, 1)
    }

    func testWarmupGraceAppliesAfreshAfterARoamRedial() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        feedStall(meter, ordinal: 2, transit: 88, at: 20)
        XCTAssertEqual(meter.assessment().sessionStallCount, 1)
        // Roam re-dial: ordinals restart on a fresh clock — its own
        // connect ramp gets the same grace.
        feedStall(meter, ordinal: 1, transit: 115, at: 100)
        XCTAssertEqual(meter.assessment().sessionStallCount, 1)
        feedStall(meter, ordinal: 2, transit: 90, at: 115)
        XCTAssertEqual(meter.assessment().sessionStallCount, 2)
    }

    func testOneTransitStallIsDegradedWithItsMagnitude() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<60, at: 0)
        feedStall(meter, ordinal: 60, transit: 88, at: 15)
        let verdict = meter.assessment()
        XCTAssertEqual(verdict.level, .degraded)
        XCTAssertEqual(verdict.worstStallMilliseconds, 88)
        XCTAssertEqual(verdict.dominantStage, "network")
        XCTAssertEqual(verdict.stallsPerMinute, 1.0)
    }

    func testDeepOrFrequentStallsArePoor() {
        // Deep: one ≥100 ms freeze is poor on its own.
        let deep = LinkHealthMeter()
        feedClean(deep, ordinals: 1..<2, at: 0)
        feedStall(deep, ordinal: 2, transit: 115, at: 15)
        XCTAssertEqual(deep.assessment().level, .poor)

        // Frequent: three separated 30 ms stalls are poor too —
        // the 2026-08-01 Wi-Fi comb shape.
        let frequent = LinkHealthMeter()
        feedClean(frequent, ordinals: 1..<2, at: 0)
        for (i, t) in [15.0, 25.0, 35.0].enumerated() {
            feedStall(frequent, ordinal: UInt64(i + 2), transit: 30,
                      at: t)
        }
        let verdict = frequent.assessment()
        XCTAssertEqual(verdict.level, .poor)
        XCTAssertEqual(verdict.stallsPerMinute, 3.0)
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
        let verdict = meter.assessment()
        XCTAssertEqual(verdict.stallsPerMinute, 1.0)
        XCTAssertEqual(verdict.worstStallMilliseconds, 115)
        XCTAssertEqual(verdict.level, .poor)
    }

    func testEpisodesAgeOutBackToGood() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        feedStall(meter, ordinal: 2, transit: 90, at: 15)
        XCTAssertEqual(meter.assessment().level, .degraded)
        // The window ages on the FRAME clock — a later clean frame
        // moves it past the stall.
        feedClean(meter, ordinals: 3..<4, at: 90)
        XCTAssertEqual(meter.assessment().level, .good)
    }

    func testStageAttributionPicksTheGuiltyParty() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        meter.observe(
            ordinal: 2, transitStretchMilliseconds: 1,
            sourceGapMilliseconds: 120, queueWaitMilliseconds: 0.05,
            enqueueMilliseconds: 0.03, frameSeconds: 15)
        XCTAssertEqual(meter.assessment().dominantStage, "host")

        let renderer = LinkHealthMeter()
        feedClean(renderer, ordinals: 1..<2, at: 0)
        renderer.observe(
            ordinal: 2, transitStretchMilliseconds: nil,
            sourceGapMilliseconds: nil, queueWaitMilliseconds: 9,
            enqueueMilliseconds: 3, frameSeconds: 15)
        XCTAssertEqual(
            renderer.assessment().dominantStage, "renderer")
    }

    func testRecorderResetRestartsTheWindowButKeepsTheBooks() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<2, at: 0)
        feedStall(meter, ordinal: 500, transit: 115, at: 15)
        XCTAssertEqual(meter.assessment().level, .poor)
        // A roam re-dial resets the recorder (ordinals restart): the
        // WINDOW must not carry old-clock episodes, but the sitting's
        // totals survive — the stalls that trigger re-dials are
        // exactly the ones the total exists to count.
        feedClean(meter, ordinals: 1..<2, at: 16)
        let after = meter.assessment()
        XCTAssertEqual(after.level, .good)
        XCTAssertEqual(after.sessionStallCount, 1)
        XCTAssertEqual(after.sessionWorstMilliseconds, 115)
        // Only the sitting's end clears the books.
        meter.resetSessionBooks()
        XCTAssertEqual(meter.assessment().sessionStallCount, 0)
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
        let verdict = meter.assessment()
        XCTAssertEqual(verdict.level, .good)
        XCTAssertEqual(verdict.sessionStallCount, 2)
        XCTAssertEqual(verdict.sessionWorstMilliseconds, 39)
        // A roam re-dial (ordinals restart) keeps the books; only
        // the sitting's end clears them.
        feedClean(meter, ordinals: 1..<2, at: 150)
        XCTAssertEqual(meter.assessment().sessionStallCount, 2)
        meter.resetSessionBooks()
        let fresh = meter.assessment()
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
        XCTAssertEqual(meter.assessment().stallsPerMinute, 1.0)
        // A later distinct stall past the coalesce window is a second.
        feedStall(meter, ordinal: 8, transit: 80, at: 17)
        XCTAssertEqual(meter.assessment().stallsPerMinute, 2.0)
    }
}
