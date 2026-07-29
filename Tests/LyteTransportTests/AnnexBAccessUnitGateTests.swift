import XCTest
import LyteTransport
import LyteWire

// THE V-2 GATE (H4 plan: the file-in seam of the §7 harness's client
// half). AnnexBAccessUnits must cut an Annex-B elementary stream into
// frame-shaped access units — the hevc_nvenc low-delay shape (parameter
// sets + IDR, then P slices), multi-slice pictures, prefix-NAL
// attribution, and start-code variants — because every offline harness
// leg replays files through DecodeUnit/VideoRenderFactory via exactly
// these ranges.

final class AnnexBAccessUnitGateTests: XCTestCase {

    /// A NAL with the given type, first-slice flag (bit 7 of the byte
    /// after the 2-byte header), and a 4- or 3-byte start code.
    private func nal(
        _ type: UInt8, firstSlice: Bool = true, fourByte: Bool = true,
        payload: [UInt8] = [0xAA, 0xBB]
    ) -> [UInt8] {
        var out: [UInt8] = fourByte ? [0, 0, 0, 1] : [0, 0, 1]
        out += [type << 1, 0x01]
        out += [firstSlice ? 0x80 : 0x00]
        out += payload
        return out
    }

    func testNvencLowDelayShape() {
        // [VPS SPS PPS IDR] [P] [P] — the V-1 bitstream shape.
        let au0 = nal(HevcNalType.vps) + nal(HevcNalType.sps)
            + nal(HevcNalType.pps) + nal(HevcNalType.idrWRadl)
        let au1 = nal(HevcNalType.trailR)
        let au2 = nal(HevcNalType.trailN)
        let stream = au0 + au1 + au2

        let ranges = AnnexBAccessUnits.ranges(in: stream)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(Array(stream[ranges[0]]), au0)
        XCTAssertEqual(Array(stream[ranges[1]]), au1)
        XCTAssertEqual(Array(stream[ranges[2]]), au2)
        // Every cut is frame-shaped — DecodeUnit-ready as-is.
        for range in ranges {
            XCTAssertTrue(AnnexBCheck.isFrameShaped(Array(stream[range])))
        }
        XCTAssertTrue(AnnexBCheck.containsIrap(Array(stream[ranges[0]])))
        XCTAssertFalse(AnnexBCheck.containsIrap(Array(stream[ranges[1]])))
    }

    func testMultiSlicePictureStaysOneUnit() {
        // Two slices of one picture (second has first_slice flag 0),
        // then the next picture — 2 units, not 3.
        let au0 = nal(HevcNalType.idrWRadl)
            + nal(HevcNalType.idrWRadl, firstSlice: false)
        let au1 = nal(HevcNalType.trailR)
        let stream = au0 + au1

        let ranges = AnnexBAccessUnits.ranges(in: stream)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(Array(stream[ranges[0]]), au0)
        XCTAssertEqual(Array(stream[ranges[1]]), au1)
    }

    func testPrefixNalsAttachForward() {
        // Mid-stream parameter sets + prefix SEI belong to the NEXT
        // picture (the in-band refresh the factory rebuilds from);
        // suffix SEI stays with the picture it follows.
        let au0 = nal(HevcNalType.idrWRadl) + nal(HevcNalType.suffixSei)
        let au1 = nal(HevcNalType.sps) + nal(HevcNalType.pps)
            + nal(HevcNalType.prefixSei) + nal(HevcNalType.trailR)
        let stream = au0 + au1

        let ranges = AnnexBAccessUnits.ranges(in: stream)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(Array(stream[ranges[0]]), au0)
        XCTAssertEqual(Array(stream[ranges[1]]), au1)
    }

    func testThreeByteStartCodesAndGarbagePrefix() {
        // 3-byte start codes cut identically, and bytes before the
        // first start code belong to no unit.
        let garbage: [UInt8] = [0xDE, 0xAD]
        let au0 = nal(HevcNalType.idrWRadl, fourByte: false)
        let au1 = nal(HevcNalType.trailR, fourByte: false)
        let stream = garbage + au0 + au1

        let ranges = AnnexBAccessUnits.ranges(in: stream)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(Array(stream[ranges[0]]), au0)
        XCTAssertEqual(Array(stream[ranges[1]]), au1)
    }

    func testNoVclMeansNoUnits() {
        let stream = nal(HevcNalType.vps) + nal(HevcNalType.sps)
        XCTAssertEqual(AnnexBAccessUnits.ranges(in: stream), [])
        XCTAssertEqual(AnnexBAccessUnits.ranges(in: []), [])
    }
}
