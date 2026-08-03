import XCTest
import LyteWire

// The anchor value below was computed by hand from the layout comment in
// FecField.swift, not by running the codec — same circularity-breaking
// rule as EnvelopeTests' anchor bytes.

final class FecFieldTests: XCTestCase {

    private func nominalGeometry() throws -> FecGeometry {
        try FecGeometry(dataShards: 4, parityShards: 2, groupByteCount: 4000)
    }

    // byte 0 shardIndex=0x05, byte 1 k=0x04, byte 2 m=0x02,
    // byte 3 scheme=0x01, bytes 4–6 groupByteCount=4000=0x000FA0,
    // byte 7 reserved=0 — as a LE u64: 0x0000_0FA0_0102_0405.
    private let anchorRaw: UInt64 = 0x0000_0FA0_0102_0405

    func testAnchorEncode() throws {
        let field = try FecField.reedSolomonShard(5, of: nominalGeometry())
        XCTAssertEqual(field.encoded, anchorRaw)
    }

    func testAnchorDecode() throws {
        let field = try FecField.decode(anchorRaw)
        XCTAssertEqual(
            field,
            .reedSolomon(shardIndex: 5, geometry: try nominalGeometry())
        )
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

    func testNoneIsAllZero() throws {
        XCTAssertEqual(FecField.none.encoded, 0)
        XCTAssertEqual(try FecField.decode(0), .none)
    }

    func testNoneWithGeometryBytesRejected() {
        // Any non-zero bit in bytes 0–6 under scheme none is malformed.
        for raw: UInt64 in [0x01, 0x0100, 0x0001_0000, 0x0001_0000_0000] {
            XCTAssertThrowsError(try FecField.decode(raw)) {
                XCTAssertEqual($0 as? FecError, .nonZeroNoneField)
            }
        }
    }

    func testReservedByteIgnoredOnDecode() throws {
        XCTAssertEqual(
            try FecField.decode(anchorRaw | 0xFF00_0000_0000_0000),
            try FecField.decode(anchorRaw)
        )
        XCTAssertEqual(try FecField.decode(0xAB00_0000_0000_0000), .none)
    }

    func testUnknownSchemesRejected() {
        for scheme: UInt64 in [0x02, 0x7F, 0xFF] {
            XCTAssertThrowsError(try FecField.decode(scheme << 24)) {
                XCTAssertEqual(
                    $0 as? FecError, .unknownScheme(UInt8(scheme))
                )
            }
        }
    }

    func testShardIndexBounds() throws {
        let geometry = try nominalGeometry()
        // 0…5 valid for k=4 m=2; 6 is out.
        for index in 0..<geometry.totalShards {
            XCTAssertNoThrow(try FecField.reedSolomonShard(index, of: geometry))
            let raw = try FecField.reedSolomonShard(index, of: geometry).encoded
            XCTAssertNoThrow(try FecField.decode(raw))
        }
        XCTAssertThrowsError(
            try FecField.reedSolomonShard(6, of: geometry)
        ) {
            XCTAssertEqual($0 as? FecError, .shardIndexOutOfRange(6))
        }
        XCTAssertThrowsError(try FecField.decode(anchorRaw + 1)) {
            XCTAssertEqual($0 as? FecError, .shardIndexOutOfRange(6))
        }
    }

    func testGeometryRejectsSurfaceThroughDecode() {
        // k=0
        XCTAssertThrowsError(try FecField.decode(0x0000_0064_0102_0000)) {
            XCTAssertEqual($0 as? FecError, .dataShardsOutOfRange(0))
        }
        // k=200 m=60: 260 shards over the GF(2^8) block.
        XCTAssertThrowsError(try FecField.decode(0x0003_0D40_013C_C800)) {
            XCTAssertEqual($0 as? FecError, .parityShardsOutOfRange(60))
        }
        // k=1 over 1113 B.
        XCTAssertThrowsError(try FecField.decode(0x0000_0459_0101_0100)) {
            XCTAssertEqual($0 as? FecError, .groupByteCountOutOfRange(1113))
        }
        // Zero group bytes.
        XCTAssertThrowsError(try FecField.decode(0x0000_0000_0101_0100)) {
            XCTAssertEqual($0 as? FecError, .groupByteCountOutOfRange(0))
        }
        // k=4 over 5 B: trailing shard would be empty.
        XCTAssertThrowsError(try FecField.decode(0x0000_0005_0102_0400)) {
            XCTAssertEqual(
                $0 as? FecError,
                .overProvisionedDataShards(dataShards: 4, groupByteCount: 5)
            )
        }
    }
}
