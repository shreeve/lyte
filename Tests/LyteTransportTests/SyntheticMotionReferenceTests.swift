import LyteCore
import XCTest
@testable import LyteTransport

final class SyntheticMotionReferenceTests: XCTestCase {
    func testMarkerSelectsExactReferenceFrame() {
        let source = SyntheticMotionReference(width: 1024, height: 640)
        let frame = source.frame(0x00A5_5A3C)
        XCTAssertEqual(source.marker(in: frame), 0x00A5_5A3C)
        XCTAssertNotEqual(frame, source.frame(0x00A5_5A3D))
    }

    func testBlurredOrMissingSentinelsCannotSelectAPhase() {
        let source = SyntheticMotionReference(width: 1024, height: 640)
        var frame = source.frame(7)
        for y in 0..<24 {
            for x in 0..<24 {
                let offset = (y * 1024 + x) * 4
                frame[offset] = 0
                frame[offset + 1] = 0
                frame[offset + 2] = 0
            }
        }
        XCTAssertNil(source.marker(in: frame))
    }

    // The cross-language pin: these SHA-256 digests are computed from
    // MotionFrames in Scripts/motion-presenter.py (the numpy twin of the
    // GTK canvas) and asserted verbatim by
    // Scripts/test_analyze_app_benchmark.py. If either renderer drifts
    // from the authored frame, exactly one side of the pin moves and
    // both suites fail.
    func testTwinRenderersAgreeByteForByte() {
        let source = SyntheticMotionReference(width: 1024, height: 640)
        let pins: [(frameID: UInt32, sha256: String)] = [
            (0, "fec91c8942b63df2264470cd0db2ccc0e485454170edc36ccb9e90b3a43ca2b4"),
            (257, "9183977edb22c8f8e21554388376ac82fc170da15a1ebb98579b08c9a13c68ff"),
            (900, "00c770aac5dcfc5d5489c0ee62e32bd8b541105e4b2fca41d9ba8ea463c1c43f"),
        ]
        for pin in pins {
            let digest = Sha256.digest(source.frame(pin.frameID))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hex, pin.sha256,
                           "frame \(pin.frameID) drifted from the glass")
        }
    }
}
