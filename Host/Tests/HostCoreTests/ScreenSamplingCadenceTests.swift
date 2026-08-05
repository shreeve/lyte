import XCTest
@testable import HostCore

final class ScreenSamplingCadenceTests: XCTestCase {
    func testFirstObservationSamplesAndThenWaitsForBeat() {
        var cadence = ScreenSamplingCadence(periodMicroseconds: 10)

        XCTAssertEqual(cadence.poll(nowMicroseconds: 100),
                       .sample(skippedBeats: 0))
        XCTAssertEqual(cadence.poll(nowMicroseconds: 109),
                       .wait(untilMicroseconds: 110))
        XCTAssertEqual(cadence.poll(nowMicroseconds: 110),
                       .sample(skippedBeats: 0))
    }

    func testLateShellSkipsWithoutBurstAndPreservesPhase() {
        var cadence = ScreenSamplingCadence(periodMicroseconds: 10)
        _ = cadence.poll(nowMicroseconds: 100)

        XCTAssertEqual(cadence.poll(nowMicroseconds: 136),
                       .sample(skippedBeats: 2))
        XCTAssertEqual(cadence.poll(nowMicroseconds: 139),
                       .wait(untilMicroseconds: 140))
        XCTAssertEqual(cadence.poll(nowMicroseconds: 140),
                       .sample(skippedBeats: 0))
    }

    func testResetMakesTheCurrentInstantANewBeat() {
        var cadence = ScreenSamplingCadence(periodMicroseconds: 10)
        _ = cadence.poll(nowMicroseconds: 100)
        cadence.reset()

        XCTAssertEqual(cadence.poll(nowMicroseconds: 103),
                       .sample(skippedBeats: 0))
        XCTAssertEqual(cadence.poll(nowMicroseconds: 104),
                       .wait(untilMicroseconds: 113))
    }
}
