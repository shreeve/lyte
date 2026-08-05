import XCTest
import LyteClientSession
import LyteWire

final class ClientControlSessionTests: XCTestCase {
    private var local: Capabilities {
        var capabilities = Capabilities.wireDefault
        capabilities.maxDatagramBytes = 1_400
        return capabilities
    }

    func testStartupDeclarationComesFromTheComposedBoundaryOnce() throws {
        var session = makeSession()
        XCTAssertEqual(
            try CapabilityDeclaration.decode(try XCTUnwrap(session.start()))
                .capabilities,
            local
        )
        XCTAssertNil(try session.start())
    }

    func testLifecycleWordRoutesThroughTheComposedBoundary() throws {
        var session = makeSession()
        let result = try XCTUnwrap(session.receiveReliable(
            ModeTransition(mode: .idle).encode(),
            now: at(10)
        ))

        XCTAssertEqual(result.event, .lifecycle(.modeTransition))
        XCTAssertEqual(result.lifecycle?.state, .idle)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.wireMode, .idle)
    }

    func testCapabilityWordRoutesThroughTheComposedBoundary() throws {
        var remote = local
        remote.maxDatagramBytes = 1_300
        var session = makeSession()
        let result = try XCTUnwrap(session.receiveReliable(
            try CapabilityDeclaration(capabilities: remote).encode(),
            now: at(10)
        ))

        let agreed = local.intersecting(remote)
        XCTAssertEqual(result.event, .capability(.agreed(agreed)))
        XCTAssertEqual(session.agreedCapabilities, agreed)
        XCTAssertNil(result.lifecycle)
    }

    func testUnworkableCapabilitiesBecomeOneComposedTeardownDecision() throws {
        var remote = local
        remote.videoCodecs = []
        var session = makeSession()
        let result = try XCTUnwrap(session.receiveReliable(
            try CapabilityDeclaration(capabilities: remote).encode(),
            now: at(10)
        ))

        XCTAssertEqual(
            result.event,
            .capability(.failed(.noCommonVideoCodec))
        )
        XCTAssertEqual(result.lifecycle?.actions, [
            .sendTeardownMessage(.shuttingDown),
            .sessionClosed(.localTeardown(.shuttingDown)),
        ])
        XCTAssertEqual(session.state, .closed)
    }

    func testMalformedKindsStayTypedAcrossTheFacade() throws {
        var session = makeSession()
        XCTAssertEqual(
            try session.receiveReliable(
                [CtrlMessageType.modeTransition], now: at(10))?.event,
            .malformedLifecycle(.modeTransition)
        )
        XCTAssertEqual(
            try session.receiveReliable(
                [CtrlMessageType.capabilityDeclaration], now: at(11))?.event,
            .capability(.malformed(.declaration))
        )
    }

    func testAudioRoutingRequestAndStatusShareTheComposedBoundary() throws {
        let routing = local.declaringHostAudioRouting()
        var session = makeSession(
            localCapabilities: routing,
            desiredHostAudioRouting: .hostMuted)
        _ = try session.receiveReliable(
            try CapabilityDeclaration(capabilities: routing).encode(),
            now: at(10))

        XCTAssertEqual(
            try session.requestHostAudioRouting(.hostAudible),
            [0x18, 0x01]
        )
        XCTAssertEqual(
            try session.receiveReliable(
                AudioRoutingStatus(mode: .hostAudible).encode(),
                now: at(11)),
            ClientControlSessionDecision(
                outboundReliable: [[0x18, 0x02]],
                event: .audioRouting(.status(
                    .hostAudible,
                    startup: .requested(.hostMuted))))
        )
        XCTAssertEqual(session.hostAudioRoutingPosture, .hostAudible)
        XCTAssertTrue(session.hostAudioRoutingNegotiated)
    }

    func testUnrelatedReliableWordIsNotClaimed() throws {
        var session = makeSession()
        XCTAssertNil(try session.receiveReliable(
            [CtrlMessageType.idleFrame], now: at(10)))
    }

    private func makeSession(
        localCapabilities: Capabilities? = nil,
        desiredHostAudioRouting: HostAudioRoutingMode? = nil
    ) -> ClientControlSession {
        ClientControlSession(
            localCapabilities: localCapabilities ?? local,
            machineConfig: SessionMachineConfig(),
            desiredHostAudioRouting: desiredHostAudioRouting,
            now: at(0)
        )
    }

    private func at(_ microseconds: UInt64) -> ClientTimestamp {
        ClientTimestamp(microseconds: microseconds)
    }
}
