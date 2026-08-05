import LyteClientSession
import LyteWire
import XCTest

final class ClientMediaPostureSessionTests: XCTestCase {
    private var postureCapabilities: Capabilities {
        Capabilities.wireDefault
            .declaringAudioQuietPosture()
            .declaringVideoQuietPosture()
    }

    func testAudioPostureTracksAnnouncementsAndAuthenticatedEvidence() {
        var session = ClientMediaPostureSession()
        let quiet = AudioTrackState(state: .quiet)
        let active = AudioTrackState(state: .active)

        XCTAssertEqual(
            session.receiveReliable(
                quiet.encode(), agreed: postureCapabilities),
            .audioState(quiet))
        XCTAssertTrue(session.hostAnnouncedAudioQuiet)

        session.noteAudioEvidence()
        XCTAssertFalse(session.hostAnnouncedAudioQuiet)

        XCTAssertEqual(
            session.receiveReliable(
                active.encode(), agreed: postureCapabilities),
            .audioState(active))
        XCTAssertFalse(session.hostAnnouncedAudioQuiet)
    }

    func testVideoPostureOwnsTheChangeEdge() {
        var session = ClientMediaPostureSession()
        let quiet = VideoPostureState(posture: .quiet, keepaliveSeconds: 5)

        XCTAssertEqual(
            session.receiveReliable(
                quiet.encode(), agreed: postureCapabilities),
            .videoState(quiet, changed: true))
        XCTAssertEqual(session.announcedVideoPosture, quiet)
        XCTAssertEqual(
            session.receiveReliable(
                quiet.encode(), agreed: postureCapabilities),
            .videoState(quiet, changed: false))
    }

    func testValidPosturesRequireTheirNegotiatedCapabilities() {
        var session = ClientMediaPostureSession()

        XCTAssertEqual(
            session.receiveReliable(
                AudioTrackState(state: .quiet).encode(),
                agreed: .wireDefault),
            .unnegotiatedAudioState)
        XCTAssertEqual(
            session.receiveReliable(
                VideoPostureState(
                    posture: .active, keepaliveSeconds: 1).encode(),
                agreed: .wireDefault),
            .unnegotiatedVideoState)
        XCTAssertFalse(session.hostAnnouncedAudioQuiet)
        XCTAssertNil(session.announcedVideoPosture)
    }

    func testMalformedPosturesAreClassifiedBeforeCapability() {
        var session = ClientMediaPostureSession()

        XCTAssertEqual(
            session.receiveReliable(
                [CtrlMessageType.audioTrackState], agreed: nil),
            .malformedAudioState)
        XCTAssertEqual(
            session.receiveReliable(
                [CtrlMessageType.videoPostureState], agreed: nil),
            .malformedVideoState)
    }

    func testUnrelatedReliableWordIsNotClaimed() {
        var session = ClientMediaPostureSession()

        XCTAssertNil(session.receiveReliable(
            [CtrlMessageType.idleFrame], agreed: postureCapabilities))
    }
}
