import XCTest
@testable import LyteTransport

/// The user-facing video-health law: successful correction is silent. Only a
/// terminal, uncorrectable presentation miss or renderer failure enters the
/// rolling warning window. Lateness on a preserved frame remains diagnostic
/// only. Episodes still coalesce, age out, and survive the same session/roaming
/// boundaries as before.
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

    private func observe(
        _ meter: LinkHealthMeter,
        ordinal: UInt64,
        at time: TimeInterval,
        lateness: Double? = nil,
        dropped: Bool = false,
        failed: Bool = false
    ) {
        let outcome: LinkHealthMeter.Outcome
        if failed {
            outcome = .rendererFailure
        } else if dropped {
            outcome = .uncorrectableMiss
        } else {
            outcome = .preserved
        }
        meter.observe(
            ordinal: ordinal,
            presentationLatenessMilliseconds: lateness,
            outcome: outcome,
            eventMicroseconds: micros(time))
    }

    private func anchor(_ meter: LinkHealthMeter, at time: TimeInterval = 0) {
        observe(meter, ordinal: 1, at: time)
    }

    func testSuccessfulFramesAreSilent() {
        let meter = LinkHealthMeter()
        anchor(meter)
        for ordinal in UInt64(2)..<120 {
            observe(meter, ordinal: ordinal, at: 20)
        }
        let verdict = assessment(meter, at: 20)
        XCTAssertEqual(verdict.level, .good)
        XCTAssertEqual(verdict.stallsLastMinute, 0)
        XCTAssertEqual(verdict.dominantStage, "none")
    }

    func testWarmupGraceSwallowsTheConnectRamp() {
        let meter = LinkHealthMeter()
        anchor(meter)
        observe(meter, ordinal: 2, at: 3, lateness: 115)
        observe(meter, ordinal: 3, at: 9, dropped: true)
        XCTAssertEqual(assessment(meter, at: 9).level, .good)

        observe(meter, ordinal: 4, at: 15, lateness: 88, dropped: true)
        let verdict = assessment(meter, at: 15)
        XCTAssertEqual(verdict.level, .degraded)
        XCTAssertEqual(verdict.sessionStallCount, 1)
    }

    func testAnyLatenessOnPreservedFramesStaysSilent() {
        let meter = LinkHealthMeter()
        anchor(meter)
        for (index, lateness) in [0.999, 16.667, 49, 400].enumerated() {
            observe(
                meter, ordinal: UInt64(index + 2),
                at: 15 + Double(index), lateness: lateness)
        }

        let verdict = assessment(meter, at: 20)
        XCTAssertEqual(verdict.level, .good)
        XCTAssertEqual(verdict.stallsLastMinute, 0)
        XCTAssertEqual(verdict.sessionStallCount, 0)
        XCTAssertEqual(verdict.dominantStage, "none")
    }

    func testUncorrectableMissUsesMeasuredLatenessAsMagnitude() {
        let meter = LinkHealthMeter()
        anchor(meter)
        observe(
            meter, ordinal: 2, at: 15,
            lateness: 49, dropped: true)

        let verdict = assessment(meter, at: 15)
        XCTAssertEqual(verdict.level, .degraded)
        XCTAssertEqual(verdict.stallsLastMinute, 1)
        XCTAssertEqual(
            verdict.worstStallMilliseconds, 49)
        XCTAssertEqual(verdict.dominantStage, "miss")
    }

    func testRendererDropOrFailureIsReportedWithoutInventedDuration() {
        for failure in [(dropped: true, failed: false),
                        (dropped: false, failed: true)] {
            let meter = LinkHealthMeter()
            anchor(meter)
            observe(
                meter, ordinal: 2, at: 15,
                dropped: failure.dropped, failed: failure.failed)

            let verdict = assessment(meter, at: 15)
            XCTAssertEqual(verdict.level, .degraded)
            XCTAssertEqual(verdict.stallsLastMinute, 1)
            XCTAssertEqual(verdict.worstStallMilliseconds, 0)
            XCTAssertEqual(
                verdict.dominantStage,
                failure.failed ? "renderer" : "miss")
        }
    }

    func testDeepOrFrequentFailuresArePoor() {
        let deep = LinkHealthMeter()
        anchor(deep)
        observe(deep, ordinal: 2, at: 15, lateness: 115, dropped: true)
        XCTAssertEqual(assessment(deep, at: 15).level, .poor)

        let frequent = LinkHealthMeter()
        anchor(frequent)
        for (index, time) in [15.0, 25.0, 35.0].enumerated() {
            observe(
                frequent, ordinal: UInt64(index + 2),
                at: time, lateness: 20, dropped: true)
        }
        let verdict = assessment(frequent, at: 35)
        XCTAssertEqual(verdict.level, .poor)
        XCTAssertEqual(verdict.stallsLastMinute, 3)
    }

    func testConsecutiveFailedFramesCoalesceAndPeakWins() {
        let meter = LinkHealthMeter()
        anchor(meter)
        observe(meter, ordinal: 2, at: 15.00,
                lateness: 20, dropped: true)
        observe(meter, ordinal: 3, at: 15.02,
                lateness: 19, dropped: true)
        observe(meter, ordinal: 4, at: 15.04,
                lateness: 18, dropped: true)

        let verdict = assessment(meter, at: 15.04)
        XCTAssertEqual(verdict.stallsLastMinute, 1)
        XCTAssertEqual(verdict.sessionStallCount, 1)
        XCTAssertEqual(verdict.worstStallMilliseconds, 20)
        XCTAssertEqual(verdict.dominantStage, "miss")
    }

    func testUncorrectableMissCanCarrySubBeatMagnitude() {
        let meter = LinkHealthMeter()
        anchor(meter)
        observe(
            meter, ordinal: 2, at: 15,
            lateness: 0.8, dropped: true)

        let verdict = assessment(meter, at: 15)
        XCTAssertEqual(verdict.level, .degraded)
        XCTAssertEqual(verdict.stallsLastMinute, 1)
        XCTAssertEqual(verdict.worstStallMilliseconds, 0.8)
        XCTAssertEqual(verdict.dominantStage, "miss")
    }

    func testRendererEpisodeCanBecomeMeasuredLateWithoutDoubleCounting() {
        let meter = LinkHealthMeter()
        anchor(meter)
        observe(meter, ordinal: 2, at: 15.0, failed: true)
        observe(meter, ordinal: 3, at: 15.1,
                lateness: 22, dropped: true)

        let verdict = assessment(meter, at: 15.1)
        XCTAssertEqual(verdict.stallsLastMinute, 1)
        XCTAssertEqual(verdict.sessionStallCount, 1)
        XCTAssertEqual(verdict.worstStallMilliseconds, 22)
        XCTAssertEqual(verdict.dominantStage, "miss")
    }

    func testFailuresAgeOutWhileSessionBooksSurvive() {
        let meter = LinkHealthMeter()
        anchor(meter)
        observe(meter, ordinal: 2, at: 15,
                lateness: 39, dropped: true)
        observe(meter, ordinal: 3, at: 25, failed: true)

        let aged = assessment(meter, at: 85)
        XCTAssertEqual(aged.level, .good)
        XCTAssertEqual(aged.stallsLastMinute, 0)
        XCTAssertEqual(aged.worstStallMilliseconds, 0)
        XCTAssertEqual(aged.sessionStallCount, 2)
        XCTAssertEqual(aged.sessionWorstMilliseconds, 39)
    }

    func testRoamStartsFreshWindowAndKeepsSessionBooks() {
        let meter = LinkHealthMeter()
        anchor(meter)
        observe(meter, ordinal: 2, at: 15,
                lateness: 88, dropped: true)
        XCTAssertEqual(assessment(meter, at: 15).sessionStallCount, 1)

        meter.resetEpochKeepingSessionBooks()
        observe(meter, ordinal: 1, at: 100,
                lateness: 115, dropped: true)
        let ramp = assessment(meter, at: 100)
        XCTAssertEqual(ramp.level, .good)
        XCTAssertEqual(ramp.stallsLastMinute, 0)
        XCTAssertEqual(ramp.sessionStallCount, 1)

        observe(meter, ordinal: 2, at: 115,
                lateness: 20, dropped: true)
        XCTAssertEqual(assessment(meter, at: 115).sessionStallCount, 2)
    }

    func testSessionResetClearsAllBooks() {
        let meter = LinkHealthMeter()
        anchor(meter)
        observe(meter, ordinal: 2, at: 15,
                lateness: 39, dropped: true)
        meter.resetSessionBooks()

        let fresh = assessment(meter, at: 15)
        XCTAssertEqual(fresh.level, .good)
        XCTAssertEqual(fresh.sessionStallCount, 0)
        XCTAssertEqual(fresh.sessionWorstMilliseconds, 0)
    }

    func testDuplicateOrdinalsFoldOnce() {
        let meter = LinkHealthMeter()
        anchor(meter)
        for _ in 0..<5 {
            observe(meter, ordinal: 7, at: 15,
                    lateness: 20, dropped: true)
        }
        XCTAssertEqual(assessment(meter, at: 15).stallsLastMinute, 1)

        observe(meter, ordinal: 8, at: 17,
                lateness: 20, dropped: true)
        XCTAssertEqual(assessment(meter, at: 17).stallsLastMinute, 2)
    }

    func testOneSecondBucketCountsDistinctEpisodes() {
        let meter = LinkHealthMeter()
        anchor(meter)
        observe(meter, ordinal: 2, at: 15.00,
                lateness: 20, dropped: true)
        observe(meter, ordinal: 3, at: 15.75, failed: true)

        let verdict = assessment(meter, at: 15.99)
        XCTAssertEqual(verdict.stallsLastMinute, 2)
        XCTAssertEqual(verdict.sessionStallCount, 2)
        XCTAssertEqual(verdict.worstStallMilliseconds, 20)
    }

    func testExactlySixtyOneSecondBucketsRollAtTheBoundary() {
        let meter = LinkHealthMeter()
        anchor(meter)
        observe(meter, ordinal: 2, at: 15,
                lateness: 20, dropped: true)
        observe(meter, ordinal: 3, at: 16,
                lateness: 21, dropped: true)

        XCTAssertEqual(assessment(meter, at: 74.999).stallsLastMinute, 2)
        XCTAssertEqual(assessment(meter, at: 75).stallsLastMinute, 1)
        XCTAssertEqual(assessment(meter, at: 76).stallsLastMinute, 0)
    }

    func testRingSlotReuseCannotResurrectOldFailure() {
        let meter = LinkHealthMeter()
        anchor(meter)
        observe(meter, ordinal: 2, at: 15,
                lateness: 20, dropped: true)
        observe(meter, ordinal: 3, at: 75,
                lateness: 21, dropped: true)

        let verdict = assessment(meter, at: 75)
        XCTAssertEqual(verdict.stallsLastMinute, 1)
        XCTAssertEqual(verdict.sessionStallCount, 2)
        XCTAssertEqual(verdict.worstStallMilliseconds, 21)
    }
}
