import LyteClientSession
import LyteWire
import XCTest

final class ClientSessionLifecycleTests: XCTestCase {
    func testReceiverModeEdgesReportExactlyOnce() {
        var lifecycle = ClientSessionLifecycle(
            config: SessionMachineConfig(),
            now: at(0)
        )

        let idle = lifecycle.advance(
            .modeMessage(.idle),
            now: at(10)
        )
        XCTAssertEqual(idle.state, .idle)
        XCTAssertEqual(idle.wireMode, .idle)
        XCTAssertEqual(idle.stateChange, .idle)
        XCTAssertEqual(idle.wireModeChange, .idle)
        XCTAssertEqual(idle.actions, [])

        let steady = lifecycle.advance(now: at(11))
        XCTAssertNil(steady.stateChange)
        XCTAssertNil(steady.wireModeChange)
        XCTAssertEqual(steady.actions, [])
    }

    func testSilenceAndEvidenceFormOneFrozenEpisode() {
        let config = SessionMachineConfig(
            blackoutSilenceMicroseconds: 350,
            livenessTimeoutMicroseconds: 30_000
        )
        var lifecycle = ClientSessionLifecycle(config: config, now: at(0))

        let frozen = lifecycle.advance(now: at(350))
        XCTAssertEqual(frozen.state, .frozen)
        XCTAssertEqual(frozen.stateChange, .frozen)
        XCTAssertTrue(lifecycle.isFrozen)

        let recovered = lifecycle.advance(
            .mediaPathEvidence,
            now: at(351)
        )
        XCTAssertEqual(recovered.state, .active)
        XCTAssertEqual(recovered.stateChange, .active)
        XCTAssertFalse(lifecycle.isFrozen)
        XCTAssertNil(lifecycle.advance(now: at(352)).stateChange)
    }

    func testReconfigurePreservesModeAndDefersTheEdge() {
        var lifecycle = ClientSessionLifecycle(
            config: SessionMachineConfig(
                blackoutSilenceMicroseconds: 100
            ),
            now: at(0)
        )
        _ = lifecycle.advance(.modeMessage(.idle), now: at(1))
        let frozen = lifecycle.advance(now: at(101))
        XCTAssertEqual(frozen.state, .frozen)
        XCTAssertEqual(frozen.wireMode, .idle)

        XCTAssertTrue(lifecycle.reconfigure(
            SessionMachineConfig(blackoutSilenceMicroseconds: 2_500),
            now: at(102)
        ))
        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertEqual(lifecycle.wireMode, .idle)

        let next = lifecycle.advance(now: at(102))
        XCTAssertEqual(next.stateChange, .idle)
        XCTAssertNil(next.wireModeChange)
    }

    func testTeardownReturnsWireActionAndTerminalEdgeTogether() {
        var lifecycle = ClientSessionLifecycle(
            config: SessionMachineConfig(),
            now: at(0)
        )
        let decision = lifecycle.advance(
            .teardownRequest(.shuttingDown),
            now: at(1)
        )

        XCTAssertEqual(decision.actions, [
            .sendTeardownMessage(.shuttingDown),
            .sessionClosed(.localTeardown(.shuttingDown)),
        ])
        XCTAssertEqual(decision.stateChange, .closed)
        XCTAssertFalse(lifecycle.reconfigure(
            SessionMachineConfig(),
            now: at(2)
        ))
    }

    private func at(_ microseconds: UInt64) -> ClientTimestamp {
        ClientTimestamp(microseconds: microseconds)
    }
}
