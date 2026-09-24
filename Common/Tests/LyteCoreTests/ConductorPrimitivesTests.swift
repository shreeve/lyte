import XCTest
@testable import LyteCore

// The Conductor's shared primitives: the proof counter is the
// proof-before-shed law, and the conductor plays to the score's beat.

final class ConductorPrimitivesTests: XCTestCase {

    func testProofCounterIsTheProofBeforeShedLaw() {
        var proof = ProofCounter()
        XCTAssertFalse(proof.reached(1), "no evidence, no shed")
        proof.advance()
        proof.advance()
        XCTAssertTrue(proof.reached(2))
        XCTAssertFalse(proof.reached(3))
        proof.reset()
        XCTAssertFalse(proof.reached(1),
                       "contrary evidence starts the proof over")
        proof.advance()
        XCTAssertTrue(proof.reached(1))
    }

    func testConductorPlaysToTheScoreBeat() {
        XCTAssertEqual(
            VideoBeatConductor.Config().beatPeriodMicroseconds,
            ScoreBeat.periodMicroseconds)
    }
}
