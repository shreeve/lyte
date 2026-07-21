import XCTest
@testable import HostCore

// Builds a NAL payload with the HEVC 2-byte header for a given type.
private func nal(_ type: UInt8, payload: [UInt8] = [0x01]) -> [UInt8] {
    [(type << 1), 0x01] + payload
}

private let sc3: [UInt8] = [0x00, 0x00, 0x01]
private let sc4: [UInt8] = [0x00, 0x00, 0x00, 0x01]

final class AnnexBTests: XCTestCase {

    func testSplitsThreeByteStartCodes() {
        let stream = sc3 + nal(HevcNal.vps) + sc3 + nal(HevcNal.sps) + sc3 + nal(HevcNal.pps)
        let units = AnnexB.nalUnits(in: stream)
        XCTAssertEqual(units.map(\.type), [HevcNal.vps, HevcNal.sps, HevcNal.pps])
    }

    func testSplitsFourByteStartCodes() {
        let stream = sc4 + nal(HevcNal.vps) + sc4 + nal(HevcNal.idrWRadl)
        let units = AnnexB.nalUnits(in: stream)
        XCTAssertEqual(units.map(\.type), [HevcNal.vps, HevcNal.idrWRadl])
        // The 4-byte code's leading zero must not be counted in the previous payload.
        XCTAssertEqual(units[0].length, 3)
    }

    func testMixedStartCodes() {
        let stream = sc4 + nal(HevcNal.vps) + sc3 + nal(HevcNal.sps) + sc4 + nal(HevcNal.pps)
        let units = AnnexB.nalUnits(in: stream)
        XCTAssertEqual(units.map(\.type), [HevcNal.vps, HevcNal.sps, HevcNal.pps])
        XCTAssertEqual(units.map(\.length), [3, 3, 3])
    }

    func testOffsetsAndLengths() {
        let payload: [UInt8] = [0x40, 0x01, 0xAA, 0xBB, 0xCC]  // VPS header + 3 bytes
        let stream = sc4 + payload
        let units = AnnexB.nalUnits(in: stream)
        XCTAssertEqual(units, [NalUnit(offset: 4, length: 5, type: HevcNal.vps)])
    }

    func testGarbageBeforeFirstStartCodeIsIgnored() {
        let stream: [UInt8] = [0xDE, 0xAD] + sc3 + nal(HevcNal.trailR)
        let units = AnnexB.nalUnits(in: stream)
        XCTAssertEqual(units.map(\.type), [HevcNal.trailR])
    }

    func testEmptyAndTinyInputs() {
        XCTAssertEqual(AnnexB.nalUnits(in: []), [])
        XCTAssertEqual(AnnexB.nalUnits(in: [0x00, 0x00]), [])
        // A start code with a truncated (sub-header) payload yields nothing.
        XCTAssertEqual(AnnexB.nalUnits(in: sc3 + [0x40]), [])
    }

    func testEmulationPreventionBytesInPayloadDoNotSplit() {
        // 00 00 03 01 inside a payload is not a start code.
        let payload: [UInt8] = [0x26, 0x01, 0x00, 0x00, 0x03, 0x01, 0xFF]
        let stream = sc4 + payload
        let units = AnnexB.nalUnits(in: stream)
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].length, payload.count)
        XCTAssertEqual(units[0].type, HevcNal.idrWRadl)
    }

    func testIdrAndIrapClassification() {
        XCTAssertTrue(HevcNal.isIdr(HevcNal.idrWRadl))
        XCTAssertTrue(HevcNal.isIdr(HevcNal.idrNLp))
        XCTAssertFalse(HevcNal.isIdr(HevcNal.craNut))
        XCTAssertTrue(HevcNal.isIrap(HevcNal.craNut))
        XCTAssertTrue(HevcNal.isIrap(HevcNal.blaWLp))
        XCTAssertFalse(HevcNal.isIrap(HevcNal.trailR))
        XCTAssertFalse(HevcNal.isIrap(HevcNal.vps))
    }

    func testStartsWithParameterSetsAndIrap() {
        let good = sc4 + nal(HevcNal.vps) + sc4 + nal(HevcNal.sps) + sc4 + nal(HevcNal.pps)
            + sc4 + nal(HevcNal.idrWRadl)
        XCTAssertTrue(AnnexB.startsWithParameterSetsAndIrap(good))

        let noIdr = sc4 + nal(HevcNal.vps) + sc4 + nal(HevcNal.sps) + sc4 + nal(HevcNal.pps)
            + sc4 + nal(HevcNal.trailR)
        XCTAssertFalse(AnnexB.startsWithParameterSetsAndIrap(noIdr))

        let noSps = sc4 + nal(HevcNal.vps) + sc4 + nal(HevcNal.pps) + sc4 + nal(HevcNal.idrNLp)
        XCTAssertFalse(AnnexB.startsWithParameterSetsAndIrap(noSps))
    }

    func testSummary() {
        let stream = sc4 + nal(HevcNal.vps) + sc4 + nal(HevcNal.sps) + sc4 + nal(HevcNal.pps)
            + sc4 + nal(HevcNal.idrWRadl)
        XCTAssertEqual(AnnexB.summary(of: stream), "VPS SPS PPS IDR_W_RADL")
    }
}
