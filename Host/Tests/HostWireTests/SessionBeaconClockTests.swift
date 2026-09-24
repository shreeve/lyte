import XCTest
import Foundation
import HostWire
import LyteWire

final class SessionBeaconClockTests: XCTestCase {
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

    /// Sends one beacon at host µs `t1` and returns its sequence.
    private func sendBeacon(
        _ clock: inout SessionBeaconClock, at t1: UInt64
    ) -> UInt32 {
        clock.armSessionStart(at: 0)
        _ = clock.takeDueBeacon(now: 0, hostMicroseconds: t1)
        return clock.noteBeaconSent()
    }

    func testEchoOwnsSamplesMinimumRttAndNextBeaconMirror() {
        var clock = SessionBeaconClock(intervalNanoseconds: 1_000)
        let firstSeq = sendBeacon(&clock, at: 1_000)
        let first = BeaconEcho(
            beaconSeq: firstSeq,
            hostSend: HostTimestamp(microseconds: 1_000),
            clientReceive: ClientTimestamp(microseconds: 3_100),
            clientSend: ClientTimestamp(microseconds: 3_200)
        )
        let firstSample = clock.accept(echo: first, hostMicroseconds: 1_300)
        XCTAssertEqual(firstSample?.offsetMicroseconds, 2_000)
        XCTAssertEqual(firstSample?.rttMicroseconds, 200)

        let slowerSeq = sendBeacon(&clock, at: 2_000)
        let slower = BeaconEcho(
            beaconSeq: slowerSeq,
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
                beaconSeq: slowerSeq,
                clientSend: ClientTimestamp(microseconds: 4_300),
                hostReceive: HostTimestamp(microseconds: 2_500)
            )
        )
    }

    func testRttComesFromTheHostsOwnT1NotTheEchoedOne() {
        var clock = SessionBeaconClock(intervalNanoseconds: 1_000)
        let seq = sendBeacon(&clock, at: 10_000)
        // The echo lies about t1; the sample is still 10_400 − 10_000 −
        // turnaround 100 = 300 µs.
        let lying = BeaconEcho(
            beaconSeq: seq,
            hostSend: HostTimestamp(microseconds: UInt64.max),
            clientReceive: ClientTimestamp(microseconds: 50_000),
            clientSend: ClientTimestamp(microseconds: 50_100)
        )
        XCTAssertEqual(
            clock.accept(echo: lying, hostMicroseconds: 10_400)?
                .rttMicroseconds,
            300)
    }

    func testHostileEchoesYieldNoSample() {
        var clock = SessionBeaconClock(intervalNanoseconds: 1_000)
        let seq = sendBeacon(&clock, at: 10_000)
        func echo(
            _ beaconSeq: UInt32, t2: UInt64, t3: UInt64
        ) -> BeaconEcho {
            BeaconEcho(
                beaconSeq: beaconSeq,
                hostSend: HostTimestamp(microseconds: 10_000),
                clientReceive: ClientTimestamp(microseconds: t2),
                clientSend: ClientTimestamp(microseconds: t3))
        }
        let hostile = [
            // A beacon that never left.
            echo(seq &+ 1, t2: 1, t3: 2),
            // Turnaround longer than the whole round trip.
            echo(seq, t2: 0, t3: 5_000),
            // Negative turnaround: RTT past the round trip.
            echo(seq, t2: 5_000, t3: 0),
            // Turnaround that wraps the RTT to Int64.min.
            echo(seq, t2: 0, t3: UInt64(Int64.max) + 1),
            echo(seq, t2: 1, t3: UInt64.max),
        ]
        for message in hostile {
            XCTAssertNil(clock.accept(echo: message, hostMicroseconds: 11_000))
        }
        XCTAssertEqual(clock.stats, SessionClockStats())

        // The genuine echo still lands, once.
        let genuine = echo(seq, t2: 70_000, t3: 70_200)
        XCTAssertEqual(
            clock.accept(echo: genuine, hostMicroseconds: 11_000)?
                .rttMicroseconds,
            800)
        XCTAssertNil(clock.accept(echo: genuine, hostMicroseconds: 11_100),
                     "one sample per beacon")
    }

    func testRoundTripsPastTenSecondsYieldNoSample() {
        var clock = SessionBeaconClock(intervalNanoseconds: 1_000)
        let seq = sendBeacon(&clock, at: 0)
        let late = BeaconEcho(
            beaconSeq: seq,
            hostSend: HostTimestamp(microseconds: 0),
            clientReceive: ClientTimestamp(microseconds: 1),
            clientSend: ClientTimestamp(microseconds: 1))
        XCTAssertNil(clock.accept(echo: late, hostMicroseconds: 10_000_001))
    }
}
