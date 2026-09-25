import XCTest
import LyteWire
import LyteWireTestKit

// The pairing message codecs (CTRL 0x0B–0x0E), anchored by hand-built
// byte layouts — the anchor pairing-v1.json's messageVectors are checked
// against, so vectorgen never grades its own homework — plus the encode
// guards. Decode rejects live in the vectors.

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
        assertThrows(PairingMessageError.invalidShareLength(3)) {
            try PairingShareA(share: [1, 2, 3]).encode()
        }
        assertThrows(PairingMessageError.invalidTagLength(1)) {
            try PairingShareB(
                share: Self.share, confirmationTag: [0]
            ).encode()
        }
        assertThrows(PairingMessageError.invalidTagLength(0)) {
            try PairingConfirm(confirmationTag: []).encode()
        }
    }
}
