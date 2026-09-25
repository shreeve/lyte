import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// The capability message codecs (0x0F / 0x11 / 0x12), anchored by
// hand-built bytes — the anchors that break the vector file's
// circularity — plus the encode-side refusals and the decode rejects
// capabilities-v1.json does not carry.

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

    func testDeclarationEncodeRefusesOverBudget() {
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

    func testUpdateEncodeRefusesEmptyProposal() {
        assertThrows(CapabilityMessageError.emptyUpdate) {
            try CapabilityUpdate(parameters: []).encode()
        }
    }

    // MARK: - Update ack (0x12)

    func testUpdateAckHandComputedAnchor() throws {
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
    }

    /// The ack frames its own type and status, so its rejects are its
    /// own, not the shared declaration/update frame check's.
    func testUpdateAckRejects() {
        assertThrows(CapabilityMessageError.emptyUpdate) {
            try CapabilityUpdateAck.decode(hex("1201a0"))
        }
        assertThrows(CapabilityMessageError.unexpectedType(0x11)) {
            try CapabilityUpdateAck.decode(hex("1101" + raiseMapHex))
        }
    }
}
