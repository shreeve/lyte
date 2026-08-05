import XCTest
@testable import LyteCore

// The Conductor's video instrument, law by law
// (docs/20260803-050422-metronome-playout-design.md): cue, beat,
// late, hole, slip, chain. The debt/flush recovery pins carried over
// from the retired adaptive playout.

final class VideoBeatConductorTests: XCTestCase {
    private let period: UInt64 = 16_667

    private func conductor(
        cushionBeats: Int = 2,
        maximumCushionBeats: Int = 8,
        maximumCueMicroseconds: UInt64 = 120_000,
        slipProofFrames: Int = 4
    ) -> VideoBeatConductor {
        VideoBeatConductor(config: .init(
            beatPeriodMicroseconds: period,
            cushionBeats: cushionBeats,
            maximumCushionBeats: maximumCushionBeats,
            maximumCueMicroseconds: maximumCueMicroseconds,
            slipProofFrames: slipProofFrames))
    }

    func testShippingConfigStartsAutomaticAtOneBeat() {
        let config = VideoBeatConductor.Config()
        XCTAssertEqual(config.cushionBeats, 1)
        XCTAssertEqual(config.maximumCushionBeats, 4)
        XCTAssertEqual(config.maximumCueMicroseconds, 150_000)
        XCTAssertEqual(config.slipProofFrames, 120)
    }

    func testShippingCushionGrowsFromOneBeatToFourAndNoFurther() {
        var policy = conductor(
            cushionBeats: 1,
            maximumCushionBeats: 4,
            maximumCueMicroseconds: 150_000,
            slipProofFrames: 120)
        var capture: UInt64 = 1_000_000
        let first = policy.schedule(
            mappedCaptureMicroseconds: capture,
            arrivalMicroseconds: capture &+ 9_000,
            sourceCaptureMicroseconds: capture)
        XCTAssertEqual(first.reserveMicroseconds, period)

        // A hole large enough to ask for far more than the allowed range
        // consumes the three remaining beats and stays honestly late.
        capture &+= period
        let hole = policy.schedule(
            mappedCaptureMicroseconds: capture,
            arrivalMicroseconds: capture &+ 200_000,
            sourceCaptureMicroseconds: capture)
        XCTAssertEqual(hole.cueMicroseconds, 9_000 + 4 * period)
        XCTAssertGreaterThan(hole.latenessMicroseconds, 0)

        // Another hole cannot mint a fifth reserve beat. Once ordinary air
        // returns, the decision exposes exactly the four-beat posture.
        capture &+= period
        let secondHole = policy.schedule(
            mappedCaptureMicroseconds: capture,
            arrivalMicroseconds: capture &+ 200_000,
            sourceCaptureMicroseconds: capture)
        XCTAssertEqual(secondHole.cueMicroseconds, 9_000 + 4 * period)
        capture &+= period
        let calm = policy.schedule(
            mappedCaptureMicroseconds: capture,
            arrivalMicroseconds: capture &+ 9_000,
            sourceCaptureMicroseconds: capture)
        XCTAssertEqual(calm.reserveMicroseconds, 4 * period)
    }

    func testShippingCushionReturnsTowardOneBeatOnlyAfterCleanProof() {
        var policy = conductor(
            cushionBeats: 1,
            maximumCushionBeats: 4,
            maximumCueMicroseconds: 150_000,
            slipProofFrames: 120)
        var capture: UInt64 = 1_000_000
        _ = policy.schedule(
            mappedCaptureMicroseconds: capture,
            arrivalMicroseconds: capture &+ 9_000,
            sourceCaptureMicroseconds: capture)

        capture &+= period
        _ = policy.schedule(
            mappedCaptureMicroseconds: capture,
            arrivalMicroseconds: capture &+ 200_000,
            sourceCaptureMicroseconds: capture)

        var finalReserve: UInt64 = 0
        // The one bad path sample must age out of the p99 evidence before
        // clean proof can return the three extra beats one at a time.
        for _ in 0..<600 {
            capture &+= period
            let decision = policy.schedule(
                mappedCaptureMicroseconds: capture,
                arrivalMicroseconds: capture &+ 9_000,
                sourceCaptureMicroseconds: capture)
            finalReserve = decision.reserveMicroseconds
        }
        XCTAssertEqual(finalReserve, period)
    }

