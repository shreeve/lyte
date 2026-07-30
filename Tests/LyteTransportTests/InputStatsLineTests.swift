import XCTest
import LyteTransport
import LyteWire

// CL-16, the stats-truthfulness half: the overlay's input line renders
// UNCONDITIONALLY — "input 0 sent" is the datum that discriminates a
// client-capture failure from a host-side one, and the line carries
// the capture-install verdict for the same reason. (CL-13 hid the line
// while eventsSent == 0, which hid exactly the interesting case.) The
// app's statsLines() feeds this formatter straight from the sender's
// books; the contract pinned here is the formatter's.
final class InputStatsLineTests: XCTestCase {

    func testOverlayLineRendersAtZeroEvents() throws {
        // A fresh sender that never sent: the line must still exist
        // and say zero — the datum that discriminates a client-capture
        // failure from a host-side one. (Capture state itself moved to
        // the overlay's state line, 2026-07-30 consult round two.)
        let stats = InputSender(clockModel: HostClockModel()) { _, _ in }
            .snapshotStats()
        XCTAssertEqual(stats.overlayLine(), "outbound: 0 client events sent")
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
            "outbound: 1 client event sent"
                + " · applied on host p50/p99 101.5/101.5 ms")
    }
}
