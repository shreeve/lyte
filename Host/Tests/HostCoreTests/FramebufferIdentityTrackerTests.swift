import XCTest
@testable import HostCore

final class FramebufferIdentityTrackerTests: XCTestCase {
    func testFirstAndChangedFramebufferInvalidateTheImportOnce() {
        var tracker = FramebufferIdentityTracker()
        XCTAssertEqual(tracker.observe(41), .changed(41))
        XCTAssertEqual(tracker.observe(41), .held)
        XCTAssertEqual(tracker.observe(42), .changed(42))
        XCTAssertEqual(tracker.observe(42), .held)
    }

    func testUnavailableReadDoesNotLoseThePreviousFramebuffer() {
        var tracker = FramebufferIdentityTracker()
        XCTAssertEqual(tracker.observe(41), .changed(41))
        XCTAssertEqual(tracker.observe(nil), .unavailable)
        XCTAssertEqual(tracker.observe(41), .held)
    }

    func testResetMakesTheCurrentFramebufferFreshAgain() {
        var tracker = FramebufferIdentityTracker()
        XCTAssertEqual(tracker.observe(41), .changed(41))
        tracker.reset()
        XCTAssertEqual(tracker.observe(41), .changed(41))
    }
}
