import XCTest
import LyteWire

// The E3 cursor-shape vocabulary's anchors (direct-eye plan §5,
// docs/20260801-105800-direct-eye-plan.md): hand-computed bytes for 0x24
// (the vector file never grades its own homework), the key-13
// capability spine, the registry numbers, and the validation laws —
// including the one clipboard doesn't have: EMPTY IS A STATE.

final class CursorCodecTests: XCTestCase {

    // MARK: The codec, pinned against hand-computed bytes

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
        // The hidden state: nine bytes, all field bytes zero.
        XCTAssertEqual(
            try CursorShape.hidden.encode(),
            [0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        )
        let hidden = try CursorShape.decode(
            [0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        )
        XCTAssertTrue(hidden.isHidden)
        XCTAssertEqual(hidden, .hidden)
        // LE field placement: width 256 = 00 01 (the only legal
        // two-byte side), height 3 = 03 00, hotspot (255, 2).
        let wide = CursorShape(
            width: 256, height: 3, hotspotX: 255, hotspotY: 2,
            pixels: [UInt8](repeating: 0xAB, count: 256 * 3 * 4)
        )
        XCTAssertEqual(
            Array(try wide.encode().prefix(9)),
            [0x24, 0x00, 0x01, 0x03, 0x00, 0xFF, 0x00, 0x02, 0x00]
        )
        XCTAssertEqual(try CursorShape.decode(try wide.encode()), wide)
    }

    func testCeilingAndCapsAreLegalToTheUnit() throws {
        // The exact image ceiling: 128×128 = 65,536 B.
        let square = CursorShape(
            width: 128, height: 128, hotspotX: 127, hotspotY: 127,
            pixels: [UInt8](
                repeating: 0x7F, count: CursorWire.maxImageByteCount
            )
        )
        let encoded = try square.encode()
        XCTAssertEqual(
            encoded.count,
            CursorWire.headerByteCount + CursorWire.maxImageByteCount
        )
        XCTAssertEqual(try CursorShape.decode(encoded), square)
        // The exact side cap: 256×1.
        let beam = CursorShape(
            width: 256, height: 1, hotspotX: 255, hotspotY: 0,
            pixels: [UInt8](repeating: 0x01, count: 256 * 4)
        )
        XCTAssertEqual(
            try CursorShape.decode(try beam.encode()), beam
        )
    }

    func testHostileCursorBytesRejectAndNeverTrap() {
        // Truncation: empty, and a half header.
        XCTAssertThrowsError(try CursorShape.decode([])) {
            XCTAssertEqual($0 as? CursorMessageError, .truncatedMessage)
        }
        XCTAssertThrowsError(try CursorShape.decode(
            [0x24, 0x01, 0x00, 0x01, 0x00]
        )) {
            XCTAssertEqual($0 as? CursorMessageError, .truncatedMessage)
        }
        // Foreign type.
        XCTAssertThrowsError(try CursorShape.decode(
            [0x23, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        )) {
            XCTAssertEqual(
                $0 as? CursorMessageError, .unexpectedType(0x23)
            )
        }
        // A lone zero side, and a side past the cap (257 = 01 01).
        XCTAssertThrowsError(try CursorShape.decode(
            [0x24, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00]
        )) {
            XCTAssertEqual(
                $0 as? CursorMessageError,
                .invalidDimensions(width: 0, height: 2)
            )
        }
        XCTAssertThrowsError(try CursorShape.decode(
            [0x24, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]
        )) {
            XCTAssertEqual(
                $0 as? CursorMessageError,
                .invalidDimensions(width: 257, height: 1)
            )
        }
        // Over-budget area, judged before the pixel count so hostile
        // bytes never oblige a 262 KB allocation to reject.
        XCTAssertThrowsError(try CursorShape.decode(
            [0x24, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        )) {
            XCTAssertEqual(
                $0 as? CursorMessageError,
                .imageOverBudget(256 * 256 * 4)
            )
        }
        // Count mismatch, short and long.
        XCTAssertThrowsError(try CursorShape.decode(
            [0x24, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
             0xFF, 0x00, 0x00]
        )) {
            XCTAssertEqual(
                $0 as? CursorMessageError,
                .pixelCountMismatch(expected: 4, found: 3)
            )
        }
        XCTAssertThrowsError(try CursorShape.decode(
            [0x24, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
             0xFF, 0x00, 0x00, 0xFF, 0x00]
        )) {
            XCTAssertEqual(
                $0 as? CursorMessageError,
                .pixelCountMismatch(expected: 4, found: 5)
            )
        }
        // Hotspot at the edge (strictly-inside rule), and a hidden
        // shape claiming one.
        XCTAssertThrowsError(try CursorShape(
            width: 2, height: 2, hotspotX: 2, hotspotY: 0,
            pixels: [UInt8](repeating: 0, count: 16)
        ).encode()) {
            XCTAssertEqual(
                $0 as? CursorMessageError,
                .hotspotOutsideImage(x: 2, y: 0)
            )
        }
        XCTAssertThrowsError(try CursorShape.decode(
            [0x24, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]
        )) {
            XCTAssertEqual(
                $0 as? CursorMessageError,
                .hotspotOutsideImage(x: 1, y: 0)
            )
        }
    }

    // MARK: Key 13 on the forward-compat spine, zero frozen bytes

    func testKey13RidesTheSpine() throws {
        let base = Capabilities.wireDefault
        XCTAssertFalse(base.cursorShape)
        let declared = base.declaringCursorShape()
        XCTAssertTrue(declared.cursorShape)
        // Idempotent.
        XCTAssertEqual(
            try declared.declaringCursorShape().encodeCbor(),
            try declared.encodeCbor()
        )
        // No frozen bytes moved: the declared encoding is the base
        // encoding with the map head bumped and `0D F5` appended.
        let baseBytes = try base.encodeCbor()
        let declaredBytes = try declared.encodeCbor()
        XCTAssertEqual(declaredBytes.first, baseBytes.first.map { $0 + 1 })
        XCTAssertEqual(
            Array(declaredBytes.dropFirst()),
            Array(baseBytes.dropFirst()) + [0x0D, 0xF5]
        )
        // Roundtrip through decode preserves the key.
        let redecoded = try Capabilities.decodeCbor(declaredBytes)
        XCTAssertTrue(redecoded.cursorShape)
        XCTAssertEqual(try redecoded.encodeCbor(), declaredBytes)
        // Survives intersection only on mutual declaration.
        XCTAssertTrue(declared.intersecting(declared).cursorShape)
        XCTAssertFalse(declared.intersecting(base).cursorShape)
        XCTAssertFalse(base.intersecting(declared).cursorShape)
    }

    // MARK: The registry numbers

    func testRegistryNumbersArePinned() {
        XCTAssertEqual(CtrlMessageType.cursorShape, 0x24)
        XCTAssertEqual(CapabilityKey.cursorShape, 13)
        XCTAssertEqual(CursorWire.maxSide, 256)
        XCTAssertEqual(CursorWire.maxImageByteCount, 65_536)
        XCTAssertEqual(CursorWire.headerByteCount, 9)
    }
}
