import XCTest
@testable import LyteTransport

// The Conductor's remaining shared primitive: the proof counter must be
// exactly the law all three call sites already lived. Histogram retention
// and rank doctrine are pinned in LyteCoreTests.

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
}
