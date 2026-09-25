import XCTest
import LyteWire

// The cursor-shape anchor: hand-computed bytes for 0x24 (the vector file
// never grades its own homework), the encode-side refusal, and the
// registry numbers. Round trips, ceilings and decode rejects live in
// cursor-v1.json.

final class CursorCodecTests: XCTestCase {

    func testCursorShapePinsBytes() throws {
        // 1×1, hotspot (0,0), one opaque blue BGRA pixel. Header by
        // hand: 24 ‖ 01 00 ‖ 01 00 ‖ 00 00 ‖ 00 00 (LE u16s).
        let blue = CursorShape(
            width: 1, height: 1, hotspotX: 0, hotspotY: 0,
            pixels: [0xFF, 0x00, 0x00, 0xFF]
        )
        XCTAssertEqual(
            try blue.encode(),
            [0x24, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
             0xFF, 0x00, 0x00, 0xFF]
        )
        XCTAssertEqual(
            try CursorShape.decode(try blue.encode()), blue
        )
        // Empty is a state: the hidden shape decodes as hidden.
        XCTAssertTrue(try CursorShape.decode(CursorShape.hidden.encode()).isHidden)
    }

    /// The hotspot must lie strictly inside the image; the encoder
    /// refuses an edge hotspot rather than ship it.
    func testEncodeRefusesHotspotOutsideImage() {
        assertThrows(CursorMessageError.hotspotOutsideImage(x: 2, y: 0)) {
            try CursorShape(
                width: 2, height: 2, hotspotX: 2, hotspotY: 0,
                pixels: [UInt8](repeating: 0, count: 16)
            ).encode()
        }
    }

    func testRegistryNumbersArePinned() {
        XCTAssertEqual(CtrlMessageType.cursorShape, 0x24)
        XCTAssertEqual(CursorWire.maxSide, 256)
        XCTAssertEqual(CursorWire.maxImageByteCount, 65_536)
        XCTAssertEqual(CursorWire.headerByteCount, 9)
    }
}
