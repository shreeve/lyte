import XCTest
import HostWire

/// The encoder-VBV policy on the shipping posture: a capped VBR at the
/// wire rate whose VBV is the one-FEC-group guard. At 60 fps the budget
/// window is 25 ms, so a ceiling of C bytes is a rate of 320 × C b/s.
final class EncoderVbvGateTests: XCTestCase {
    private static let ms: UInt64 = 1_000_000
    private static let sec: UInt64 = 1_000_000_000

    /// 19,179,840 b/s: clean under a 10 Mbps recipe.
    private static let clean = 59_937
    private static let guardBits = 2_000_000

    private func policy(
        max: Int = 10_000_000, vbv: Int = guardBits
    ) -> EncoderVbvPolicy {
        EncoderVbvPolicy(config: EncoderVbvConfig(
            fps: 60, baselineMaxBitsPerSecond: max, baselineVbvBits: vbv
        ))
    }

    private func assertDirective(
        _ directive: EncoderRateDirective?,
        _ kind: EncoderRateDirective.Kind, max: Int, vbv: Int? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(directive?.kind, kind, file: file, line: line)
        XCTAssertEqual(directive?.maxBitsPerSecond, max, file: file, line: line)
        if let vbv {
            XCTAssertEqual(directive?.vbvBits, vbv, file: file, line: line)
        }
        XCTAssertNil(directive?.averageBitsPerSecond, file: file, line: line)
    }

    func testFrameBudgetWindowPinned() {
        // B = min(2/fps, 25 ms): 60 and 30 fps cap at 25 ms, 120 fps
        // rides 2/fps.
        XCTAssertEqual(RateEstimator.frameBudgetNS(fps: 60), 25_000_000)
        XCTAssertEqual(RateEstimator.frameBudgetNS(fps: 30), 25_000_000)
        XCTAssertEqual(RateEstimator.frameBudgetNS(fps: 120), 16_666_666)
    }

    // MARK: - The clean path

    func testCleanPathIssuesNothing() {
        let policy = policy()
        for i in 0..<100 {
            XCTAssertNil(policy.note(
                frameByteCeiling: Self.clean, now: UInt64(i) * 16 * Self.ms
            ))
        }
        XCTAssertEqual(policy.directivesIssued, 0)
        XCTAssertFalse(policy.squeezeEngaged)
    }

    func testCleanBoundaryIsTheDeadband() {
        // (1 − 0.1) × 10 Mbps = 9 Mbps = 28,125 B. At the line: clean.
        // One byte below: the first look engages at once, on the rate.
        let atLine = policy()
        XCTAssertEqual(atLine.cleanPathRateBitsPerSecond, 9_000_000)
        XCTAssertNil(atLine.note(frameByteCeiling: 28_125, now: 0))
        XCTAssertFalse(atLine.squeezeEngaged)

        let below = policy()
        assertDirective(
            below.note(frameByteCeiling: 28_124, now: 0),
            .tighten, max: 8_999_680, vbv: 899_968
        )
        XCTAssertTrue(below.squeezeEngaged)
    }

    func testBoundariesScaleWithTheRecipe() {
        let policy = policy(max: 50_000_000)
        XCTAssertEqual(policy.cleanPathRateBitsPerSecond, 45_000_000)
        XCTAssertNil(policy.note(frameByteCeiling: 140_625, now: 0))
        XCTAssertFalse(policy.squeezeEngaged)
        assertDirective(
            policy.note(frameByteCeiling: 140_624, now: Self.ms),
            .tighten, max: 44_999_680
        )
    }

    // MARK: - The mapping

    func testTightenLandsOnTheCeilingRateWithTheWindowLadder() {
        // vbv = k × 8 × C', k by the squeeze depth: 40% ⇒ 1, 60% ⇒ 2,
        // 70% ⇒ 3, 85% ⇒ 4.
        for (ceiling, vbv) in [
            (12_500, 100_000), (18_750, 300_000),
            (21_875, 525_000), (26_562, 849_984),
        ] {
            let directive = policy().note(frameByteCeiling: ceiling, now: 0)
            assertDirective(directive, .tighten, max: 320 * ceiling, vbv: vbv)
            XCTAssertEqual(directive?.frameByteCeiling, ceiling)
        }
        // The guard VBV caps every posture.
        assertDirective(
            policy(vbv: 166_666).note(frameByteCeiling: 26_562, now: 0),
            .tighten, max: 8_499_840, vbv: 166_666
        )
    }

    // MARK: - Hysteresis

    func testDeepFallTightensImmediatelyThroughAnyHold() {
        let policy = policy()
        XCTAssertNotNil(policy.note(frameByteCeiling: 6_000, now: 0))
        assertDirective(
            policy.note(frameByteCeiling: 1_000, now: 10 * Self.ms),
            .tighten, max: 320_000, vbv: 8_000
        )
        XCTAssertEqual(policy.directivesIssued, 2)
    }

    func testDeadbandParksAFallButAMaterialFallRetunes() {
        let policy = policy()
        _ = policy.note(frameByteCeiling: 12_500, now: 0) // 4.0 Mbps
        // −4%: ×1.1 still clears the applied max.
        XCTAssertNil(policy.note(frameByteCeiling: 12_000, now: Self.ms))
        // −12.5%: materially below.
        assertDirective(
            policy.note(frameByteCeiling: 10_937, now: 2 * Self.ms),
            .tighten, max: 3_499_840
        )
        XCTAssertEqual(policy.directivesIssued, 2)
    }

