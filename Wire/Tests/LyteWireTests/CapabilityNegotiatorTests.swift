import XCTest
import LyteWire
import LyteWireTestKit

// The sans-IO negotiation machine: both ends of the exchange driven
// against each other (declarations cross, intersections settle
// identically), the no-common-ground failures, the v1 renegotiation
// round in both verdicts, and every role/state protocol violation.

final class CapabilityNegotiatorTests: XCTestCase {

    private static let hostSet = Capabilities(
        wireMinor: 1,
        videoCodecs: [CapabilityCodec.hevc, 2],
        chromaModes: [CapabilityChroma.yuv420, CapabilityChroma.yuv444],
        idleSilence: true,
        featureChannels: [CapabilityFeature.clipboard],
        audioExpress: false,
        resume: true,
        maxDatagramBytes: 1500
    )

    private static let clientSet = Capabilities(
        wireMinor: 0,
        videoCodecs: [CapabilityCodec.hevc],
        chromaModes: [CapabilityChroma.yuv420],
        idleSilence: true,
        featureChannels: [
            CapabilityFeature.clipboard, CapabilityFeature.fileTransfer,
        ],
        audioExpress: true,
        resume: false,
        maxDatagramBytes: 1400
    )

    /// Cross-feeds the declarations and returns both settled machines.
    private func establish() throws
        -> (host: CapabilityNegotiator, client: CapabilityNegotiator) {
        var host = CapabilityNegotiator(role: .host, local: Self.hostSet)
        var client = CapabilityNegotiator(
            role: .client, local: Self.clientSet
        )
        let hostDeclaration = host.start()
        let clientDeclaration = client.start()
        let hostView = try host.receive(clientDeclaration)
        let clientView = try client.receive(hostDeclaration)
        XCTAssertEqual(hostView, clientView)
        return (host, client)
    }

    // MARK: - Declaration exchange

    func testBothEndsSettleOnTheSameAgreedSet() throws {
        let (host, client) = try establish()
        let agreed = try XCTUnwrap(host.agreed)
        XCTAssertEqual(client.agreed, agreed)
        XCTAssertEqual(agreed.wireMinor, 0)
        XCTAssertEqual(agreed.videoCodecs, [CapabilityCodec.hevc])
        XCTAssertEqual(agreed.chromaModes, [CapabilityChroma.yuv420])
        XCTAssertEqual(
            agreed.featureChannels, [CapabilityFeature.clipboard]
        )
        XCTAssertFalse(agreed.audioExpress)
        XCTAssertFalse(agreed.resume)
        XCTAssertEqual(agreed.maxDatagramBytes, 1400)
        // The operative geometry stays at the 1152 default no matter
        // how high the agreed ceiling sits.
        XCTAssertEqual(host.operativeMaxDatagramBytes, 1152)
        XCTAssertEqual(client.operativeMaxDatagramBytes, 1152)
    }

    func testPeerUnknownKeysVanishFromTheAgreedSet() throws {
        var peer = Self.clientSet
        peer.unknownEntries = [
            CborMapEntry(key: .unsigned(200), value: .bool(true))
        ]
        var host = CapabilityNegotiator(role: .host, local: Self.hostSet)
        _ = host.start()
        let event = try host.receive(
            CapabilityDeclaration(capabilities: peer)
        )
        guard case .agreed(let agreed) = event else {
            return XCTFail("expected agreed, got \(event)")
        }
        XCTAssertTrue(agreed.unknownEntries.isEmpty)
    }

    func testNoCommonVideoCodecFails() {
        var host = CapabilityNegotiator(role: .host, local: Self.hostSet)
        _ = host.start()
        var alien = Self.clientSet
        alien.videoCodecs = [77]
        XCTAssertThrowsError(
            try host.receive(CapabilityDeclaration(capabilities: alien))
        ) { error in
            XCTAssertEqual(
                error as? CapabilityNegotiationError, .noCommonVideoCodec
            )
        }
    }

