import XCTest
@testable import LyteTransport

final class SyntheticMotionReferenceTests: XCTestCase {
    func testMarkerSelectsExactReferenceFrame() {
        let source = SyntheticMotionReference(width: 640, height: 360)
        let frame = source.frame(0x00A5_5A3C)
        XCTAssertEqual(source.marker(in: frame), 0x00A5_5A3C)
        XCTAssertNotEqual(frame, source.frame(0x00A5_5A3D))
    }

    func testBlurredOrMissingSentinelsCannotSelectAPhase() {
        let source = SyntheticMotionReference(width: 640, height: 360)
        var frame = source.frame(7)
        for y in 0..<24 {
            for x in 0..<24 {
                let offset = (y * 640 + x) * 4
                frame[offset] = 0
                frame[offset + 1] = 0
                frame[offset + 2] = 0
            }
        }
        XCTAssertNil(source.marker(in: frame))
    }
}
