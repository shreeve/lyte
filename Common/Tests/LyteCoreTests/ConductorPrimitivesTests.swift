import XCTest
@testable import LyteCore

// The conductor plays to the score's beat.

final class ConductorPrimitivesTests: XCTestCase {

    func testConductorPlaysToTheScoreBeat() {
        XCTAssertEqual(
            VideoBeatConductor.Config().beatPeriodMicroseconds,
            ScoreBeat.periodMicroseconds)
    }
}
