import XCTest
import Foundation
import HostWire
import LyteWire

final class SessionBeaconClockTests: XCTestCase {
    func testSessionDelegatesBeaconPolicyToTheNamedOwner() throws {
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
            "private var beaconClock: SessionBeaconClock"
        ))
        for retiredOwnerSpelling in [
            "private var beaconSeq",
            "private var nextBeaconAt",
            "private var lastEcho: ClockBeacon.LastEcho",
            "echo.clockSample(hostReceive:",
        ] {
            XCTAssertFalse(
                session.contains(retiredOwnerSpelling),
                "beacon policy returned to Session: \(retiredOwnerSpelling)"
            )
        }
    }

    func testFailedSendRetriesTheSameSequenceOnTheNextBeat() {
        var clock = SessionBeaconClock(intervalNanoseconds: 1_000)
        clock.armSessionStart(at: 100)

        let refused = clock.takeDueBeacon(now: 100, hostMicroseconds: 10)
        XCTAssertEqual(refused?.beaconSeq, 0)
        XCTAssertEqual(clock.nextDeadlineNanoseconds, 1_100)

        let retry = clock.takeDueBeacon(now: 1_100, hostMicroseconds: 20)
        XCTAssertEqual(retry?.beaconSeq, 0)
        XCTAssertEqual(clock.noteBeaconSent(), 0)

        let next = clock.takeDueBeacon(now: 2_100, hostMicroseconds: 30)
        XCTAssertEqual(next?.beaconSeq, 1)
    }

    func testLateWakePreservesTheBeatOrStartsOneFreshInterval() {
        var clock = SessionBeaconClock(intervalNanoseconds: 1_000)
        clock.armSessionStart(at: 100)

        _ = clock.takeDueBeacon(now: 100, hostMicroseconds: 1)
        XCTAssertEqual(clock.nextDeadlineNanoseconds, 1_100)

        _ = clock.takeDueBeacon(now: 1_101, hostMicroseconds: 2)
        XCTAssertEqual(
            clock.nextDeadlineNanoseconds, 2_100,
            "a small late wake must retain the original cadence"
        )

        _ = clock.takeDueBeacon(now: 4_500, hostMicroseconds: 3)
        XCTAssertEqual(
            clock.nextDeadlineNanoseconds, 5_500,
            "a stalled loop emits once and never schedules a catch-up burst"
        )
        XCTAssertNil(clock.takeDueBeacon(now: 5_499, hostMicroseconds: 4))
    }

    func testEchoOwnsSamplesMinimumRttAndNextBeaconMirror() {
        var clock = SessionBeaconClock(intervalNanoseconds: 1_000)
        let first = BeaconEcho(
            beaconSeq: 7,
            hostSend: HostTimestamp(microseconds: 1_000),
            clientReceive: ClientTimestamp(microseconds: 3_100),
            clientSend: ClientTimestamp(microseconds: 3_200)
        )
        let firstSample = clock.accept(echo: first, hostMicroseconds: 1_300)
        XCTAssertEqual(firstSample.offsetMicroseconds, 2_000)
        XCTAssertEqual(firstSample.rttMicroseconds, 200)

        let slower = BeaconEcho(
            beaconSeq: 8,
            hostSend: HostTimestamp(microseconds: 2_000),
            clientReceive: ClientTimestamp(microseconds: 4_200),
            clientSend: ClientTimestamp(microseconds: 4_300)
        )
        _ = clock.accept(echo: slower, hostMicroseconds: 2_500)

        XCTAssertEqual(clock.stats.samples, 2)
        XCTAssertEqual(clock.stats.lastOffsetMicroseconds, 2_000)
        XCTAssertEqual(clock.stats.lastRttMicroseconds, 400)
        XCTAssertEqual(clock.stats.minRttMicroseconds, 200)
        XCTAssertEqual(clock.stats.minRttOffsetMicroseconds, 2_000)

        let beacon = clock.makeSessionStartBeacon(
            now: 9_000, hostMicroseconds: 9_500
        )
        XCTAssertEqual(
            beacon.lastEcho,
            ClockBeacon.LastEcho(
                beaconSeq: 8,
                clientSend: ClientTimestamp(microseconds: 4_300),
                hostReceive: HostTimestamp(microseconds: 2_500)
            )
        )
    }
}
