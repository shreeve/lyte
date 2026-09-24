import HostCore
import XCTest

final class HostServiceLoopTests: XCTestCase {
    private let streamed = HostServiceLoop.LegEvidence(
        frames: 120, firstPacketStartsStream: true)
    private let empty = HostServiceLoop.LegEvidence(
        frames: 0, firstPacketStartsStream: false)

    func testOnlyAnUnclockedNonPairingListenerIsTheService() {
        typealias Loop = HostServiceLoop
        XCTAssertEqual(
            Loop.posture(listening: true, secondsGiven: false,
                         pairing: false, seconds: 5),
            .service)
        XCTAssertEqual(
            Loop.posture(listening: true, secondsGiven: true,
                         pairing: false, seconds: 7_200),
            .singleSession(seconds: 7_200),
            "an explicit --seconds keeps the bounded one-session run")
        XCTAssertEqual(
            Loop.posture(listening: true, secondsGiven: false,
                         pairing: true, seconds: 5),
            .singleSession(seconds: 5),
            "one PIN, one session")
        XCTAssertEqual(
            Loop.posture(listening: false, secondsGiven: false,
                         pairing: false, seconds: 5),
            .singleSession(seconds: 5),
            "wire-out and file mode serve once")
    }

    func testTheServiceHasNoClockAndServesSessionAfterSession() {
        var loop = HostServiceLoop(posture: .service)
        XCTAssertEqual(loop.sessionSeconds, .infinity)
        for _ in 0..<3 {
            XCTAssertEqual(
                loop.sessionEnded(.sessionEnded, leg: streamed),
                .serveAnother)
        }
        // A client that leaves before the first frame is not a host fault.
        XCTAssertEqual(
            loop.sessionEnded(.sessionEnded, leg: empty), .serveAnother)
        XCTAssertEqual(loop.sessionsServed, 4)
    }

    func testTheServiceStopsOnTerminationModeChangeOrFailure() {
        var loop = HostServiceLoop(posture: .service)
        XCTAssertEqual(
            loop.sessionEnded(.terminationRequested, leg: streamed),
            .exit(failure: nil))
        XCTAssertEqual(
            loop.sessionEnded(.terminatedBeforeHandshake, leg: empty),
            .exit(failure: nil))
        XCTAssertEqual(
            loop.sessionEnded(.displayModeChanged, leg: streamed),
            .exit(failure: nil),
            "the warm scanout holds the old geometry; a fresh process reads the new")
        XCTAssertEqual(
            loop.sessionEnded(.failed("vaEndPicture"), leg: streamed),
            .exit(failure: "vaEndPicture"),
            "a failed leg never loops on possibly broken GPU state")
    }

    func testAnUnstartableStreamIsAFailureInEveryPosture() {
        let broken = HostServiceLoop.LegEvidence(
            frames: 3, firstPacketStartsStream: false)
        var service = HostServiceLoop(posture: .service)
        var single = HostServiceLoop(posture: .singleSession(seconds: 5))
        for next in [
            service.sessionEnded(.sessionEnded, leg: broken),
            single.sessionEnded(.clockExpired, leg: broken),
        ] {
            guard case .exit(let failure?) = next else {
                return XCTFail("expected a failure, got \(next)")
            }
            XCTAssertTrue(failure.contains("VPS/SPS/PPS"))
        }
    }

    func testASingleSessionExitsAfterItAndDemandsFrames() {
        var loop = HostServiceLoop(posture: .singleSession(seconds: 7_200))
        XCTAssertEqual(loop.sessionSeconds, 7_200)
        XCTAssertEqual(
            loop.sessionEnded(.clockExpired, leg: streamed),
            .exit(failure: nil))

        var idle = HostServiceLoop(posture: .singleSession(seconds: 5))
        XCTAssertEqual(
            idle.sessionEnded(.clockExpired, leg: empty),
            .exit(failure: "direct eye produced no frames in 5s"))

        var interrupted = HostServiceLoop(posture: .singleSession(seconds: 5))
        XCTAssertEqual(
            interrupted.sessionEnded(.terminationRequested, leg: empty),
            .exit(failure: "direct eye produced no frames in 5s"))

        var unbounded = HostServiceLoop(posture: .singleSession(seconds: .infinity))
        XCTAssertEqual(
            unbounded.sessionEnded(.terminationRequested, leg: empty),
            .exit(failure: "direct eye produced no frames"),
            "a bound too large for an Int is still reported, not trapped on")

        var paired = HostServiceLoop(posture: .singleSession(seconds: 5))
        XCTAssertEqual(
            paired.sessionEnded(.sessionEnded, leg: empty),
            .exit(failure: nil),
            "a client that leaves before the first frame (pairing) is no eye fault")

        var early = HostServiceLoop(posture: .singleSession(seconds: 5))
        XCTAssertEqual(
            early.sessionEnded(.terminatedBeforeHandshake, leg: empty),
            .exit(failure: nil),
            "no leg ran, so no frames are owed")
    }
}
