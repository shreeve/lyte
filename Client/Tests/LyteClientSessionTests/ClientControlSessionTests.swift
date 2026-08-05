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

    func testUnrelatedReliableWordIsNotClaimed() throws {
        var session = makeSession()
        XCTAssertNil(try session.receiveReliable(
            [CtrlMessageType.idleFrame], now: at(10)))
    }

    private func makeSession() -> ClientControlSession {
        ClientControlSession(
            localCapabilities: local,
            machineConfig: SessionMachineConfig(),
            now: at(0)
        )
    }

    private func at(_ microseconds: UInt64) -> ClientTimestamp {
        ClientTimestamp(microseconds: microseconds)
    }
}
