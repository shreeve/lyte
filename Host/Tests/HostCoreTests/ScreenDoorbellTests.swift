import XCTest
@testable import HostCore

final class ScreenDoorbellTests: XCTestCase {
    func testFirstAndChangedFramebufferRingOnce() {
        var doorbell = ScreenDoorbell()
        XCTAssertEqual(doorbell.observe(41), .changed(41))
        XCTAssertEqual(doorbell.observe(41), .held)
        XCTAssertEqual(doorbell.observe(42), .changed(42))
        XCTAssertEqual(doorbell.observe(42), .held)
    }

    func testUnavailableReadDoesNotLoseThePreviousFramebuffer() {
        var doorbell = ScreenDoorbell()
        XCTAssertEqual(doorbell.observe(41), .changed(41))
        XCTAssertEqual(doorbell.observe(nil), .unavailable)
        XCTAssertEqual(doorbell.observe(41), .held)
    }

    func testResetMakesTheCurrentFramebufferFreshAgain() {
        var doorbell = ScreenDoorbell()
        XCTAssertEqual(doorbell.observe(41), .changed(41))
        doorbell.reset()
        XCTAssertEqual(doorbell.observe(41), .changed(41))
    }
}
