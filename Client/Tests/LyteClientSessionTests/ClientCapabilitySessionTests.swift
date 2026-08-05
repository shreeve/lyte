import XCTest
import LyteClientSession
import LyteWire

final class ClientCapabilitySessionTests: XCTestCase {
    private var local: Capabilities {
        var capabilities = Capabilities.wireDefault
        capabilities.maxDatagramBytes = 1_400
        return capabilities
    }

    func testDeclarationIsTheOneStartupWord() throws {
        var session = ClientCapabilitySession(local: local)
        let first = try XCTUnwrap(session.start())
        XCTAssertEqual(
            try CapabilityDeclaration.decode(first).capabilities,
            local)
        XCTAssertNil(try session.start())
    }

    func testDeclarationSettlesTheIntersection() throws {
        var remote = local
        remote.maxDatagramBytes = 1_300
        var session = ClientCapabilitySession(local: local)
        let bytes = try CapabilityDeclaration(
            capabilities: remote).encode()

        let decision = try XCTUnwrap(session.receive(bytes))
        let agreed = local.intersecting(remote)
        XCTAssertEqual(decision.event, .agreed(agreed))
        XCTAssertEqual(session.agreed, agreed)
        XCTAssertTrue(decision.outboundReliable.isEmpty)
        XCTAssertNil(decision.teardownReason)
    }

    func testUnworkableDeclarationRecommendsTypedTeardown() throws {
        var remote = local
        remote.videoCodecs = []
        var session = ClientCapabilitySession(local: local)
        let decision = try XCTUnwrap(session.receive(
            try CapabilityDeclaration(capabilities: remote).encode()))

        XCTAssertEqual(
            decision.event, .failed(.noCommonVideoCodec))
        XCTAssertEqual(decision.teardownReason, .shuttingDown)
        XCTAssertNil(session.agreed)
    }

    func testMalformedAndDuplicateDeclarationsAreDistinct() throws {
        var session = ClientCapabilitySession(local: local)
        let malformed = try XCTUnwrap(session.receive(
            [CtrlMessageType.capabilityDeclaration]))
        XCTAssertEqual(malformed.event, .malformed(.declaration))

        let declaration = try CapabilityDeclaration(
            capabilities: local).encode()
        _ = try session.receive(declaration)
        let duplicate = try XCTUnwrap(session.receive(declaration))
        XCTAssertEqual(
            duplicate.event,
            .refused(.declaration, .duplicateDeclaration))
    }

    func testAcceptedUpdateReturnsExactAckAndMovesOperativeCeiling() throws {
        var session = ClientCapabilitySession(local: local)
        _ = try session.receive(try CapabilityDeclaration(
            capabilities: local).encode())
        let update = CapabilityUpdate(parameters: [CapabilityParameter(
            key: CapabilityKey.maxDatagramBytes,
            value: .unsigned(1_300)
        )])
        let decision = try XCTUnwrap(session.receive(try update.encode()))

        XCTAssertEqual(decision.event, .updateAnswered(accepted: true))
        XCTAssertEqual(session.operativeMaxDatagramBytes, 1_300)
        let ack = try CapabilityUpdateAck.decode(
            try XCTUnwrap(decision.outboundReliable.first))
        XCTAssertEqual(ack.status, .accepted)
        XCTAssertEqual(ack.parameters, update.parameters)
    }

    func testUpdateBeforeAgreementIsRefusedWithoutOutboundBytes() throws {
        var session = ClientCapabilitySession(local: local)
        let update = CapabilityUpdate(parameters: [CapabilityParameter(
            key: CapabilityKey.maxDatagramBytes,
            value: .unsigned(1_300)
        )])
        let decision = try XCTUnwrap(session.receive(try update.encode()))
        XCTAssertEqual(
            decision.event, .refused(.update, .notEstablished))
        XCTAssertTrue(decision.outboundReliable.isEmpty)
    }

    func testUnrelatedReliableWordIsNotClaimed() throws {
        var session = ClientCapabilitySession(local: local)
        XCTAssertNil(try session.receive(
            [CtrlMessageType.modeTransition, 0]))
    }
}