    /// beat: perfectly authored captures with jittered arrivals still
    /// present on an exact beat grid — every delta is one period.
    func testEveryFreshFramePresentsOnTheBeatGrid() {
        var policy = conductor()
        let jitter: [UInt64] = [0, 3_000, 1_200, 4_800, 900, 2_500,
                                4_000, 100, 3_700, 2_000]
        var presentations: [UInt64] = []
        for (index, wobble) in jitter.enumerated() {
            let capture = 1_000_000 &+ UInt64(index) &* period
            let decision = policy.schedule(
                mappedCaptureMicroseconds: capture,
                arrivalMicroseconds: capture &+ 9_000 &+ wobble,
                sourceCaptureMicroseconds: capture)
            presentations.append(decision.presentationMicroseconds)
        }
        for (left, right) in zip(presentations, presentations.dropFirst()) {
            XCTAssertEqual(right - left, period,
                           "the cadence never breathes")
        }
    }

    /// beat: capture-stamp wobble under half a beat rounds away —
    /// the half-beat bias in action.
    func testCaptureJitterIsAbsorbedByRounding() {
        var policy = conductor()
        let stampWobble: [Int64] = [0, 2_000, -3_000, 1_500, -900,
                                    3_900, -2_200, 800]
        var presentations: [UInt64] = []
        for (index, wobble) in stampWobble.enumerated() {
            let authored = 1_000_000 &+ UInt64(index) &* period
            let capture = UInt64(Int64(authored) + wobble)
            let decision = policy.schedule(
                mappedCaptureMicroseconds: capture,
                arrivalMicroseconds: authored &+ 10_000,
                sourceCaptureMicroseconds: capture)
            presentations.append(decision.presentationMicroseconds)
        }
        for (left, right) in zip(presentations, presentations.dropFirst()) {
            XCTAssertEqual(right - left, period,
                           "stamp wobble must not move the beat")
        }
    }

    /// late: a frame under one beat behind KEEPS its passed beat —
    /// never rescheduled to arrival — and the cue does not move.
    func testLateFrameKeepsItsBeatAndNeverPresentsAtArrival() {
        var policy = conductor()
        var expected: UInt64 = 0
        // The cue is 9 000 (frame 0's path delay) + 2 beats = 42 334;
        // the straggler lands 10 000 past its beat — under one beat,
        // so the late law holds it and the cue must not move.
        for index in 0..<6 {
            let capture = 1_000_000 &+ UInt64(index) &* period
            let arrival = index == 3
                ? capture &+ 52_334
                : capture &+ 9_000
            let decision = policy.schedule(
                mappedCaptureMicroseconds: capture,
                arrivalMicroseconds: arrival,
                sourceCaptureMicroseconds: capture)
            if index == 0 { expected = decision.presentationMicroseconds }
            XCTAssertEqual(decision.presentationMicroseconds, expected,
                           "frame \(index) must hold the grid")
            if index == 3 {
                XCTAssertGreaterThan(decision.latenessMicroseconds, 0)
                XCTAssertLessThan(decision.presentationMicroseconds, arrival,
                                  "a late part is never rescheduled")
            } else {
                XCTAssertEqual(decision.latenessMicroseconds, 0)
            }
            expected &+= period
        }
    }

    /// chain (retained): the same authored pixels re-encoded ride one
    /// microsecond behind their predecessor, no beat claimed, no
    /// lateness minted.
    func testRetainedRefinementRidesJustBehindItsPredecessor() {
        var policy = conductor()
        let capture: UInt64 = 1_000_000
        let first = policy.schedule(
            mappedCaptureMicroseconds: capture,
            arrivalMicroseconds: capture &+ 9_000,
            sourceCaptureMicroseconds: capture)
        let refinement = policy.schedule(
            mappedCaptureMicroseconds: capture,
            arrivalMicroseconds: capture &+ 1_009_000,
            sourceCaptureMicroseconds: capture)
        XCTAssertGreaterThan(
            refinement.presentationMicroseconds,
            first.presentationMicroseconds)
        XCTAssertEqual(refinement.latenessMicroseconds, 0)
        XCTAssertFalse(refinement.shouldFlush)
    }

