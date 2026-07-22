import XCTest
import LyteWire
import LyteWireTestKit

// The W7 capability message codecs (0x0F / 0x11 / 0x12), anchored by
// hand-built bytes — the anchors that break the vector file's
// circularity, per the beacon/lifecycle doctrine.

final class CapabilityCodecTests: XCTestCase {

    private func hex(_ s: String) -> [UInt8] {
        Hex.bytes(s)!
    }

    /// {8: 1500} — the nominal geometry-raise proposal map.
    private let raiseMapHex = "a1081905dc"

    // MARK: - Declaration (0x0F)

    func testDeclarationHandComputedAnchor() throws {
        let expected = hex("0f" + CapabilitiesTests.wireDefaultHex)
        let message = CapabilityDeclaration(capabilities: .wireDefault)
        XCTAssertEqual(try message.encode(), expected)
        XCTAssertEqual(
            try CapabilityDeclaration.decode(expected), message
        )
    }

    func testDeclarationRejects() {
        XCTAssertThrowsError(
            try CapabilityDeclaration.decode(hex("0f"))
        ) { error in
            XCTAssertEqual(
                error as? CapabilityMessageError, .truncatedMessage
            )
        }
        XCTAssertThrowsError(
            try CapabilityDeclaration.decode(
                hex("10" + CapabilitiesTests.wireDefaultHex)
            )
        ) { error in
            XCTAssertEqual(
                error as? CapabilityMessageError, .unexpectedType(0x10)
            )
        }
        // A declaration past the 1024 B ceiling refuses BEFORE any
        // CBOR work — the anti-streaming stop.
        let fat = hex("0f") + Array(repeating: 0, count: 1024)
        XCTAssertThrowsError(
            try CapabilityDeclaration.decode(fat)
        ) { error in
            XCTAssertEqual(
                error as? CapabilityMessageError, .messageOverBudget(1025)
            )
        }
        // Encode enforces the same ceiling.
        var bloated = Capabilities.wireDefault
        bloated.unknownEntries = [CborMapEntry(
            key: .unsigned(100),
            value: .bytes(Array(repeating: 0xAA, count: 1100))
        )]
        XCTAssertThrowsError(
            try CapabilityDeclaration(capabilities: bloated).encode()
        ) { error in
            guard case .messageOverBudget = error as? CapabilityMessageError
            else {
                return XCTFail("expected messageOverBudget, got \(error)")
            }
        }
        // A malformed body wraps the capability error.
        XCTAssertThrowsError(
            try CapabilityDeclaration.decode(hex("0f810a"))
        ) { error in
            XCTAssertEqual(
                error as? CapabilityMessageError, .malformedBody(.notAMap)
            )
        }
    }

    // MARK: - Update (0x11)

    func testUpdateHandComputedAnchor() throws {
        let expected = hex("11" + raiseMapHex)
        let message = CapabilityUpdate(parameters: [
            CapabilityParameter(
                key: CapabilityKey.maxDatagramBytes,
                value: .unsigned(1500)
            )
        ])
        XCTAssertEqual(try message.encode(), expected)
        XCTAssertEqual(try CapabilityUpdate.decode(expected), message)
    }

    func testUpdateRejects() {
        XCTAssertThrowsError(
            try CapabilityUpdate.decode(hex("11"))
        ) { error in
            XCTAssertEqual(
                error as? CapabilityMessageError, .truncatedMessage
            )
        }
        // An empty proposal map is a no-op and rejects.
        XCTAssertThrowsError(
            try CapabilityUpdate.decode(hex("11a0"))
        ) { error in
            XCTAssertEqual(error as? CapabilityMessageError, .emptyUpdate)
        }
        XCTAssertThrowsError(
            try CapabilityUpdate(parameters: []).encode()
        ) { error in
            XCTAssertEqual(error as? CapabilityMessageError, .emptyUpdate)
        }
        // Parameter keys are registry numbers; a text key rejects.
        XCTAssertThrowsError(
            try CapabilityUpdate.decode(hex("11a1616100"))
        ) { error in
            XCTAssertEqual(
                error as? CapabilityMessageError, .nonIntegerParameterKey
            )
        }
        XCTAssertThrowsError(
            try CapabilityUpdate.decode(hex("0f" + raiseMapHex))
        ) { error in
            XCTAssertEqual(
                error as? CapabilityMessageError, .unexpectedType(0x0F)
            )
        }
    }

    // MARK: - Update ack (0x12)

    func testUpdateAckHandComputedAnchors() throws {
        let parameters = [CapabilityParameter(
            key: CapabilityKey.maxDatagramBytes, value: .unsigned(1500)
        )]
        let accepted = CapabilityUpdateAck(
            status: .accepted, parameters: parameters
        )
        XCTAssertEqual(try accepted.encode(), hex("1201" + raiseMapHex))
        XCTAssertEqual(
            try CapabilityUpdateAck.decode(hex("1201" + raiseMapHex)),
            accepted
        )
        let rejected = CapabilityUpdateAck(
            status: .rejected, parameters: parameters
        )
        XCTAssertEqual(try rejected.encode(), hex("1202" + raiseMapHex))
        XCTAssertEqual(
            try CapabilityUpdateAck.decode(hex("1202" + raiseMapHex)),
            rejected
        )
    }

    func testUpdateAckRejects() {
        XCTAssertThrowsError(
            try CapabilityUpdateAck.decode(hex("12"))
        ) { error in
            XCTAssertEqual(
                error as? CapabilityMessageError, .truncatedMessage
            )
        }
        XCTAssertThrowsError(
            try CapabilityUpdateAck.decode(hex("1203" + raiseMapHex))
        ) { error in
            XCTAssertEqual(
                error as? CapabilityMessageError, .unknownStatus(0x03)
            )
        }
        XCTAssertThrowsError(
            try CapabilityUpdateAck.decode(hex("1200" + raiseMapHex))
        ) { error in
            XCTAssertEqual(
                error as? CapabilityMessageError, .unknownStatus(0x00)
            )
        }
        XCTAssertThrowsError(
            try CapabilityUpdateAck.decode(hex("1201a0"))
        ) { error in
            XCTAssertEqual(error as? CapabilityMessageError, .emptyUpdate)
        }
        XCTAssertThrowsError(
            try CapabilityUpdateAck.decode(hex("1101" + raiseMapHex))
        ) { error in
            XCTAssertEqual(
                error as? CapabilityMessageError, .unexpectedType(0x11)
            )
        }
    }
}
