import LyteClientSession
import LyteWire
import XCTest

final class ClientCursorSessionTests: XCTestCase {
    private let arrow = CursorShape(
        width: 2,
        height: 1,
        hotspotX: 1,
        hotspotY: 0,
        pixels: [
            0x00, 0x00, 0x00, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF,
        ])
    private var cursorCapabilities: Capabilities {
        .wireDefault.declaringCursorShape()
    }

    func testNegotiatedVisibleAndHiddenShapesSurfaceByteExact() throws {
        let session = ClientCursorSession()

        XCTAssertEqual(
            session.receiveReliable(
                try arrow.encode(), agreed: cursorCapabilities),
            .shape(arrow))
        XCTAssertEqual(
            session.receiveReliable(
                try CursorShape.hidden.encode(),
                agreed: cursorCapabilities),
            .shape(.hidden))
    }

    func testValidShapeRequiresNegotiatedCapability() throws {
        let session = ClientCursorSession()
        let bytes = try arrow.encode()

        XCTAssertEqual(
            session.receiveReliable(bytes, agreed: nil),
            .unnegotiatedShape)
        XCTAssertEqual(
            session.receiveReliable(bytes, agreed: .wireDefault),
            .unnegotiatedShape)
    }

    func testMalformedShapeIsClassifiedBeforeCapability() {
        let session = ClientCursorSession()
        let malformed: [UInt8] = [CtrlMessageType.cursorShape, 0x01]

        XCTAssertEqual(
            session.receiveReliable(malformed, agreed: nil),
            .malformedShape)
        XCTAssertEqual(
            session.receiveReliable(
                malformed, agreed: cursorCapabilities),
            .malformedShape)
    }

    func testUnrelatedReliableWordIsNotClaimed() {
        let session = ClientCursorSession()

        XCTAssertNil(session.receiveReliable(
            [CtrlMessageType.idleFrame], agreed: cursorCapabilities))
    }
}
