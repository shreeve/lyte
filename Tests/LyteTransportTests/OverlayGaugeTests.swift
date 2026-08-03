import XCTest
import LyteTransport

// The radio watchdog's 3-strike debounce behaves exactly as the AWDL
// choppiness verdict demands. The shared overlay gauge arithmetic now lives
// and is pinned beside its sans-IO LyteCore policy.

final class RadioHoldPolicyTests: XCTestCase {

    func testHeldRadioIsHealthy() {
        var policy = RadioHoldPolicy()
        XCTAssertEqual(policy.check(radioUp: false), .none)
        XCTAssertFalse(policy.alarm)
        XCTAssertEqual(policy.looseChecks, 0)
    }

    func testFirstLooseSightingAsksForReengage() {
        var policy = RadioHoldPolicy()
        XCTAssertEqual(policy.check(radioUp: true), .reengage)
        XCTAssertFalse(policy.alarm, "one sighting must not alarm")
    }

    func testThreeConsecutiveLooseChecksLatchTheAlarm() {
        var policy = RadioHoldPolicy()
        XCTAssertEqual(policy.check(radioUp: true), .reengage)
        XCTAssertEqual(policy.check(radioUp: true), .none)
        XCTAssertFalse(policy.alarm)
        XCTAssertEqual(policy.check(radioUp: true), .none)
        XCTAssertTrue(policy.alarm)
    }

    func testRecoveryClearsStrikesAndAlarm() {
        var policy = RadioHoldPolicy()
        for _ in 0..<3 { _ = policy.check(radioUp: true) }
        XCTAssertTrue(policy.alarm)
        XCTAssertEqual(policy.check(radioUp: false), .none)
        XCTAssertFalse(policy.alarm)
        // The next loose era is a fresh episode: re-engage fires again.
        XCTAssertEqual(policy.check(radioUp: true), .reengage)
    }

    func testResetForStreamEnd() {
        var policy = RadioHoldPolicy()
        _ = policy.check(radioUp: true)
        _ = policy.check(radioUp: true)
        policy.reset()
        XCTAssertEqual(policy, RadioHoldPolicy())
    }
}
