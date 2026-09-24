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

    /// The ack carries a status byte the update lacks, so an update that
    /// fills the 1024 B ceiling cannot be echoed. That is a malformed
    /// update from this end's view, never an error escaping the session.
    func testUpdateTooLargeToEchoIsMalformedNotThrown() throws {
        var session = ClientCapabilitySession(local: local)
        _ = try session.receive(try CapabilityDeclaration(
            capabilities: local).encode())
        var filler = 1_000
        var update: [UInt8] = []
        while update.count < CapabilityDeclaration.maxEncodedByteCount {
            update = try CapabilityUpdate(parameters: [CapabilityParameter(
                key: 23, value: .text(String(repeating: "x", count: filler))
            )]).encode()
            filler += 1
        }
        XCTAssertEqual(update.count, CapabilityDeclaration.maxEncodedByteCount)

        let decision = try XCTUnwrap(session.receive(update))
        XCTAssertEqual(decision.event, .malformed(.update))
        XCTAssertTrue(decision.outboundReliable.isEmpty)
    }

    func testUnrelatedReliableWordIsNotClaimed() throws {
        var session = ClientCapabilitySession(local: local)
        XCTAssertNil(try session.receive(
            [CtrlMessageType.modeTransition, 0]))
    }
}
