import XCTest
import LyteWire

// The anchor value below was computed by hand from the layout comment in
// FecField.swift, not by running the codec — same circularity-breaking
// rule as EnvelopeTests' anchor bytes. Decode rejects and the leniency
// rules live in fec-v1.json's field vectors.

final class FecFieldTests: XCTestCase {

    private func nominalGeometry() throws -> FecGeometry {
        try FecGeometry(dataShards: 4, parityShards: 2, groupByteCount: 4000)
    }

    // byte 0 shardIndex=0x05, byte 1 k=0x04, byte 2 m=0x02,
    // byte 3 scheme=0x01, bytes 4–6 groupByteCount=4000=0x000FA0,
    // byte 7 reserved=0 — as a LE u64: 0x0000_0FA0_0102_0405.
    private let anchorRaw: UInt64 = 0x0000_0FA0_0102_0405

    func testAnchor() throws {
        let field = try FecField.reedSolomonShard(5, of: nominalGeometry())
        XCTAssertEqual(field.encoded, anchorRaw)
        XCTAssertEqual(try FecField.decode(anchorRaw), field)
    }

    func testAnchorBytesInsideEnvelope() throws {
        // The u64 rides the envelope little-endian at offset 16: the two
        // layers must agree on the wire bytes.
        let envelope = Envelope(
            channel: .videoActive,
            seq: ChannelSeq(rawValue: 1),
            frame: FrameNumber(rawValue: 1),
            timestamp: 0,
            fec: anchorRaw
        )
        let datagram = try envelope.encode()
        XCTAssertEqual(
            Array(datagram[16..<24]),
            [0x05, 0x04, 0x02, 0x01, 0xA0, 0x0F, 0x00, 0x00]
        )
        let (decoded, _) = try Envelope.decode(datagram)
        XCTAssertEqual(
            try FecField.decode(decoded.fec),
            .reedSolomon(shardIndex: 5, geometry: try nominalGeometry())
        )
    }

    func testShardConstructionRefusesIndexPastGeometry() throws {
        // 0…5 valid for k=4 m=2; 6 is out.
        assertThrows(FecError.shardIndexOutOfRange(6)) {
            try FecField.reedSolomonShard(6, of: nominalGeometry())
        }
    }
}
