import XCTest
import LyteWire
import LyteWireTestKit

// The NAL-walking core copy-adapted from the frozen client depacketizer —
// verified against hand-laid-out byte streams, since every video-interior
// guarantee (frame-shape checks, corpus splitting) stands on this walk.

final class AnnexBCheckTests: XCTestCase {

    // MARK: - NAL walking

    func testWalksThreeAndFourByteStartCodes() {
        // 4-byte start + VPS, 3-byte start + SPS, 4-byte start + IDR.
        let stream: [UInt8] = [
            0, 0, 0, 1, 0x40, 0x01, 0xAA,       // VPS (type 32)
            0, 0, 1, 0x42, 0x01, 0xBB, 0xCC,    // SPS (type 33)
            0, 0, 0, 1, 0x26, 0x01, 0xDD,       // IDR_W_RADL (type 19)
        ]
        let units = AnnexBCheck.nalUnits(in: stream)
        XCTAssertEqual(units.count, 3)
        XCTAssertEqual(units[0], HevcNalUnit(offset: 4, length: 3, type: 32))
        // The 4-byte start code's leading zero is not part of SPS's payload.
        XCTAssertEqual(units[1], HevcNalUnit(offset: 10, length: 4, type: 33))
        XCTAssertEqual(units[2], HevcNalUnit(offset: 18, length: 3, type: 19))
    }

    func testOffsetsAreBlobRelativeOnSlices() {
        let padded: [UInt8] = [0xFF, 0xFF] + [0, 0, 1, 0x02, 0x01, 0x99]
        let units = AnnexBCheck.nalUnits(in: padded[2...])
        XCTAssertEqual(units, [HevcNalUnit(offset: 3, length: 3, type: 1)])
    }

    func testIgnoresBytesBeforeFirstStartCodeAndShortUnits() {
        // Garbage prefix, then a 1-byte unit (dropped), then a real one.
        let stream: [UInt8] = [0x11, 0x22]
            + [0, 0, 1, 0x50]                    // 1 byte: under the NAL header
            + [0, 0, 1, 0x02, 0x01, 0x33]        // TRAIL_R
        let units = AnnexBCheck.nalUnits(in: stream)
        XCTAssertEqual(units.map(\.type), [1])
    }

    func testEmptyAndTinyInputs() {
        XCTAssertEqual(AnnexBCheck.nalUnits(in: [] as [UInt8]), [])
        XCTAssertEqual(AnnexBCheck.nalUnits(in: [0, 0, 1]), [])
        XCTAssertNil(AnnexBCheck.leadingStartCodeLength([0, 0, 1][...]))
        XCTAssertEqual(AnnexBCheck.leadingStartCodeLength([0, 0, 1, 0x40][...]), 3)
        XCTAssertEqual(AnnexBCheck.leadingStartCodeLength([0, 0, 0, 1, 0x40][...]), 4)
        XCTAssertNil(AnnexBCheck.leadingStartCodeLength([0, 1, 0, 1, 0x40][...]))
    }

    // MARK: - Frame-shape integrity

    func testFrameShapedRequiresLeadingStartCodeAndVcl() {
        let vclFrame: [UInt8] = [0, 0, 0, 1, 0x02, 0x01, 0x10, 0x20]
        XCTAssertTrue(AnnexBCheck.isFrameShaped(vclFrame))

        // Parameter sets alone are not a frame.
        let noVcl: [UInt8] = [0, 0, 0, 1, 0x40, 0x01, 0x0C]
        XCTAssertFalse(AnnexBCheck.isFrameShaped(noVcl))

        // Bytes before the first start code disqualify the blob.
        XCTAssertFalse(AnnexBCheck.isFrameShaped([0xFF] + vclFrame))
        XCTAssertFalse(AnnexBCheck.isFrameShaped([] as [UInt8]))
    }

    func testContainsIrapDistinguishesIdrFromTrail() {
        let idr: [UInt8] = [0, 0, 0, 1, 0x26, 0x01, 0x10]   // IDR_W_RADL
        let cra: [UInt8] = [0, 0, 0, 1, 0x2A, 0x01, 0x10]   // CRA_NUT (21)
        let trail: [UInt8] = [0, 0, 0, 1, 0x02, 0x01, 0x10] // TRAIL_R
        XCTAssertTrue(AnnexBCheck.containsIrap(idr))
        XCTAssertTrue(AnnexBCheck.containsIrap(cra))
        XCTAssertFalse(AnnexBCheck.containsIrap(trail))
        XCTAssertTrue(HevcNalType.isIdr(19))
        XCTAssertTrue(HevcNalType.isIdr(20))
        XCTAssertFalse(HevcNalType.isIdr(21))
        XCTAssertTrue(HevcNalType.isIrap(21))
    }

    func testSummaryNamesTheCorpusShape() {
        let stream: [UInt8] =
            [0, 0, 0, 1, 0x40, 0x01, 0]          // VPS
            + [0, 0, 0, 1, 0x42, 0x01, 0]        // SPS
            + [0, 0, 0, 1, 0x44, 0x01, 0]        // PPS
            + [0, 0, 0, 1, 0x4E, 0x01, 0]        // prefix SEI (39)
            + [0, 0, 0, 1, 0x26, 0x01, 0]        // IDR
        XCTAssertEqual(
            AnnexBCheck.summary(of: stream), "VPS SPS PPS PREFIX_SEI IDR_W_RADL"
        )
    }

    // MARK: - Access-unit splitting (TestKit corpus tooling)

    func testAccessUnitSplitMatchesTheHostStreamShape() {
        // The corpus shape: [VPS SPS PPS SEI IDR] [SEI P] [SEI P].
        func nal(_ headerByte: UInt8, _ len: Int) -> [UInt8] {
            [0, 0, 0, 1, headerByte, 0x01] + Array(repeating: 0x77, count: len)
        }
        let au0 = nal(0x40, 2) + nal(0x42, 3) + nal(0x44, 1) + nal(0x4E, 2) + nal(0x26, 9)
        let au1 = nal(0x4E, 2) + nal(0x02, 7)
        let au2 = nal(0x4E, 2) + nal(0x02, 5)
        let stream = au0 + au1 + au2

        let ranges = AnnexBStream.accessUnitRanges(in: stream)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(Array(stream[ranges[0]]), au0)
        XCTAssertEqual(Array(stream[ranges[1]]), au1)
        XCTAssertEqual(Array(stream[ranges[2]]), au2)
        // Coverage is exact and contiguous — concatenation is identity.
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, stream.count)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(a.upperBound, b.lowerBound)
        }
    }

    func testAccessUnitSplitWithThreeByteStartCodes() {
        func nal(_ headerByte: UInt8, _ len: Int) -> [UInt8] {
            [0, 0, 1, headerByte, 0x01] + Array(repeating: 0x55, count: len)
        }
        let au0 = nal(0x26, 4)
        let au1 = nal(0x02, 4)
        let ranges = AnnexBStream.accessUnitRanges(in: au0 + au1)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(Array((au0 + au1)[ranges[1]]), au1)
    }

    func testSha256KnownAnswers() {
        // FIPS 180-4 published digests — the TestKit hash never grades
        // its own homework.
        XCTAssertEqual(
            Sha256.hex([]),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            Sha256.hex(Array("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        // A two-block message (>55 bytes) exercises the padding path.
        XCTAssertEqual(
            Sha256.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }
}
