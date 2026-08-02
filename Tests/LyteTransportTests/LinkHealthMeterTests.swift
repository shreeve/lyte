import XCTest
@testable import LyteTransport

/// The link-health verdict laws: quiet link → good (and the UI shows
/// nothing); one stall → degraded with its magnitude; frequent or
/// deep stalls → poor; episodes coalesce and age out; a recorder
/// reset (ordinals restart) forgets the old session's sins.
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

    func testQuietLinkIsGoodAndBlamesNobody() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<120, at: 10)
        let verdict = meter.assessment()
        XCTAssertEqual(verdict.level, .good)
        XCTAssertEqual(verdict.stallsPerMinute, 0)
        XCTAssertEqual(verdict.dominantStage, "none")
    }

    func testOneTransitStallIsDegradedWithItsMagnitude() {
        let meter = LinkHealthMeter()
        feedClean(meter, ordinals: 1..<60, at: 10)
        meter.observe(
            ordinal: 60, transitStretchMilliseconds: 88,
            sourceGapMilliseconds: 16.7, queueWaitMilliseconds: 0.05,
            enqueueMilliseconds: 0.03, frameSeconds: 10)
        let verdict = meter.assessment()
        XCTAssertEqual(verdict.level, .degraded)
        XCTAssertEqual(verdict.worstStallMilliseconds, 88)
        XCTAssertEqual(verdict.dominantStage, "network")
        XCTAssertEqual(verdict.stallsPerMinute, 1.0)
    }

    func testDeepOrFrequentStallsArePoor() {
        // Deep: one ≥100 ms freeze is poor on its own.
        let deep = LinkHealthMeter()
        deep.observe(
            ordinal: 1, transitStretchMilliseconds: 115,
            sourceGapMilliseconds: 16.7, queueWaitMilliseconds: 0.05,
            enqueueMilliseconds: 0.03, frameSeconds: 5)
        XCTAssertEqual(deep.assessment().level, .poor)

        // Frequent: three separated 30 ms stalls are poor too —
        // the 2026-08-01 Wi-Fi comb shape.
        let frequent = LinkHealthMeter()
        for (i, t) in [10.0, 20.0, 30.0].enumerated() {
            frequent.observe(
                ordinal: UInt64(i + 1), transitStretchMilliseconds: 30,
                sourceGapMilliseconds: 16.7,
                queueWaitMilliseconds: 0.05,
                enqueueMilliseconds: 0.03, frameSeconds: t)
        }
        let verdict = frequent.assessment()
        XCTAssertEqual(verdict.level, .poor)
        XCTAssertEqual(verdict.stallsPerMinute, 3.0)
    }

    func testBurstCoalescesToOneEpisodeAndPeakWins() {
        // One deaf-window smears across adjacent frames — the user
        // felt ONE hitch, the meter counts ONE episode at its peak.
        let meter = LinkHealthMeter()
        for (i, stretch) in [40.0, 115.0, 60.0].enumerated() {
            meter.observe(
                ordinal: UInt64(i + 1),
                transitStretchMilliseconds: stretch,
                sourceGapMilliseconds: 16.7,
                queueWaitMilliseconds: 0.05,
                enqueueMilliseconds: 0.03,
                frameSeconds: 10 + Double(i) * 0.02)
        }
        let verdict = meter.assessment()
        XCTAssertEqual(verdict.stallsPerMinute, 1.0)
        XCTAssertEqual(verdict.worstStallMilliseconds, 115)
        XCTAssertEqual(verdict.level, .poor)
    }

    func testEpisodesAgeOutBackToGood() {
        let meter = LinkHealthMeter()
        meter.observe(
            ordinal: 1, transitStretchMilliseconds: 90,
            sourceGapMilliseconds: 16.7, queueWaitMilliseconds: 0.05,
            enqueueMilliseconds: 0.03, frameSeconds: 10)
        XCTAssertEqual(meter.assessment().level, .degraded)
        // The window ages on the FRAME clock — a later clean frame
        // moves it past the stall.
        feedClean(meter, ordinals: 2..<3, at: 80)
        XCTAssertEqual(meter.assessment().level, .good)
    }

    func testStageAttributionPicksTheGuiltyParty() {
        let meter = LinkHealthMeter()
        meter.observe(
            ordinal: 1, transitStretchMilliseconds: 1,
            sourceGapMilliseconds: 120, queueWaitMilliseconds: 0.05,
            enqueueMilliseconds: 0.03, frameSeconds: 10)
        XCTAssertEqual(meter.assessment().dominantStage, "host")

        let renderer = LinkHealthMeter()
        renderer.observe(
            ordinal: 1, transitStretchMilliseconds: nil,
            sourceGapMilliseconds: nil, queueWaitMilliseconds: 9,
            enqueueMilliseconds: 3, frameSeconds: 10)
        XCTAssertEqual(
            renderer.assessment().dominantStage, "renderer")
    }

    func testRecorderResetForgetsTheOldSession() {
        let meter = LinkHealthMeter()
        meter.observe(
            ordinal: 500, transitStretchMilliseconds: 115,
            sourceGapMilliseconds: 16.7, queueWaitMilliseconds: 0.05,
            enqueueMilliseconds: 0.03, frameSeconds: 10)
        XCTAssertEqual(meter.assessment().level, .poor)
        // Reconnect: ordinals restart. The old session's stalls must
        // not haunt the new one.
        meter.observe(
            ordinal: 1, transitStretchMilliseconds: 0.5,
            sourceGapMilliseconds: 16.7, queueWaitMilliseconds: 0.05,
            enqueueMilliseconds: 0.03, frameSeconds: 11)
        XCTAssertEqual(meter.assessment().level, .good)
    }

    func testSessionBooksOutliveTheWindowAndDieWithTheSession() {
        let meter = LinkHealthMeter()
        meter.observe(
            ordinal: 1, transitStretchMilliseconds: 39,
            sourceGapMilliseconds: 16.7, queueWaitMilliseconds: 0.05,
            enqueueMilliseconds: 0.03, frameSeconds: 10)
        meter.observe(
            ordinal: 2, transitStretchMilliseconds: 27,
            sourceGapMilliseconds: 16.7, queueWaitMilliseconds: 0.05,
            enqueueMilliseconds: 0.03, frameSeconds: 20)
        // Two minutes of clean frames later the window has forgotten
        // both; the session books have not — "2 total, worst 39 ms"
        // still true.
        feedClean(meter, ordinals: 3..<4, at: 140)
        let verdict = meter.assessment()
        XCTAssertEqual(verdict.level, .good)
        XCTAssertEqual(verdict.sessionStallCount, 2)
        XCTAssertEqual(verdict.sessionWorstMilliseconds, 39)
        // A reconnect (ordinals restart) starts fresh books.
        meter.observe(
            ordinal: 1, transitStretchMilliseconds: 0.5,
            sourceGapMilliseconds: 16.7, queueWaitMilliseconds: 0.05,
            enqueueMilliseconds: 0.03, frameSeconds: 150)
        let fresh = meter.assessment()
        XCTAssertEqual(fresh.sessionStallCount, 0)
        XCTAssertEqual(fresh.sessionWorstMilliseconds, 0)
    }

    func testDuplicateOrdinalsFoldOnce() {
        let meter = LinkHealthMeter()
        for _ in 0..<5 {
            meter.observe(
                ordinal: 7, transitStretchMilliseconds: 80,
                sourceGapMilliseconds: 16.7,
                queueWaitMilliseconds: 0.05,
                enqueueMilliseconds: 0.03, frameSeconds: 10)
        }
        // Re-fed frames (the 1 Hz scan overlaps the ring) count once.
        XCTAssertEqual(meter.assessment().stallsPerMinute, 1.0)
        // A later distinct stall past the coalesce window is a second.
        meter.observe(
            ordinal: 8, transitStretchMilliseconds: 80,
            sourceGapMilliseconds: 16.7, queueWaitMilliseconds: 0.05,
            enqueueMilliseconds: 0.03, frameSeconds: 12)
        XCTAssertEqual(meter.assessment().stallsPerMinute, 2.0)
    }
}
