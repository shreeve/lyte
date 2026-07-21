import XCTest
import HostWire
import LyteWire

// The Mac-testable half of `lyte sniff`: exact line formats for the
// dissector, anchored so the Linux socket loop's output is known before
// pop can run it.

final class SniffFormatTests: XCTestCase {

    func testVideoShardLineIsExact() throws {
        let geometry = try FecGeometry(
            dataShards: 17, parityShards: 3, groupByteCount: 18400
        )
        let field = try FecField.reedSolomonShard(5, of: geometry)
        let envelope = Envelope(
            channel: .videoActive,
            seq: ChannelSeq(rawValue: 42),
            frame: FrameNumber(rawValue: 7),
            timestamp: 1_234_567,
            fec: field.encoded
        )
        let payload = [UInt8](repeating: 0xAB, count: 1083)
        let datagram = try envelope.encode(plaintextShard: payload)

        XCTAssertEqual(
            SniffFormat.line(datagram: datagram),
            "chan=2(video-active) seq=00042 frame=7 ts=1234567us "
                + "fec=rs idx=5/20 k=17 m=3 group=18400B "
                + "payload=1083B total=1107B"
        )
    }

    func testFecNoneAndUnknownChannel() throws {
        let envelope = Envelope(
            channel: .ctrl,
            seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0),
            timestamp: 99,
            fec: 0
        )
        let datagram = try envelope.encode(payload: [1, 2, 3])
        XCTAssertEqual(
            SniffFormat.line(datagram: datagram),
            "chan=0(ctrl) seq=00000 frame=0 ts=99us fec=none "
                + "payload=3B total=27B"
        )

        let reserved = Envelope(
            channel: ChannelId(rawValue: 6),
            seq: ChannelSeq(rawValue: 65535),
            frame: FrameNumber(rawValue: 1),
            timestamp: 0,
            fec: 0
        )
        let line = SniffFormat.line(datagram: try reserved.encode())
        XCTAssertTrue(line.hasPrefix("chan=6(reserved) seq=65535 "), line)
    }

    func testMalformedDatagramFormatsAsErrorLine() {
        // Truncated (below the 24 B envelope) and hostile fec bytes must
        // both come out as text — a sniffer never dies on wire garbage.
        let truncated = SniffFormat.line(datagram: [UInt8](repeating: 0, count: 5))
        XCTAssertTrue(truncated.hasPrefix("malformed len=5B"), truncated)

        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[0] = 2 // video-active
        bytes[19] = 0x7F // unknown fec scheme
        let line = SniffFormat.line(datagram: bytes)
        XCTAssertTrue(line.contains("fec=malformed("), line)
    }

    func testRealPacketizerShardFormats() throws {
        // A shard straight out of the real packetizer dissects cleanly.
        var packetizer = VideoPacketizer(firstSeq: ChannelSeq(rawValue: 9))
        // 4 NAL-ish bytes won't pass the frame-shape check; use a tiny
        // valid frame instead: a start code + TRAIL_R-typed NAL header.
        let frame: [UInt8] = [0, 0, 0, 1, 0x02, 0x01, 0xAF, 0x00, 0x11]
        let shards = try packetizer.packetize(
            frame: frame,
            frameNumber: FrameNumber(rawValue: 3),
            captureTimestamp: HostTimestamp(microseconds: 777),
            isIDR: false,
            regime: .clean
        )
        for (index, shard) in shards.enumerated() {
            let line = SniffFormat.line(datagram: try shard.encodeDatagram())
            XCTAssertTrue(line.contains("chan=2(video-active)"), line)
            XCTAssertTrue(line.contains("ts=777us"), line)
            XCTAssertTrue(line.contains("idx=\(index)/"), line)
        }
    }
}
