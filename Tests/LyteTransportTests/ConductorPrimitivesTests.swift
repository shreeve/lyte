import XCTest
@testable import LyteTransport

// The Conductor's shared primitives: the tail ring must be
// byte-for-byte the retired video-private estimator (nearest-rank
// upper tail over a rolling window), and the proof counter must be
// exactly the law all three call sites already lived.

final class ConductorPrimitivesTests: XCTestCase {

    func testTailMatchesTheRetiredVideoFormula() {
        // The retired formula: sorted[min(count-1, (count*99+99)/100-1)].
        for count in [1, 5, 99, 100, 101, 599, 600] {
            var ring = BeatTailRing(capacity: 600)
            for value in 1...count { ring.note(UInt64(value)) }
            let expectedIndex = min(count - 1, (count * 99 + 99) / 100 - 1)
            XCTAssertEqual(
                ring.tail(percentile: 99), UInt64(expectedIndex + 1),
                "count \(count): nearest-rank p99 must match the "
                + "retired private estimator exactly")
        }
    }

    func testEmptyRingClaimsNoDelay() {
        let ring = BeatTailRing(capacity: 8)
        XCTAssertEqual(ring.tail(percentile: 99), 0)
    }

    func testRingIsRollingNewestWindow() {
        var ring = BeatTailRing(capacity: 4)
        for value in [100, 200, 300, 400, 1, 2] as [UInt64] {
            ring.note(value)
        }
        // Window is now [300, 400, 1, 2]; p99 = max = 400. The evicted
        // 100/200 must be gone; the tail describes the newest window.
        XCTAssertEqual(ring.tail(percentile: 99), 400)
        ring.note(3); ring.note(4)
        XCTAssertEqual(ring.tail(percentile: 99), 4,
                       "once the old spike leaves the window the tail"
                       + " follows the fresh evidence")
    }

    func testRemoveAllForgetsEverything() {
        var ring = BeatTailRing(capacity: 4)
        ring.note(999)
        ring.removeAll()
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.tail(percentile: 99), 0)
        ring.note(7)
        XCTAssertEqual(ring.tail(percentile: 99), 7)
    }

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
