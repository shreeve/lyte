import XCTest
import LyteWire

// The anchor bytes below were computed by hand from the layout comment in
// ClockBeacon.swift, not by running the codec — same circularity-breaking
// rule as EnvelopeTests/FecFieldTests. Decode rejects and the leniency
// rules live in beacon-v1.json.

final class ClockBeaconTests: XCTestCase {

    // MARK: Hand-computed anchors

    // type 0x01, flags 0x01 (lastEcho present), beaconSeq=7,
    // hostSend=0x0102030405060708, lastEchoBeaconSeq=6,
    // lastEchoClientSend=0x1112131415161718,
    // lastEchoHostReceive=0x2122232425262728 — every field distinct so an
    // endianness or offset slip is visible byte-by-byte.
    private let beaconAnchorBytes: [UInt8] = [
        0x01, 0x01,
        0x07, 0x00, 0x00, 0x00,
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
        0x06, 0x00, 0x00, 0x00,
        0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11,
        0x28, 0x27, 0x26, 0x25, 0x24, 0x23, 0x22, 0x21,
    ]

    private var beaconAnchor: ClockBeacon {
        ClockBeacon(
            beaconSeq: 7,
            hostSend: HostTimestamp(microseconds: 0x0102_0304_0506_0708),
            lastEcho: ClockBeacon.LastEcho(
                beaconSeq: 6,
                clientSend: ClientTimestamp(microseconds: 0x1112_1314_1516_1718),
                hostReceive: HostTimestamp(microseconds: 0x2122_2324_2526_2728)
            )
        )
    }

    // type 0x02, beaconSeq=0x0A0B0C0D, then t1/t2/t3 with distinct bytes.
    private let echoAnchorBytes: [UInt8] = [
        0x02,
        0x0D, 0x0C, 0x0B, 0x0A,
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
        0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11,
        0x28, 0x27, 0x26, 0x25, 0x24, 0x23, 0x22, 0x21,
    ]

    private var echoAnchor: BeaconEcho {
        BeaconEcho(
            beaconSeq: 0x0A0B_0C0D,
            hostSend: HostTimestamp(microseconds: 0x0102_0304_0506_0708),
            clientReceive: ClientTimestamp(microseconds: 0x1112_1314_1516_1718),
            clientSend: ClientTimestamp(microseconds: 0x2122_2324_2526_2728)
        )
    }

    func testBeaconAnchor() throws {
        XCTAssertEqual(beaconAnchor.encode(), beaconAnchorBytes)
        XCTAssertEqual(beaconAnchorBytes.count, ClockBeacon.encodedByteCount)
        XCTAssertEqual(try ClockBeacon.decode(beaconAnchorBytes), beaconAnchor)
    }

    func testEchoAnchor() throws {
        XCTAssertEqual(echoAnchor.encode(), echoAnchorBytes)
        XCTAssertEqual(echoAnchorBytes.count, BeaconEcho.encodedByteCount)
        XCTAssertEqual(try BeaconEcho.decode(echoAnchorBytes), echoAnchor)
    }

    func testTypePeekDispatches() {
        XCTAssertEqual(CtrlMessageType.peek(beaconAnchorBytes), 0x01)
        XCTAssertEqual(CtrlMessageType.peek(echoAnchorBytes), 0x02)
        XCTAssertNil(CtrlMessageType.peek([]))
    }

    // MARK: The offset/RTT sample (the worked example is beacon-v1.json's)

    func testClockSampleNegativeOffsetAndWrap() {
        // Client clock BEHIND the host by 1 s, symmetric 2 ms path, and
        // host timestamps near the u64 wrap: the subtraction must stay
        // serial (two's-complement), never trap.
        let t1 = UInt64.max - 1_000
        let echo = BeaconEcho(
            beaconSeq: 1,
            hostSend: HostTimestamp(microseconds: t1),
            clientReceive: ClientTimestamp(microseconds: t1 &+ 2_000 &- 1_000_000),
            clientSend: ClientTimestamp(microseconds: t1 &+ 2_100 &- 1_000_000)
        )
        let sample = echo.clockSample(
            hostReceive: HostTimestamp(microseconds: t1 &+ 4_100)
        )
        XCTAssertEqual(sample.offsetMicroseconds, -1_000_000)
        XCTAssertEqual(sample.rttMicroseconds, 4_000)
    }
}
