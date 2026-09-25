@testable import HostEye
import XCTest

final class EyeBookkeepingTests: XCTestCase {
    func testGemHandlesCloseOncePerDistinctBufferObject() {
        XCTAssertEqual(uniqueGemHandles([7, 0, 0, 0]), [7])
        // CCS: the main and aux planes share one BO handle.
        XCTAssertEqual(uniqueGemHandles([7, 7, 9, 0]), [7, 9])
        XCTAssertEqual(uniqueGemHandles([0, 0, 0, 0]), [])
    }

    func testCursorPlaneDisabledAfterAShapeReportsHiddenOnce() {
        var latch = CursorFramebufferLatch()
        XCTAssertEqual(latch.observe(41), .read(41))
        latch.latch(41)
        XCTAssertEqual(latch.observe(41), .unchanged)
        XCTAssertEqual(latch.observe(0), .hidden)
        XCTAssertEqual(latch.observe(0), .unchanged)
        XCTAssertEqual(latch.observe(41), .read(41))
    }

    func testUnreadablePlaneAndFailedReadsDoNotLatch() {
        var latch = CursorFramebufferLatch()
        XCTAssertEqual(latch.observe(nil), .unchanged)
        XCTAssertEqual(latch.observe(12), .read(12))
        // The caller's read failed: no latch, so the next poll retries.
        XCTAssertEqual(latch.observe(12), .read(12))
        latch.latch(12)
        XCTAssertEqual(latch.observe(nil), .unchanged)
        XCTAssertEqual(latch.last, 12)
    }
}
