import LyteClientSession
import LyteWire
import XCTest

final class ClientAudioRoutingSessionTests: XCTestCase {
    private let routing = Capabilities.wireDefault
        .declaringHostAudioRouting()

    func testRequestRequiresNegotiatedRouting() {
        let session = ClientAudioRoutingSession(desiredAtStart: nil)

        XCTAssertThrowsError(try session.request(.hostMuted, agreed: nil)) {
            XCTAssertEqual($0 as? AudioRoutingAskError, .notNegotiated)
        }
        XCTAssertThrowsError(
            try session.request(.hostMuted, agreed: .wireDefault)
        ) {
            XCTAssertEqual($0 as? AudioRoutingAskError, .notNegotiated)
        }
    }

    func testRequestPinsBytesAndStreamOffHasItsOwnCapabilityGate() throws {
        let session = ClientAudioRoutingSession(desiredAtStart: nil)

        XCTAssertEqual(
            try session.request(.hostMuted, agreed: routing),
            [0x18, 0x02]
        )
        XCTAssertThrowsError(
            try session.request(.streamOff, agreed: routing)
        ) {
            XCTAssertEqual(
                $0 as? AudioRoutingAskError, .streamOffNotNegotiated)
        }
        XCTAssertEqual(
            try session.request(
                .streamOff,
                agreed: routing.declaringAudioStreamOff()),
            [0x18, 0x04]
        )
    }

    func testFirstStatusConfirmsPostureAndRequestsDifferentPreference() {
        var session = ClientAudioRoutingSession(
            desiredAtStart: .hostMuted)

        XCTAssertEqual(
            session.receiveReliable(
                AudioRoutingStatus(mode: .hostAudible).encode(),
                agreed: routing),
            ClientAudioRoutingSessionDecision(
                outboundReliable: [[0x18, 0x02]],
                event: .status(
                    .hostAudible,
                    startup: .requested(.hostMuted)))
        )
        XCTAssertEqual(session.posture, .hostAudible)
    }

    func testOnlyFirstStatusCanReconcileTheStartupPreference() {
        var session = ClientAudioRoutingSession(
            desiredAtStart: .hostMuted)
        _ = session.receiveReliable(
            AudioRoutingStatus(mode: .hostAudible).encode(),
            agreed: routing)

        XCTAssertEqual(
            session.receiveReliable(
                AudioRoutingStatus(mode: .hostAudible).encode(),
                agreed: routing),
            ClientAudioRoutingSessionDecision(
                event: .status(.hostAudible, startup: .none))
        )
        XCTAssertEqual(session.posture, .hostAudible)
    }

    func testMatchingOrAbsentStartupPreferenceStaysQuiet() {
        var matching = ClientAudioRoutingSession(
            desiredAtStart: .hostAudible)
        var absent = ClientAudioRoutingSession(desiredAtStart: nil)
        let status = AudioRoutingStatus(mode: .hostAudible).encode()
        let quiet = ClientAudioRoutingSessionDecision(
            event: .status(.hostAudible, startup: .none))

        XCTAssertEqual(
            matching.receiveReliable(status, agreed: routing), quiet)
        XCTAssertEqual(absent.receiveReliable(status, agreed: routing), quiet)
    }

    func testUnsupportedStartupStreamOffIsTypedButStatusStillConfirms() {
        var session = ClientAudioRoutingSession(
            desiredAtStart: .streamOff)

        XCTAssertEqual(
            session.receiveReliable(
                AudioRoutingStatus(mode: .hostAudible).encode(),
                agreed: routing),
            ClientAudioRoutingSessionDecision(
                event: .status(
                    .hostAudible,
                    startup: .refused(
                        .streamOff,
                        .streamOffNotNegotiated)))
        )
        XCTAssertEqual(session.posture, .hostAudible)
    }

    func testMalformedStatusIsTypedAndCannotChangePosture() {
        var session = ClientAudioRoutingSession(desiredAtStart: nil)

        XCTAssertEqual(
            session.receiveReliable(
                [CtrlMessageType.audioRoutingStatus], agreed: routing),
            ClientAudioRoutingSessionDecision(event: .malformedStatus)
        )
        XCTAssertNil(session.posture)
    }

    func testUnnegotiatedStatusIsTypedAndCannotChangePosture() {
        var session = ClientAudioRoutingSession(desiredAtStart: nil)

        XCTAssertEqual(
            session.receiveReliable(
                AudioRoutingStatus(mode: .hostMuted).encode(),
                agreed: .wireDefault),
            ClientAudioRoutingSessionDecision(event: .unnegotiatedStatus)
        )
        XCTAssertNil(session.posture)
    }

    func testInboundRequestIsAlwaysTypedAsRoleConfusion() {
        var session = ClientAudioRoutingSession(desiredAtStart: nil)

        XCTAssertEqual(
            session.receiveReliable(
                [CtrlMessageType.audioRoutingRequest], agreed: routing),
            ClientAudioRoutingSessionDecision(event: .roleConfusedRequest)
        )
    }

    func testUnrelatedReliableWordIsNotClaimed() {
        var session = ClientAudioRoutingSession(desiredAtStart: nil)
        XCTAssertNil(session.receiveReliable(
            [CtrlMessageType.idleFrame], agreed: routing))
    }
}