    func testNoCommonChromaModeFails() {
        var host = CapabilityNegotiator(role: .host, local: Self.hostSet)
        _ = host.start()
        var alien = Self.clientSet
        alien.chromaModes = [9]
        XCTAssertThrowsError(
            try host.receive(CapabilityDeclaration(capabilities: alien))
        ) { error in
            XCTAssertEqual(
                error as? CapabilityNegotiationError, .noCommonChromaMode
            )
        }
    }

    func testSecondDeclarationIsAProtocolViolation() throws {
        var (host, _) = try establish()
        XCTAssertThrowsError(
            try host.receive(
                CapabilityDeclaration(capabilities: Self.clientSet)
            )
        ) { error in
            XCTAssertEqual(
                error as? CapabilityNegotiationError, .duplicateDeclaration
            )
        }
    }

    // MARK: - Renegotiation, both verdicts

    func testGeometryRaiseAcceptedEndToEnd() throws {
        var (host, client) = try establish()
        let update = try host.proposeMaxDatagramBytes(1400)
        let clientEvent = try client.receive(update)
        guard case .answerUpdate(let ack) = clientEvent else {
            return XCTFail("expected answerUpdate, got \(clientEvent)")
        }
        XCTAssertEqual(ack.status, .accepted)
        XCTAssertEqual(ack.parameters, update.parameters)
        XCTAssertEqual(client.operativeMaxDatagramBytes, 1400)
        let hostEvent = try host.receive(ack)
        XCTAssertEqual(hostEvent, .updateAccepted(update.parameters))
        XCTAssertEqual(host.operativeMaxDatagramBytes, 1400)
        // The lane is free again for the next probe result.
        XCTAssertNoThrow(try host.proposeMaxDatagramBytes(1152))
    }

    func testOverCeilingPeerProposalDrawsRejectionNotTeardown() throws {
        var (host, client) = try establish()
        _ = host // agreed ceiling is 1400
        let overreach = CapabilityUpdate(parameters: [
            CapabilityParameter(
                key: CapabilityKey.maxDatagramBytes, value: .unsigned(1500)
            )
        ])
        let event = try client.receive(overreach)
        guard case .answerUpdate(let ack) = event else {
            return XCTFail("expected answerUpdate, got \(event)")
        }
        XCTAssertEqual(ack.status, .rejected)
        XCTAssertEqual(client.operativeMaxDatagramBytes, 1152)
    }

    func testFixedKeyProposalDrawsRejection() throws {
        var (_, client) = try establish()
        let fixed = CapabilityUpdate(parameters: [
            CapabilityParameter(
                key: CapabilityKey.chromaModes,
                value: .array([.unsigned(2)])
            )
        ])
        let event = try client.receive(fixed)
        guard case .answerUpdate(let ack) = event else {
            return XCTFail("expected answerUpdate, got \(event)")
        }
        XCTAssertEqual(ack.status, .rejected)
    }

    func testRejectedAckLeavesTheProposerUnmoved() throws {
        var (host, _) = try establish()
        let update = try host.proposeMaxDatagramBytes(1400)
        let event = try host.receive(CapabilityUpdateAck(
            status: .rejected, parameters: update.parameters
        ))
        XCTAssertEqual(event, .updateRejected(update.parameters))
        XCTAssertEqual(host.operativeMaxDatagramBytes, 1152)
        XCTAssertNoThrow(try host.proposeMaxDatagramBytes(1300))
    }

    // MARK: - Protocol violations

    func testRoleViolations() throws {
        var (host, client) = try establish()
        XCTAssertThrowsError(
            try client.proposeMaxDatagramBytes(1300)
        ) { error in
            XCTAssertEqual(
                error as? CapabilityNegotiationError, .wrongRoleForUpdate
            )
        }
        let update = CapabilityUpdate(parameters: [
            CapabilityParameter(
                key: CapabilityKey.maxDatagramBytes, value: .unsigned(1300)
            )
        ])
        XCTAssertThrowsError(try host.receive(update)) { error in
            XCTAssertEqual(
                error as? CapabilityNegotiationError, .wrongRoleForUpdate
            )
        }
    }