    func testRiseInsideTheDeadbandParks() {
        let policy = policy()
        _ = policy.note(frameByteCeiling: 12_500, now: 0) // 4.0 Mbps
        // +4%: the sustain tracker never arms.
        XCTAssertNil(policy.note(frameByteCeiling: 13_000, now: Self.sec))
        XCTAssertNil(policy.note(frameByteCeiling: 13_000, now: 11 * Self.sec))
        XCTAssertEqual(policy.directivesIssued, 1)

        // +2.5% from just under 5 Mbps still parks.
        let nearFive = self.policy()
        _ = nearFive.note(frameByteCeiling: 15_312, now: 0) // 4,899,840
        for seconds: UInt64 in [1, 11, 12, 20] {
            XCTAssertNil(nearFive.note(
                frameByteCeiling: 15_700, now: seconds * Self.sec
            ))
        }
        XCTAssertEqual(nearFive.directivesIssued, 1)
        XCTAssertEqual(nearFive.appliedMaxBitsPerSecond, 4_899_840)
    }

    // MARK: - The sustained loosening

    func testMaterialRiseClimbsExactlyAfterSustain() {
        let policy = policy()
        _ = policy.note(frameByteCeiling: 12_500, now: 0) // 4.0 Mbps
        // +12.5%: arms the want, which must wait out the sustain.
        XCTAssertNil(policy.note(frameByteCeiling: 14_062, now: Self.sec))
        XCTAssertNil(policy.note(frameByteCeiling: 14_062, now: 9 * Self.sec))
        assertDirective(
            policy.note(frameByteCeiling: 14_062, now: 11 * Self.sec),
            .loosen, max: 4_499_840
        )
        XCTAssertEqual(policy.directivesIssued, 2)
    }

    func testLooseningWaitsTheSustainAndLandsOnTheHeldLevel() {
        let policy = policy()
        XCTAssertNotNil(policy.note(frameByteCeiling: 1_152, now: 0))
        // 5,000 B ⇒ 1.6 Mbps; the want clock starts at the first wanting
        // poll (t = 1 s).
        for now in [Self.sec, 6 * Self.sec, 10 * Self.sec + 900 * Self.ms] {
            XCTAssertNil(policy.note(frameByteCeiling: 5_000, now: now))
        }
        assertDirective(
            policy.note(
                frameByteCeiling: 5_000, now: 11 * Self.sec + 100 * Self.ms
            ),
            .loosen, max: 1_600_000, vbv: 40_000
        )
        XCTAssertTrue(policy.squeezeEngaged)
    }

    func testMixedSustainLandsOnTheMinimumHeldLevel() {
        let policy = policy()
        XCTAssertNotNil(policy.note(frameByteCeiling: 1_152, now: 0))
        XCTAssertNil(policy.note(frameByteCeiling: 17_500, now: Self.sec))
        XCTAssertNil(policy.note(frameByteCeiling: 5_000, now: 5 * Self.sec))
        XCTAssertNil(policy.note(
            frameByteCeiling: 17_500, now: 10 * Self.sec
        ))
        assertDirective(
            policy.note(
                frameByteCeiling: 17_500, now: 11 * Self.sec + 100 * Self.ms
            ),
            .loosen, max: 1_600_000
        )
    }

    func testSawToothHuntParks() {
        // Falls inside the deadband and climbs past it, with every fall
        // arriving inside the sustain: the posture parks on the engage.
        let policy = policy()
        XCTAssertNotNil(policy.note(frameByteCeiling: 6_000, now: 0))
        var now = Self.sec
        for _ in 0..<10 {
            XCTAssertNil(policy.note(frameByteCeiling: 5_700, now: now))
            now &+= 3 * Self.sec
            XCTAssertNil(policy.note(frameByteCeiling: 9_000, now: now))
            now &+= 5 * Self.sec
        }
        XCTAssertEqual(policy.directivesIssued, 1)
        XCTAssertTrue(policy.squeezeEngaged)
        XCTAssertEqual(policy.rateMovesAbsorbed, 20)
    }

    func testAbsorbedMovesAreCountedOnlyWhenTheCeilingMoves() {
        // Repeats of one ceiling count nothing; the first poll has no
        // predecessor to move from.
        let policy = policy()
        XCTAssertNil(policy.note(frameByteCeiling: Self.clean, now: 0))
        XCTAssertNil(policy.note(frameByteCeiling: Self.clean, now: Self.ms))
        XCTAssertEqual(policy.rateMovesAbsorbed, 0)
        XCTAssertNil(policy.note(frameByteCeiling: 50_000, now: 2 * Self.ms))
        XCTAssertNil(policy.note(frameByteCeiling: 45_000, now: 3 * Self.ms))
        XCTAssertEqual(policy.rateMovesAbsorbed, 2)
        XCTAssertEqual(policy.directivesIssued, 0)
    }

    // MARK: - Recovery

    func testSustainedCleanRestoresExactlyToTheBaseline() {
        let policy = policy()
        XCTAssertNotNil(policy.note(frameByteCeiling: 13_062, now: 0))
        XCTAssertNil(policy.note(frameByteCeiling: Self.clean, now: Self.sec))
        XCTAssertNil(policy.note(
            frameByteCeiling: Self.clean, now: 10 * Self.sec
        ))
        assertDirective(
            policy.note(
                frameByteCeiling: Self.clean,
                now: 11 * Self.sec + 100 * Self.ms
            ),
            .restore, max: 10_000_000, vbv: Self.guardBits
        )
        XCTAssertFalse(policy.squeezeEngaged)
        XCTAssertNil(policy.note(
            frameByteCeiling: Self.clean, now: 12 * Self.sec
        ))
    }
}
