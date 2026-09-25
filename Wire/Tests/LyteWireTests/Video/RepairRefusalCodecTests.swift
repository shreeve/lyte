import XCTest
import LyteWire

// The repair-refusal codec (0x23) against hand-computed bytes — the
// anchor that keeps repair-refusal-v1.json honest. The reason space and
// the decode rejects live in that vector file.

final class RepairRefusalCodecTests: XCTestCase {

    func testHandComputedAnchor() throws {
        // type 0x23 ‖ frame 258 = 0x00000102 LE ‖ reason 0x01.
        let refusal = RepairRefusal(
            frame: FrameNumber(rawValue: 258), reason: .staleBudget
        )
        let expected: [UInt8] = [0x23, 0x02, 0x01, 0x00, 0x00, 0x01]
        XCTAssertEqual(refusal.encode(), expected)
        XCTAssertEqual(try RepairRefusal.decode(expected), refusal)
    }
}