    /// hole: a blackout re-cues by WHOLE beats exactly once — the
    /// phase survives, the burst's stale beats stay in the past, and
    /// the stream lands back on the grid.
    func testBlackoutRecuesWholeBeatsOnceAndPhaseSurvives() {
        var policy = conductor()
        var anchor: UInt64 = 0
        for index in 0..<3 {
            let capture = 1_000_000 &+ UInt64(index) &* period
            let decision = policy.schedule(
                mappedCaptureMicroseconds: capture,
                arrivalMicroseconds: capture &+ 9_000,
                sourceCaptureMicroseconds: capture)
            if index == 0 { anchor = decision.presentationMicroseconds }
        }
        // 120 ms of darkness; the next fresh frame arrives all at once.
        let gapFrames: UInt64 = 8
        let capture = 1_000_000 &+ (2 &+ gapFrames) &* period
        let arrival = capture &+ 9_000 &+ 70_000
        let decision = policy.schedule(
            mappedCaptureMicroseconds: capture,
            arrivalMicroseconds: arrival,
            sourceCaptureMicroseconds: capture)
        XCTAssertGreaterThanOrEqual(
            decision.presentationMicroseconds, arrival,
            "the re-cued part lands on a future beat")
        XCTAssertEqual(
            (decision.presentationMicroseconds - anchor) % period, 0,
            "re-cue moves whole beats — the phase is sacred")
        // The follower is back on the grid, one beat later.
        let next = policy.schedule(
            mappedCaptureMicroseconds: capture &+ period,
            arrivalMicroseconds: capture &+ period &+ 9_000,
            sourceCaptureMicroseconds: capture &+ period)
        XCTAssertEqual(
            next.presentationMicroseconds
                - decision.presentationMicroseconds,
            period)
    }

    /// slip: sustained proof of a beat of surplus hands exactly one
    /// beat back, phase preserved.
    func testSlipComesBackOneBeatAfterProof() {
        var policy = conductor(slipProofFrames: 4)
        var anchor: UInt64 = 0
        for index in 0..<3 {
            let capture = 1_000_000 &+ UInt64(index) &* period
            let decision = policy.schedule(
                mappedCaptureMicroseconds: capture,
                arrivalMicroseconds: capture &+ 9_000,
                sourceCaptureMicroseconds: capture)
            if index == 0 { anchor = decision.presentationMicroseconds }
        }
        // A two-beat excursion re-cues the grid (+2 beats)…
        let lateCapture = 1_000_000 &+ 3 &* period
        _ = policy.schedule(
            mappedCaptureMicroseconds: lateCapture,
            arrivalMicroseconds: lateCapture &+ 61_001,
            sourceCaptureMicroseconds: lateCapture)
        // …then calm air proves the surplus. Slip is tail-gated: the
        // excursion's sample must age past the p99 index (~200 fresh
        // frames) before the first beat returns, then the second.
        var cues: [UInt64] = []
        var offBeatFrames = 0
        var finalPhases: [UInt64] = []
        for index in 4..<300 {
            let capture = 1_000_000 &+ UInt64(index) &* period
            let decision = policy.schedule(
                mappedCaptureMicroseconds: capture,
                arrivalMicroseconds: capture &+ 9_000,
                sourceCaptureMicroseconds: capture)
            cues.append(decision.cueMicroseconds)
            let phase = (decision.presentationMicroseconds - anchor) % period
            if phase != 0 { offBeatFrames += 1 }
            if index >= 290 { finalPhases.append(phase) }
        }
        XCTAssertEqual(cues.first! - cues.last!, 2 &* period,
                       "the excursion's two beats come back, one per proof")
        XCTAssertEqual(cues.last!, 9_000 &+ 2 &* period,
                       "the cue settles exactly back at tail + cushion")
        // Each slip retires exactly one beat: its transitional frame
        // rides a microsecond behind its predecessor (the controlled
        // slip itself); everything else stays on the grid.
        XCTAssertLessThanOrEqual(offBeatFrames, 2,
                                 "one transitional frame per slip")
        XCTAssertTrue(finalPhases.allSatisfy { $0 == 0 },
                      "the settled stream is back on the beat")
    }

