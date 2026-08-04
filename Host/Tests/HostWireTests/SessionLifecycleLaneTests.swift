import XCTest
import Foundation
@testable import HostWire
import LyteWire

final class SessionLifecycleLaneTests: XCTestCase {
    func testSessionDelegatesLifecycleStateDeadlineAndFreezeProjection()
        throws
    {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false
        )
        components.removeLast(3)
        let packageRoot = components.joined(separator: "/")
        let session = try String(contentsOfFile:
            packageRoot + "/Sources/HostWire/Session.swift",
            encoding: .utf8
        )

        XCTAssertTrue(session.contains(
            "private var lifecycleLane: SessionLifecycleLane"
        ))
        XCTAssertTrue(session.contains("public var phase: Phase {"))
        XCTAssertTrue(session.contains(
            "lifecycleLane.isEstablished ? .established : .awaitingHandshake"
        ))
        for retired in [
            "SessionStateMachine<HostClock>",
            "private var machineDeadlineNS",
            "private var videoFrozen",
            "SessionStateMachine(",
            "public private(set) var phase",
            "self.phase =",
            "phase = .established",
            "phase = .awaitingHandshake",
        ] {
            XCTAssertFalse(
                session.contains(retired),
                "lifecycle ownership returned to Session: \(retired)"
            )
        }
        XCTAssertTrue(session.contains("lifecycleLane.videoSendsSuppressed"))
        XCTAssertTrue(session.contains("lifecycleLane.audioSendsSuppressed"))
        XCTAssertTrue(session.contains(
            "lifecycleLane.nextDeadlineNanoseconds"
        ))
        XCTAssertTrue(session.contains("lifecycleLane.isRecovering"))
        XCTAssertTrue(session.contains("lifecycleLane.shouldService(at: now)"))
    }

    func testDormantLaneBeginsAtEstablishmentAndProjectsExactDeadline() {
        var lane = SessionLifecycleLane(config: SessionMachineConfig())

        XCTAssertFalse(lane.isEstablished)
        XCTAssertNil(lane.state)
        XCTAssertNil(lane.nextDeadlineNanoseconds)
        XCTAssertTrue(lane.videoSendsSuppressed)
        XCTAssertTrue(lane.audioSendsSuppressed)
        let dormant = lane.drive(.damage, now: 900)
        XCTAssertTrue(dormant.actions.isEmpty)
        XCTAssertNil(dormant.stateChangedTo)

        lane.establish(at: 1_234_567)
        XCTAssertEqual(lane.state, .active)
        XCTAssertNil(lane.nextDeadlineNanoseconds)
        XCTAssertTrue(lane.shouldService(at: 1_234_567))
        XCTAssertFalse(lane.videoSendsSuppressed)
        XCTAssertFalse(lane.audioSendsSuppressed)

        let first = lane.drive(nil, now: 1_234_567)
        XCTAssertTrue(first.actions.isEmpty)
        XCTAssertNil(first.stateChangedTo)
        XCTAssertEqual(
            lane.nextDeadlineNanoseconds,
            351_234_000,
            "the machine's µs instant is projected exactly back into ns"
        )
        XCTAssertFalse(lane.shouldService(at: 351_233_999))
        XCTAssertTrue(lane.shouldService(at: 351_234_000))
    }

    func testInputAppliesBeforeTimersPollAtTheSameInstant() {
        var lane = SessionLifecycleLane(
            config: SessionMachineConfig(
                blackoutSilenceMicroseconds: 350,
                livenessTimeoutMicroseconds: 30_000
            ),
            establishedAtNanoseconds: 0
        )
        _ = lane.drive(nil, now: 0)
        XCTAssertEqual(lane.nextDeadlineNanoseconds, 350_000)

        let verdict = lane.drive(.mediaPathEvidence, now: 350_000)

        XCTAssertEqual(lane.state, .active)
        XCTAssertNil(verdict.stateChangedTo)
        XCTAssertTrue(verdict.actions.isEmpty)
        XCTAssertEqual(
            lane.nextDeadlineNanoseconds, 700_000,
            "fresh evidence at the boundary must re-arm before poll judges it"
        )
    }

    func testFrozenRecoveryActiveAndClosedMediaProjections() {
        var lane = SessionLifecycleLane(
            config: SessionMachineConfig(
                blackoutSilenceMicroseconds: 100,
                livenessTimeoutMicroseconds: 1_000,
                cleanWindowsToRecover: 2
            ),
            establishedAtNanoseconds: 0
        )
        _ = lane.drive(nil, now: 0)

        let frozen = lane.drive(nil, now: 100_000)
        XCTAssertEqual(frozen.stateChangedTo, .frozen)
        XCTAssertTrue(frozen.actions.isEmpty,
                      "the lane consumes its local freeze action")
        XCTAssertTrue(lane.videoSendsSuppressed)
        XCTAssertFalse(
            lane.audioSendsSuppressed,
            "FROZEN deliberately keeps audio alive as the path probe"
        )

        let recovery = lane.drive(.ctrlEvidence, now: 101_000)
        XCTAssertEqual(recovery.stateChangedTo, .recovery)
        XCTAssertEqual(recovery.actions, [.forceIdr(.halfStaleEstimate)])
        XCTAssertTrue(lane.isRecovering)
        XCTAssertFalse(lane.videoSendsSuppressed)
        XCTAssertFalse(lane.audioSendsSuppressed)

        let firstClean = lane.drive(
            .feedbackWindow(clean: true), now: 102_000
        )
        XCTAssertNil(firstClean.stateChangedTo)
        let active = lane.drive(
            .feedbackWindow(clean: true), now: 103_000
        )
        XCTAssertEqual(active.stateChangedTo, .active)
        XCTAssertTrue(active.actions.isEmpty)
        XCTAssertFalse(lane.isRecovering)

        let closed = lane.drive(
            .teardownRequest(.shuttingDown), now: 104_000
        )
        XCTAssertEqual(closed.stateChangedTo, .closed)
        XCTAssertEqual(closed.actions, [
            .sendTeardownMessage(.shuttingDown),
            .sessionClosed(.localTeardown(.shuttingDown)),
        ])
        XCTAssertNil(lane.nextDeadlineNanoseconds)
        XCTAssertFalse(lane.shouldService(at: .max))
        XCTAssertTrue(
            lane.isEstablished,
            "CLOSED is a terminal established machine, not handshake dormancy"
        )
        XCTAssertTrue(lane.videoSendsSuppressed)
        XCTAssertTrue(lane.audioSendsSuppressed)
    }

    func testIdleAndWakeEachReturnOneFinalStateChangeVerdict() {
        var lane = SessionLifecycleLane(
            config: SessionMachineConfig(), establishedAtNanoseconds: 0
        )

        let converged = lane.drive(.ratchetConverged, now: 1_000)
        XCTAssertNil(converged.stateChangedTo)
        XCTAssertEqual(converged.actions, [.sendFinalFrameReliably])

        let idle = lane.drive(.finalFrameAcknowledged, now: 2_000)
        XCTAssertEqual(idle.stateChangedTo, .idle)
        XCTAssertEqual(idle.actions, [.sendModeMessage(.idle)])
        XCTAssertFalse(lane.videoSendsSuppressed)
        XCTAssertFalse(lane.audioSendsSuppressed)

        let wake = lane.drive(.damage, now: 3_000)
        XCTAssertEqual(wake.stateChangedTo, .active)
        XCTAssertEqual(wake.actions, [
            .sendModeMessage(.active),
            .armNextDamageAsIdr(.lastGoodRate),
        ])
    }
}
