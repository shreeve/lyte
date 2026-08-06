import XCTest
@testable import HostCore

final class CursorHotspotTests: XCTestCase {
    func testArrowTipFromSettledPlane() {
        // Adwaita-ish left_ptr: pointer (100, 40), plane at tip − hotspot,
        // crop (0, 1), content 23×31, hotspot ≈ (4, 0) in the crop.
        let hot = CursorHotspot.derive(
            pointer: .init(x: 100, y: 40),
            planeCrtc: .init(x: 96, y: 39),
            crop: .init(x: 0, y: 1),
            width: 23, height: 31)
        XCTAssertEqual(hot, .init(x: 4, y: 0))
    }

    func testResizeCornerHotspotIsNotTopLeft() {
        // se-resize: tip near content bottom-right. Plane lags? No — settled.
        // pointer (500, 500), crop (3, 3), content 26×26, hotspot (11, 11).
        let hot = CursorHotspot.derive(
            pointer: .init(x: 500, y: 500),
            planeCrtc: .init(x: 486, y: 486),
            crop: .init(x: 3, y: 3),
            width: 26, height: 26)
        XCTAssertEqual(hot, .init(x: 11, y: 11))
    }

    func testMissingPlaneFallsBackToContentTip() {
        // The pre-ATOMIC CRTC_X/Y absence: do NOT treat plane as (0,0) and
        // slam into the bottom-right clamp when the pointer is far away.
        let hot = CursorHotspot.derive(
            pointer: .init(x: 1046, y: 201),
            planeCrtc: nil,
            crop: .init(x: 6, y: 1),
            width: 16, height: 29)
        XCTAssertEqual(hot, .init(x: 0, y: 0))
        XCTAssertFalse(CursorHotspot.canRecheck(planeCrtc: nil))
    }

    func testRealOriginPlaneIsNotTreatedAsLie() {
        // Cursor overhanging the top-left: plane genuinely at (0, 0).
        let hot = CursorHotspot.derive(
            pointer: .init(x: 4, y: 1),
            planeCrtc: .init(x: 0, y: 0),
            crop: .init(x: 0, y: 1),
            width: 23, height: 31)
        XCTAssertEqual(hot, .init(x: 4, y: 0))
        XCTAssertTrue(CursorHotspot.canRecheck(planeCrtc: .init(x: 0, y: 0)))
    }

    func testClampsMidMotionOvershoot() {
        // Pointer raced ahead of the plane by more than the image.
        let hot = CursorHotspot.derive(
            pointer: .init(x: 200, y: 200),
            planeCrtc: .init(x: 100, y: 100),
            crop: .init(x: 0, y: 0),
            width: 26, height: 26)
        XCTAssertEqual(hot, .init(x: 25, y: 25))
    }

    func testMissingPointerFallsBackToTip() {
        let hot = CursorHotspot.derive(
            pointer: nil,
            planeCrtc: .init(x: 50, y: 50),
            crop: .init(x: 0, y: 0),
            width: 10, height: 10)
        XCTAssertEqual(hot, .init(x: 0, y: 0))
    }
}
