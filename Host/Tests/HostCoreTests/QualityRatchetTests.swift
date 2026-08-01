import XCTest
import HostCore

final class QualityRatchetTests: XCTestCase {
    func testBestLiveTransientAllSkipDoesNotConvergeAboveFloor() {
        var policy = QualityRatchetConvergence(floorQP: 4)
        let livePrefix = [
            (36_647, 48),
            (74_398, 46),
            (139_203, 43),
            (110, 49),
        ]

        for (bytes, qp) in livePrefix {
            XCTAssertFalse(policy.note(bytes: bytes, averageQP: qp))
        }
        XCTAssertEqual(policy.stablePasses, 0)

        // The matched production C-leaf continuation after the transient
        // all-skip: quality work resumes immediately and eventually reaches
        // qmin. Only three stable floor-qualified deltas earn silence.
        XCTAssertFalse(policy.note(bytes: 161_304, averageQP: 40))
        XCTAssertFalse(policy.note(bytes: 4_558, averageQP: 4))
        XCTAssertFalse(policy.note(bytes: 98, averageQP: 4))
        XCTAssertFalse(policy.note(bytes: 98, averageQP: 4))
        XCTAssertFalse(policy.note(bytes: 98, averageQP: 4))
        XCTAssertTrue(policy.note(bytes: 98, averageQP: 4))
    }

    func testSmallPacketsNeverConvergeWhileAboveFloor() {
        var policy = QualityRatchetConvergence(floorQP: 12)
        for _ in 0..<20 {
            XCTAssertFalse(policy.note(bytes: 96, averageQP: 13))
        }
        XCTAssertEqual(policy.stablePasses, 0)
    }

    func testUnstableFloorPacketsResetTheStabilityRun() {
        var policy = QualityRatchetConvergence(floorQP: 4)
        XCTAssertFalse(policy.note(bytes: 10_000, averageQP: 4))
        XCTAssertFalse(policy.note(bytes: 10_050, averageQP: 4))
        XCTAssertFalse(policy.note(bytes: 10_100, averageQP: 4))
        XCTAssertFalse(policy.note(bytes: 20_000, averageQP: 4))
        XCTAssertEqual(policy.stablePasses, 0)
    }

    func testResetStartsANewDamageEpisode() {
        var policy = QualityRatchetConvergence(
            floorQP: 4, requiredStablePasses: 1)
        XCTAssertFalse(policy.note(bytes: 98, averageQP: 4))
        XCTAssertTrue(policy.note(bytes: 98, averageQP: 4))
        policy.reset()
        XCTAssertFalse(policy.note(bytes: 98, averageQP: 4))
    }

    func testSecondDamageWakeMustReearnFloorStability() {
        var policy = QualityRatchetConvergence(floorQP: 4)
        XCTAssertFalse(policy.note(bytes: 31_626, averageQP: 4))
        XCTAssertFalse(policy.note(bytes: 98, averageQP: 4))
        XCTAssertFalse(policy.note(bytes: 98, averageQP: 4))
        XCTAssertFalse(policy.note(bytes: 98, averageQP: 4))
        XCTAssertTrue(policy.note(bytes: 98, averageQP: 4))

        // A genuine second capture abandons the converged episode. This is
        // the live wake's shape: large work, then a transient all-skip-like
        // packet at QP 8. Neither prior stability nor the tiny packet may
        // silence the new walk.
        policy.reset()
        XCTAssertFalse(policy.note(bytes: 125_728, averageQP: 45))
        XCTAssertFalse(policy.note(bytes: 185_558, averageQP: 35))
        XCTAssertFalse(policy.note(bytes: 1_934, averageQP: 8))
        XCTAssertEqual(policy.stablePasses, 0)

        XCTAssertFalse(policy.note(bytes: 28_856, averageQP: 4))
        XCTAssertFalse(policy.note(bytes: 96, averageQP: 4))
        XCTAssertFalse(policy.note(bytes: 96, averageQP: 4))
        XCTAssertFalse(policy.note(bytes: 96, averageQP: 4))
        XCTAssertTrue(policy.note(bytes: 96, averageQP: 4))
    }
}
