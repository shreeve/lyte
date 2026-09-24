import XCTest
import HostSession
import HostWire
import HostWireTestKit
import LyteWire
import LyteWireTestKit

// Every timestamp an authenticated client supplies (beacon-echo t1/t2/t3,
// dispersion bases and arrival deltas) is hostile input: none may trap the
// host, and none may drive RTT or queuing-delay state out of range.
final class HostileTimestampGateTests: XCTestCase {
    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_041,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    func testEchoedTimestampsCannotTrapOrPoisonTheRttGate() throws {
        let host = HostSessionHarness(
            config: SessionConfig(
                crypto: .noise(hostStatic: NoiseKeyPair.generate()),
                rateBitsPerSecond: 20_000_000,
                beaconIntervalNS: 1 << 62
            ),
            tuple: Self.tupleA,
            rng: SplitMix64(seed: 0xEC40)
        )
        var client = try host.connectClient(declaring: nil)
        try host.deliver(to: &client, at: 0)

        // The session-start beacon left at host µs 0 as beaconSeq 0.
        func echo(
            seq: UInt32, t1: UInt64, t2: UInt64, t3: UInt64, at t4: UInt64
        ) throws -> [SessionEvent] {
            let body = BeaconEcho(
                beaconSeq: seq,
                hostSend: HostTimestamp(microseconds: t1),
                clientReceive: ClientTimestamp(microseconds: t2),
                clientSend: ClientTimestamp(microseconds: t3)
            ).encode()
            return host.receive(
                try client.datagram(body: body, sealed: true, timestamp: t3),
                at: t4
            )
        }
        // Turnarounds that put the RTT near Int64.min/max or at −100 µs
        // (the pair that trapped the SRTT EWMA), past the round trip, or
        // an echo of a beacon that never left.
        let hostile: [(UInt32, UInt64, UInt64, UInt64)] = [
            (0, UInt64(Int64.max), 0, UInt64(Int64.max)),
            (0, 0, 0, 2_100),
            (0, 0, 100, 0),
            (0, UInt64.max, UInt64(Int64.max), 1),
            (0, 0, 0, UInt64(Int64.max) + 1),
            (7, 0, 1, 2),
        ]
        for (seq, t1, t2, t3) in hostile {
            XCTAssertEqual(
                try echo(seq: seq, t1: t1, t2: t2, t3: t3, at: 2_000),
                [.dropped(.beaconEchoUnmatched)])
        }
        XCTAssertNil(host.session.srttMicroseconds)
        XCTAssertEqual(host.session.clock.samples, 0)

        // The genuine echo, even with a forged t1, measures from the
        // host's own t1: 2_000 µs round trip − 500 µs turnaround.
        XCTAssertEqual(
            try echo(seq: 0, t1: 999_999, t2: 40_000, t3: 40_500, at: 2_000),
            [.beaconEchoAccepted(
                beaconSeq: 0,
                offsetMicroseconds: Int64(40_000 + 40_500 - 2_000) / 2,
                rttMicroseconds: 1_500)])
        XCTAssertEqual(host.session.srttMicroseconds, 1_500)
    }

    func testOutOfRangeRttSamplesNeverReachTheEstimator() {
        let estimator = RateEstimator(
            config: RateEstimatorConfig(ceilingBitsPerSecond: 20_000_000),
            now: 0)
        for sample in [Int64.min, Int64.max, -100, 10_000_001] {
            estimator.noteRtt(microseconds: sample)
        }
        XCTAssertNil(estimator.srttMicroseconds)
        XCTAssertNil(estimator.minRttMicroseconds)
        estimator.noteRtt(microseconds: 900)
        estimator.noteRtt(microseconds: 10_000_000)
        XCTAssertEqual(estimator.minRttMicroseconds, 900)
        XCTAssertEqual(estimator.srttMicroseconds, 900 + (10_000_000 - 900) / 8)
    }

    func testDispersionBasesAtTheEdgesOfTheClockCannotTrapTheDelaySensor() {
        let estimator = RateEstimator(
            config: RateEstimatorConfig(ceilingBitsPerSecond: 20_000_000),
            now: 0)
        // Every datagram left at host µs 1_000, so each report's one-way
        // delay is its base − 1_000: Int64.min, then 2^62, then the rest
        // of the clock's edges.
        let bases: [UInt64] = [
            UInt64(bitPattern: Int64.min) &+ 1_000,
            1_000 + 1 << 62,
            UInt64(bitPattern: Int64.max),
            UInt64(bitPattern: Int64.min),
            0,
            UInt64.max,
        ]
        var seq: UInt16 = 0
        var now: UInt64 = 1_000_000
        for base in bases {
            estimator.noteSent(
                channel: .videoActive, seq: ChannelSeq(rawValue: seq),
                bytes: 1_152, now: 1_000_000)
            let report = FeedbackReport(
                clientTimestamp: ClientTimestamp(microseconds: base),
                dispersion: FeedbackReport.Dispersion(
                    base: ClientTimestamp(microseconds: base),
                    samples: [FeedbackReport.Dispersion.Sample(
                        channel: .videoActive, seq: ChannelSeq(rawValue: seq),
                        arrivalDeltaMicroseconds: 0)]))
            now += 30_000_000
            _ = estimator.ingest(report, now: now, inRecovery: false)
            seq &+= 1
            XCTAssertGreaterThanOrEqual(
                estimator.queuingDelayMicroseconds ?? 0, 0,
                "inflation is a non-negative distance above the baseline")
        }
        XCTAssertGreaterThanOrEqual(
            estimator.rateBitsPerSecond, estimator.config.floorBitsPerSecond)
    }
}
