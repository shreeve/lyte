import XCTest
@testable import HostCore

final class SyntheticMotionSourceTests: XCTestCase {
    func testMarkerRoundTripsAndFramesDiffer() {
        let source = SyntheticMotionSource(width: 640, height: 360)
        var first: [UInt8] = []
        var second: [UInt8] = []
        source.render(frameID: 0x00A5_5A3C, into: &first)
        source.render(frameID: 0x00A5_5A3D, into: &second)

        XCTAssertEqual(source.decodedMarker(in: first), 0x00A5_5A3C)
        XCTAssertEqual(source.decodedMarker(in: second), 0x00A5_5A3D)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, 640 * 360 * 4)
    }

    func testAbsoluteScheduleDoesNotAccumulateRoundingError() {
        let schedule = SyntheticMotionSchedule(
            startNanoseconds: 9_000_000_000, fps: 60)
        XCTAssertEqual(schedule.deadline(frameID: 0), 9_000_000_000)
        XCTAssertEqual(
            schedule.deadline(frameID: 600),
            9_000_000_000 + 600 * (1_000_000_000 / 60))
    }
}
