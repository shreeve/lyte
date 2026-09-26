import XCTest
import LyteClientSession
import LyteTransport
import LyteWire

// The overlay's input line renders unconditionally: "0 events sent" is
// the datum that tells a client-capture failure from a host-side one.
final class InputStatsLineTests: XCTestCase {

    func testOverlayLineRendersAtZeroEvents() throws {
        let stats = InputSender(clockModel: HostClockModel()) { _, _ in }
            .snapshotStats()
        XCTAssertEqual(stats.overlayLine(), "0 events sent to host")
    }

    func testOverlayLineRendersLatencyPercentilesExactly() throws {
        // The InputPathGateTests fit, verbatim: offset (client − host)
        // exactly +500 000 µs, zero skew.
        let clock = HostClockModel()
        for (t, seq) in [(UInt64(100_000), UInt32(0)),
                         (UInt64(200_000), UInt32(1)),
                         (UInt64(300_000), UInt32(2))] {
            clock.ingest(ClockSample(
                beaconSeq: seq,
                offsetMicroseconds: 500_000,
                rttMicroseconds: 8_000,
                measuredAt: ClientTimestamp(microseconds: t)))
        }
        let sender = InputSender(clockModel: clock) { _, _ in }

        // One event, one echo: input→inject exactly 101 500 µs, so
        // p50 = p99 = 101.5 ms in the rendered line.
        _ = try sender.send(
            .keyKeycode(keycode: 30, pressed: true),
            now: ClientTimestamp(microseconds: 1_000_000))
        sender.handleEcho(
            InputEcho(tuples: [InputEchoTuple(
                seq: 0,
                receivedMicroseconds: 600_000,
                injectedMicroseconds: 601_500)]),
            now: ClientTimestamp(microseconds: 1_012_000))

        XCTAssertEqual(
            sender.snapshotStats().overlayLine(),
            "1 event sent to host"
                + " · applied on host p50/p99 101.5/101.5 ms")
    }
}
