import XCTest
import LyteWire

// The HS-32 repair-refusal codec (0x23) against hand-computed bytes —
// the anchor that keeps repair-refusal-v1.json honest (the codec never
// grades its own homework).

final class RepairRefusalCodecTests: XCTestCase {

    func testRegistryNumberIsPinned() {
        // The next free CTRL id after P-1's 0x22 — wire contract.
        XCTAssertEqual(CtrlMessageType.repairRefused, 0x23)
    }

    func testHandComputedAnchor() throws {
        // type 0x23 ‖ frame 258 = 0x00000102 LE ‖ reason 0x01.
        let refusal = RepairRefusal(
            frame: FrameNumber(rawValue: 258), reason: .staleBudget
        )
        let expected: [UInt8] = [0x23, 0x02, 0x01, 0x00, 0x00, 0x01]
        XCTAssertEqual(refusal.encode(), expected)
        XCTAssertEqual(try RepairRefusal.decode(expected), refusal)
    }

    func testWholeReasonSpaceRoundTrips() throws {
        for reason in RepairRefusalReason.allCases {
            let refusal = RepairRefusal(
                frame: FrameNumber(rawValue: 0xDEAD_BEEF), reason: reason
            )
            let bytes = refusal.encode()
            XCTAssertEqual(bytes.count, RepairRefusal.encodedByteCount)
            XCTAssertEqual(try RepairRefusal.decode(bytes), refusal)
        }
    }

    func testTruncationRejects() {
        let bytes: [UInt8] = [0x23, 0x02, 0x01, 0x00, 0x00]
        XCTAssertThrowsError(try RepairRefusal.decode(bytes)) { error in
            XCTAssertEqual(
                error as? RepairRefusalError, .truncatedMessage
            )
        }
    }

    func testTrailingBytesReject() {
        let bytes: [UInt8] = [0x23, 0x02, 0x01, 0x00, 0x00, 0x01, 0x00]
        XCTAssertThrowsError(try RepairRefusal.decode(bytes)) { error in
            XCTAssertEqual(error as? RepairRefusalError, .trailingBytes)
        }
    }

    func testForeignTypeRejectsWithWhatItFound() {
        let bytes: [UInt8] = [
            CtrlMessageType.idrRequest, 0x02, 0x01, 0x00, 0x00, 0x01,
        ]
        XCTAssertThrowsError(try RepairRefusal.decode(bytes)) { error in
            XCTAssertEqual(
                error as? RepairRefusalError,
                .unexpectedType(CtrlMessageType.idrRequest)
            )
        }
    }

    func testZeroReasonRejectsLoud() {
        // The zero-fill rule: 0x00 is never a valid reason.
        let bytes: [UInt8] = [0x23, 0x02, 0x01, 0x00, 0x00, 0x00]
        XCTAssertThrowsError(try RepairRefusal.decode(bytes)) { error in
            XCTAssertEqual(
                error as? RepairRefusalError, .unknownReason(0x00)
            )
        }
    }

    func testUnknownReasonRejects() {
        let bytes: [UInt8] = [0x23, 0x02, 0x01, 0x00, 0x00, 0x7F]
        XCTAssertThrowsError(try RepairRefusal.decode(bytes)) { error in
            XCTAssertEqual(
                error as? RepairRefusalError, .unknownReason(0x7F)
            )
        }
    }
}