    func testUpdateMachineryRequiresEstablishment() {
        var host = CapabilityNegotiator(role: .host, local: Self.hostSet)
        XCTAssertThrowsError(
            try host.proposeMaxDatagramBytes(1300)
        ) { error in
            XCTAssertEqual(
                error as? CapabilityNegotiationError, .notEstablished
            )
        }
        var client = CapabilityNegotiator(
            role: .client, local: Self.clientSet
        )
        let update = CapabilityUpdate(parameters: [
            CapabilityParameter(
                key: CapabilityKey.maxDatagramBytes, value: .unsigned(1300)
            )
        ])
        XCTAssertThrowsError(try client.receive(update)) { error in
            XCTAssertEqual(
                error as? CapabilityNegotiationError, .notEstablished
            )
        }
    }

    func testAckDiscipline() throws {
        var (host, _) = try establish()
        let stray = CapabilityUpdateAck(
            status: .accepted,
            parameters: [CapabilityParameter(
                key: CapabilityKey.maxDatagramBytes, value: .unsigned(1300)
            )]
        )
        XCTAssertThrowsError(try host.receive(stray)) { error in
            XCTAssertEqual(
                error as? CapabilityNegotiationError, .unexpectedAck
            )
        }
        let update = try host.proposeMaxDatagramBytes(1400)
        XCTAssertThrowsError(
            try host.proposeMaxDatagramBytes(1400)
        ) { error in
            XCTAssertEqual(
                error as? CapabilityNegotiationError,
                .proposalAlreadyOutstanding
            )
        }
        // An ack echoing different bytes than the outstanding
        // proposal is a violation, not a verdict.
        XCTAssertThrowsError(
            try host.receive(CapabilityUpdateAck(
                status: .accepted,
                parameters: [CapabilityParameter(
                    key: CapabilityKey.maxDatagramBytes,
                    value: .unsigned(1300)
                )]
            ))
        ) { error in
            XCTAssertEqual(
                error as? CapabilityNegotiationError, .ackParameterMismatch
            )
        }
        // The mismatch left the proposal outstanding; the honest ack
        // still lands.
        let event = try host.receive(CapabilityUpdateAck(
            status: .accepted, parameters: update.parameters
        ))
        XCTAssertEqual(event, .updateAccepted(update.parameters))
    }

    func testLocalProposalBoundsAreCaughtBeforeTheWire() throws {
        var (host, _) = try establish()
        for bad: UInt32 in [1151, 1401] {
            XCTAssertThrowsError(
                try host.proposeMaxDatagramBytes(bad), "\(bad)"
            ) { error in
                XCTAssertEqual(
                    error as? CapabilityNegotiationError,
                    .invalidLocalProposal, "\(bad)"
                )
            }
        }
    }

    // MARK: - Codec round trip through the machine

    func testExchangeSurvivesTheWireBytes() throws {
        // The same exchange with every message pushed through its
        // codec — what the ARQ stream actually delivers.
        var host = CapabilityNegotiator(role: .host, local: Self.hostSet)
        var client = CapabilityNegotiator(
            role: .client, local: Self.clientSet
        )
        let hostBytes = try host.start().encode()
        let clientBytes = try client.start().encode()
        _ = try host.receive(CapabilityDeclaration.decode(clientBytes))
        _ = try client.receive(CapabilityDeclaration.decode(hostBytes))
        let updateBytes = try host.proposeMaxDatagramBytes(1399).encode()
        let answer = try client.receive(
            CapabilityUpdate.decode(updateBytes)
        )
        guard case .answerUpdate(let ack) = answer else {
            return XCTFail("expected answerUpdate, got \(answer)")
        }
        let ackBytes = try ack.encode()
        _ = try host.receive(CapabilityUpdateAck.decode(ackBytes))
        XCTAssertEqual(host.operativeMaxDatagramBytes, 1399)
        XCTAssertEqual(client.operativeMaxDatagramBytes, 1399)
        XCTAssertEqual(host.agreed, client.agreed)
    }
}
