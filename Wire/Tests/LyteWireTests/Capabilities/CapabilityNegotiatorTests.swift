import XCTest
import LyteWire
import LyteWireTestKit

// The sans-IO negotiation machine: both ends of the exchange driven
// against each other (declarations cross, intersections settle
// identically), the no-common-ground failures, the client's answer to a
// renegotiation in both verdicts, and every role/state protocol violation.

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
        let hostDeclaration = try XCTUnwrap(host.start())
        let clientDeclaration = try XCTUnwrap(client.start())
        let hostView = try host.receive(clientDeclaration)
        let clientView = try client.receive(hostDeclaration)
        XCTAssertEqual(hostView, clientView)
        return (host, client)
    }

    // MARK: - Declaration exchange

    func testStartReturnsTheExactDeclarationOnce() throws {
        var host = CapabilityNegotiator(role: .host, local: Self.hostSet)

        XCTAssertEqual(
            try XCTUnwrap(host.start()),
            CapabilityDeclaration(capabilities: Self.hostSet)
        )
        XCTAssertNil(host.start())
    }

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

    private static func raise(to value: UInt64) -> CapabilityUpdate {
        CapabilityUpdate(parameters: [
            CapabilityParameter(
                key: CapabilityKey.maxDatagramBytes, value: .unsigned(value)
            )
        ])
    }

    func testGeometryRaiseAccepted() throws {
        var (_, client) = try establish()
        let update = Self.raise(to: 1400)
        let clientEvent = try client.receive(update)
        guard case .answerUpdate(let ack) = clientEvent else {
            return XCTFail("expected answerUpdate, got \(clientEvent)")
        }
        XCTAssertEqual(ack.status, .accepted)
        XCTAssertEqual(ack.parameters, update.parameters)
        XCTAssertEqual(client.operativeMaxDatagramBytes, 1400)
    }

    func testOutOfBoundsPeerProposalDrawsRejectionNotTeardown() throws {
        var (_, client) = try establish()
        // The agreed ceiling is 1400; the floor is 1152.
        for value: UInt64 in [1151, 1401, 1500] {
            let event = try client.receive(Self.raise(to: value))
            guard case .answerUpdate(let ack) = event else {
                return XCTFail("expected answerUpdate, got \(event)")
            }
            XCTAssertEqual(ack.status, .rejected, "\(value)")
            XCTAssertEqual(client.operativeMaxDatagramBytes, 1152)
        }
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

    // MARK: - Protocol violations

    func testUpdateAtTheHostIsARoleViolation() throws {
        var (host, _) = try establish()
        XCTAssertThrowsError(try host.receive(Self.raise(to: 1300))) { error in
            XCTAssertEqual(
                error as? CapabilityNegotiationError, .wrongRoleForUpdate
            )
        }
    }

    func testUpdateRequiresEstablishment() {
        var client = CapabilityNegotiator(
            role: .client, local: Self.clientSet
        )
        XCTAssertThrowsError(try client.receive(Self.raise(to: 1300))) { error in
            XCTAssertEqual(
                error as? CapabilityNegotiationError, .notEstablished
            )
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
        let hostBytes = try XCTUnwrap(host.start()).encode()
        let clientBytes = try XCTUnwrap(client.start()).encode()
        _ = try host.receive(CapabilityDeclaration.decode(clientBytes))
        _ = try client.receive(CapabilityDeclaration.decode(hostBytes))
        let updateBytes = try Self.raise(to: 1399).encode()
        let answer = try client.receive(
            CapabilityUpdate.decode(updateBytes)
        )
        guard case .answerUpdate(let ack) = answer else {
            return XCTFail("expected answerUpdate, got \(answer)")
        }
        XCTAssertEqual(
            try CapabilityUpdateAck.decode(ack.encode()).status, .accepted
        )
        XCTAssertEqual(client.operativeMaxDatagramBytes, 1399)
        XCTAssertEqual(host.agreed, client.agreed)
    }
}
