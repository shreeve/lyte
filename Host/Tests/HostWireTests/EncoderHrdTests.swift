import HostWire
import XCTest

final class EncoderHrdTests: XCTestCase {
    /// B6: at the 50 Mbps ceiling the four-frame window (~417 KB) sat
    /// above the one-FEC-group ceiling (~223 KB worst case), so a busy IDR
    /// came out unprotectable, was dropped, and re-demanded — a run of
    /// dropped IDRs. The guard's VBV now bounds the encoder's buffer.
    func testTheProtectableCeilingBoundsTheBufferAtTheRateCeiling() {
        let guardBits = 223_000 * 8
        let window = 50_000_000 * 4 / 60
        XCTAssertGreaterThan(window, guardBits)
        XCTAssertEqual(
            EncoderHrd.bufferBits(
                capBitsPerSecond: 50_000_000, fps: 60, vbvBits: guardBits),
            guardBits)
    }

    func testASqueezedCapKeepsItsFourFrameWindow() {
        XCTAssertEqual(
            EncoderHrd.bufferBits(
                capBitsPerSecond: 6_000_000, fps: 60, vbvBits: 223_000 * 8),
            400_000)
    }

    func testNoVbvLeavesTheWindowAlone() {
        XCTAssertEqual(
            EncoderHrd.bufferBits(
                capBitsPerSecond: 50_000_000, fps: 60, vbvBits: nil),
            50_000_000 * 4 / 60)
    }
}
