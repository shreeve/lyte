import XCTest
import LyteWire

// The anchor bytes below were computed by hand from the layout comment in
// ClockBeacon.swift, not by running the codec — same circularity-breaking
// rule as EnvelopeTests/FecFieldTests.

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

    func testBeaconAnchorEncode() {
        XCTAssertEqual(beaconAnchor.encode(), beaconAnchorBytes)
        XCTAssertEqual(beaconAnchorBytes.count, ClockBeacon.encodedByteCount)
    }

    func testBeaconAnchorDecode() throws {
        XCTAssertEqual(try ClockBeacon.decode(beaconAnchorBytes), beaconAnchor)
    }

    func testEchoAnchorEncode() {
        XCTAssertEqual(echoAnchor.encode(), echoAnchorBytes)
        XCTAssertEqual(echoAnchorBytes.count, BeaconEcho.encodedByteCount)
    }

    func testEchoAnchorDecode() throws {
        XCTAssertEqual(try BeaconEcho.decode(echoAnchorBytes), echoAnchor)
    }

    // MARK: First beacon (no echo yet)

    func testBeaconWithoutEchoRoundTrip() throws {
        let first = ClockBeacon(
            beaconSeq: 0,
            hostSend: HostTimestamp(microseconds: 1_000_000_000)
        )
        let bytes = first.encode()
        XCTAssertEqual(bytes.count, ClockBeacon.encodedByteCount)
        XCTAssertEqual(bytes[1], 0, "flags must be 0 without lastEcho")
        XCTAssertTrue(
            bytes[14...].allSatisfy { $0 == 0 },
            "absent lastEcho fields must be zero on the wire"
        )
        XCTAssertEqual(try ClockBeacon.decode(bytes), first)
    }

    func testNonZeroAbsentEchoFieldsRejected() {
        // Flip one byte in each absent-echo field of a flags=0 beacon.
        var bytes = ClockBeacon(
            beaconSeq: 3, hostSend: HostTimestamp(microseconds: 42)
        ).encode()
        for index in [14, 20, 30] {
            var corrupt = bytes
            corrupt[index] = 0xAA
            XCTAssertThrowsError(try ClockBeacon.decode(corrupt)) {
                XCTAssertEqual($0 as? BeaconError, .nonZeroAbsentEchoFields)
            }
        }
        // And the same bytes decode fine once the flag admits them.
        bytes[1] = 0x01
        XCTAssertNoThrow(try ClockBeacon.decode(bytes))
    }

    // MARK: Flags and type dispatch

    func testReservedFlagBitsIgnoredOnDecode() throws {
        var bytes = beaconAnchorBytes
        bytes[1] = 0x81 // bit0 kept, reserved bit set
        XCTAssertEqual(try ClockBeacon.decode(bytes), beaconAnchor)
    }

    func testWrongTypeRejected() {
        XCTAssertThrowsError(try ClockBeacon.decode(echoAnchorBytes + [0, 0, 0, 0, 0])) {
            XCTAssertEqual($0 as? BeaconError, .unexpectedType(0x02))
        }
        var badEcho = echoAnchorBytes
        badEcho[0] = 0x7F
        XCTAssertThrowsError(try BeaconEcho.decode(badEcho)) {
            XCTAssertEqual($0 as? BeaconError, .unexpectedType(0x7F))
        }
        XCTAssertEqual(CtrlMessageType.peek(beaconAnchorBytes), 0x01)
        XCTAssertEqual(CtrlMessageType.peek(echoAnchorBytes), 0x02)
        XCTAssertNil(CtrlMessageType.peek([]))
    }

    // MARK: Size strictness

    func testTruncationRejected() {
        for cut in 0..<beaconAnchorBytes.count {
            XCTAssertThrowsError(
                try ClockBeacon.decode(Array(beaconAnchorBytes.prefix(cut)))
            ) {
                XCTAssertEqual($0 as? BeaconError, .truncatedMessage, "cut \(cut)")
            }
        }
        for cut in 0..<echoAnchorBytes.count {
            XCTAssertThrowsError(
                try BeaconEcho.decode(Array(echoAnchorBytes.prefix(cut)))
            ) {
                XCTAssertEqual($0 as? BeaconError, .truncatedMessage, "cut \(cut)")
            }
        }
    }

    func testTrailingBytesRejected() {
        XCTAssertThrowsError(try ClockBeacon.decode(beaconAnchorBytes + [0x00])) {
            XCTAssertEqual($0 as? BeaconError, .trailingBytes)
        }
        XCTAssertThrowsError(try BeaconEcho.decode(echoAnchorBytes + [0x00])) {
            XCTAssertEqual($0 as? BeaconError, .trailingBytes)
        }
    }

    // MARK: The offset/RTT sample (the README worked example)

    func testClockSampleWorkedExample() {
        // True offset (client − host) 250,000 µs; forward path 3,000 µs,
        // reverse 5,000 µs, client turnaround 500 µs:
        //   t1 = 1,000,000                       (host send)
        //   t2 = t1 + 250,000 + 3,000 = 1,253,000 (client receive)
        //   t3 = t2 + 500             = 1,253,500 (client send)
        //   t4 = t3 − 250,000 + 5,000 = 1,008,500 (host receive)
        //   rtt    = (t4−t1) − (t3−t2) = 8,500 − 500 = 8,000
        //   offset = ((t2−t1) + (t3−t4)) / 2 = (253,000 + 245,000) / 2
        //          = 249,000 — 1,000 µs shy of truth, exactly the path
        //   asymmetry / 2 the timing doc's min-filter accepts.
        let echo = BeaconEcho(
            beaconSeq: 12,
            hostSend: HostTimestamp(microseconds: 1_000_000),
            clientReceive: ClientTimestamp(microseconds: 1_253_000),
            clientSend: ClientTimestamp(microseconds: 1_253_500)
        )
        let sample = echo.clockSample(
            hostReceive: HostTimestamp(microseconds: 1_008_500)
        )
        XCTAssertEqual(sample.offsetMicroseconds, 249_000)
        XCTAssertEqual(sample.rttMicroseconds, 8_000)
    }

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
