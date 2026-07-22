import XCTest
import LyteWire
import LyteWireTestKit

// The pairing message codecs (CTRL 0x0B–0x0E), anchored by hand-built
// byte layouts — the anchor pairing-v1.json's messageVectors are checked
// against, so vectorgen never grades its own homework.

final class PairingCodecTests: XCTestCase {

    private static let share = (0..<32).map { UInt8(0xA0 + $0) }
    private static let tag = (0..<64).map { UInt8($0) }

    // MARK: Hand-computed anchors

    func testShareAHandComputedBytes() throws {
        let message = PairingShareA(share: Self.share)
        let encoded = try message.encode()
        XCTAssertEqual(encoded.count, PairingShareA.encodedByteCount)
        XCTAssertEqual(encoded, [0x0B] + Self.share)
        XCTAssertEqual(try PairingShareA.decode(encoded), message)
        XCTAssertEqual(
            CtrlMessageType.peek(encoded), CtrlMessageType.pairingShareA
        )
    }

    func testShareBHandComputedBytes() throws {
        let message = PairingShareB(
            share: Self.share, confirmationTag: Self.tag
        )
        let encoded = try message.encode()
        XCTAssertEqual(encoded.count, PairingShareB.encodedByteCount)
        XCTAssertEqual(encoded, [0x0C] + Self.share + Self.tag)
        XCTAssertEqual(try PairingShareB.decode(encoded), message)
    }

    func testConfirmHandComputedBytes() throws {
        let message = PairingConfirm(confirmationTag: Self.tag)
        let encoded = try message.encode()
        XCTAssertEqual(encoded.count, PairingConfirm.encodedByteCount)
        XCTAssertEqual(encoded, [0x0D] + Self.tag)
        XCTAssertEqual(try PairingConfirm.decode(encoded), message)
    }

    func testRejectHandComputedBytes() throws {
        XCTAssertEqual(
            PairingReject(reason: .confirmationFailed).encode(),
            [0x0E, 0x01]
        )
        XCTAssertEqual(
            PairingReject(reason: .invalidShare).encode(), [0x0E, 0x02]
        )
        XCTAssertEqual(
            try PairingReject.decode([0x0E, 0x01]).reason,
            .confirmationFailed
        )
    }

    // MARK: Encode guards

    func testEncodeRejectsMisSizedFields() {
        XCTAssertThrowsError(
            try PairingShareA(share: [1, 2, 3]).encode()
        ) { error in
            XCTAssertEqual(
                error as? PairingMessageError, .invalidShareLength(3)
            )
        }
        XCTAssertThrowsError(
            try PairingShareB(
                share: Self.share, confirmationTag: [0]
            ).encode()
        ) { error in
            XCTAssertEqual(
                error as? PairingMessageError, .invalidTagLength(1)
            )
        }
        XCTAssertThrowsError(
            try PairingConfirm(confirmationTag: []).encode()
        ) { error in
            XCTAssertEqual(
                error as? PairingMessageError, .invalidTagLength(0)
            )
        }
    }

    // MARK: Decode rejects — the fixed-frame discipline

    func testDecodeRejectsHostileBytes() {
        // Truncation.
        XCTAssertThrowsError(try PairingShareA.decode([0x0B])) {
            XCTAssertEqual(
                $0 as? PairingMessageError, .truncatedMessage
            )
        }
        XCTAssertThrowsError(
            try PairingShareB.decode([0x0C] + Self.share)
        ) {
            XCTAssertEqual($0 as? PairingMessageError, .truncatedMessage)
        }
        XCTAssertThrowsError(try PairingReject.decode([0x0E])) {
            XCTAssertEqual($0 as? PairingMessageError, .truncatedMessage)
        }
        // Trailing bytes.
        XCTAssertThrowsError(
            try PairingShareA.decode([0x0B] + Self.share + [0x00])
        ) {
            XCTAssertEqual($0 as? PairingMessageError, .trailingBytes)
        }
        XCTAssertThrowsError(
            try PairingConfirm.decode([0x0D] + Self.tag + [0x00])
        ) {
            XCTAssertEqual($0 as? PairingMessageError, .trailingBytes)
        }
        // Foreign type bytes.
        XCTAssertThrowsError(
            try PairingShareA.decode([0x0C] + Self.share)
        ) {
            XCTAssertEqual(
                $0 as? PairingMessageError, .unexpectedType(0x0C)
            )
        }
        XCTAssertThrowsError(
            try PairingConfirm.decode([0x0B] + Self.tag)
        ) {
            XCTAssertEqual(
                $0 as? PairingMessageError, .unexpectedType(0x0B)
            )
        }
        // Reject reasons: zero-fill and unassigned values.
        XCTAssertThrowsError(try PairingReject.decode([0x0E, 0x00])) {
            XCTAssertEqual($0 as? PairingMessageError, .unknownReason(0x00))
        }
        XCTAssertThrowsError(try PairingReject.decode([0x0E, 0x7F])) {
            XCTAssertEqual($0 as? PairingMessageError, .unknownReason(0x7F))
        }
    }
}