    /// Two captures crowding one beat still leave strictly
    /// increasing presentation stamps.
    func testMonotonicPresentationUnderBeatCollision() {
        var policy = conductor()
        let capture: UInt64 = 1_000_000
        let first = policy.schedule(
            mappedCaptureMicroseconds: capture,
            arrivalMicroseconds: capture &+ 9_000,
            sourceCaptureMicroseconds: capture)
        let crowded = policy.schedule(
            mappedCaptureMicroseconds: capture &+ 2_000,
            arrivalMicroseconds: capture &+ 11_000,
            sourceCaptureMicroseconds: capture &+ 2_000)
        XCTAssertGreaterThan(
            crowded.presentationMicroseconds,
            first.presentationMicroseconds)
    }

    func testDecisionSeparatesTotalCueFromPathAndReserve() {
        var policy = conductor(cushionBeats: 3)
        let decision = policy.schedule(
            mappedCaptureMicroseconds: 1_000_000,
            arrivalMicroseconds: 1_009_000,
            sourceCaptureMicroseconds: 1_000_000)

        XCTAssertEqual(decision.pathDelayMicroseconds, 9_000)
        XCTAssertEqual(decision.cueMicroseconds, 9_000 + 3 * period)
        XCTAssertEqual(decision.reserveMicroseconds, 3 * period)
        XCTAssertEqual(
            decision.cueMicroseconds,
            decision.pathDelayMicroseconds + decision.reserveMicroseconds)
    }

    /// Debt (ported pin): a genuinely compressed blackout burst
    /// beyond the ceiling starts ONE bounded recovery; ordinary
    /// jitter never does; thirty stable frames re-arm.
    func testFreshBlackoutBurstStartsOneBoundedDebtRecovery() {
        var policy = conductor()
        var flushes = 0
        var capture: UInt64 = 1_000_000
        var arrival = capture &+ 9_000
        _ = policy.schedule(
            mappedCaptureMicroseconds: capture,
            arrivalMicroseconds: arrival,
            sourceCaptureMicroseconds: capture)
        // A 300 ms authored span arrives in a 3 ms squeeze.
        for _ in 0..<18 {
            capture &+= period
            arrival &+= 150
            let decision = policy.schedule(
                mappedCaptureMicroseconds: capture,
                arrivalMicroseconds: arrival,
                sourceCaptureMicroseconds: capture)
            if decision.shouldFlush { flushes += 1 }
        }
        XCTAssertEqual(flushes, 1, "one recovery per episode")
        policy.noteRandomAccessEnqueued()
        // Thirty cadence-stable frames re-arm the trigger.
        for _ in 0..<31 {
            capture &+= period
            arrival = capture &+ 9_000
            let decision = policy.schedule(
                mappedCaptureMicroseconds: capture,
                arrivalMicroseconds: arrival,
                sourceCaptureMicroseconds: capture)
            XCTAssertFalse(decision.shouldFlush)
        }
        for _ in 0..<18 {
            capture &+= period
            arrival &+= 150
            let decision = policy.schedule(
                mappedCaptureMicroseconds: capture,
                arrivalMicroseconds: arrival,
                sourceCaptureMicroseconds: capture)
            if decision.shouldFlush { flushes += 1 }
        }
        XCTAssertEqual(flushes, 2, "a fresh episode may recover again")
    }

    /// The rig's regression, pinned: a safety ceiling below the cue's
    /// aspiration pins the measured cue at the ceiling, and clock-map
    /// residual wobble must not cut or collide the grid — every gap
    /// stays exactly one beat.
    func testPinnedCeilingDoesNotChatterTheGrid() {
        var policy = conductor(cushionBeats: 2,
                               maximumCueMicroseconds: 25_000)
        let residual: [Int64] = [0, 400, -600, 700, -300, 200,
                                 -700, 500, -200, 650, -450, 100]
        var last: UInt64 = 0
        var gaps: [UInt64] = []
        for (index, wobble) in residual.enumerated() {
            let authored = 1_000_000 &+ UInt64(index) &* period
            let mapped = UInt64(Int64(authored) + wobble)
            let decision = policy.schedule(
                mappedCaptureMicroseconds: mapped,
                arrivalMicroseconds: authored &+ 10_000,
                sourceCaptureMicroseconds: authored)
            if index > 0 {
                gaps.append(decision.presentationMicroseconds - last)
            }
            last = decision.presentationMicroseconds
        }
        XCTAssertTrue(gaps.allSatisfy { $0 == period },
                      "the grid must not chatter at the ceiling: \(gaps)")
    }
}
