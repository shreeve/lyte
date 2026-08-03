import XCTest
@testable import LyteCore

private func nal(
    _ type: UInt8,
    firstSlice: Bool = true,
    fourByte: Bool = true,
    payload: [UInt8] = [0xAA, 0xBB]
) -> [UInt8] {
    var out: [UInt8] = fourByte ? [0, 0, 0, 1] : [0, 0, 1]
    out += [type << 1, 0x01, firstSlice ? 0x80 : 0x00]
    out += payload
    return out
}

private struct AnnexBRng: RandomNumberGenerator {
    var state: UInt64 = 0xA66E_0B01

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

final class AnnexBTests: XCTestCase {
    private func referenceNalUnits(in data: ArraySlice<UInt8>) -> [HevcNalUnit] {
        let base = data.startIndex
        var payloadStarts: [Int] = []
        var i = base
        while i + 2 < data.endIndex {
            if data[i + 2] > 1 {
                i += 3
            } else if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                payloadStarts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }

        var units: [HevcNalUnit] = []
        for (index, start) in payloadStarts.enumerated() {
            var end = index + 1 < payloadStarts.count
                ? payloadStarts[index + 1] - 3
                : data.endIndex
            if index + 1 < payloadStarts.count,
               end > start,
               data[end - 1] == 0 {
                end -= 1
            }
            let length = end - start
            if length >= 2 {
                units.append(HevcNalUnit(
                    offset: start - base,
                    length: length,
                    type: (data[start] >> 1) & 0x3F
                ))
            }
        }
        return units
    }

    func testWalksThreeAndFourByteStartCodesWithBlobRelativeOffsets() {
        let stream: [UInt8] = [
            0, 0, 0, 1, 0x40, 0x01, 0xAA,
            0, 0, 1, 0x42, 0x01, 0xBB, 0xCC,
            0, 0, 0, 1, 0x26, 0x01, 0xDD,
        ]
        XCTAssertEqual(AnnexBCheck.nalUnits(in: stream), [
            HevcNalUnit(offset: 4, length: 3, type: 32),
            HevcNalUnit(offset: 10, length: 4, type: 33),
            HevcNalUnit(offset: 18, length: 3, type: 19),
        ])

        let padded = [UInt8(0xFF), 0xFF] + [0, 0, 1, 0x02, 0x01, 0x99]
        XCTAssertEqual(
            AnnexBCheck.nalUnits(in: padded[2...]),
            [HevcNalUnit(offset: 3, length: 3, type: 1)]
        )
    }

    func testMalformedPrefixShortUnitsAndEmulationPrevention() {
        let shortThenTrail: [UInt8] = [0x11, 0x22, 0, 0, 1, 0x50]
            + [0, 0, 1, 0x02, 0x01, 0x33]
        XCTAssertEqual(AnnexBCheck.nalUnits(in: shortThenTrail).map(\.type), [1])
        XCTAssertEqual(AnnexBCheck.nalUnits(in: [] as [UInt8]), [])
        XCTAssertEqual(AnnexBCheck.nalUnits(in: [0, 0, 1]), [])

        let epbPayload: [UInt8] = [0x26, 0x01, 0, 0, 3, 1, 0xFF]
        let units = AnnexBCheck.nalUnits(in: [0, 0, 0, 1] + epbPayload)
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].length, epbPayload.count)
    }

    func testStartCodeAndClassificationSemantics() {
        XCTAssertNil(AnnexBCheck.leadingStartCodeLength([0, 0, 1][...]))
        XCTAssertEqual(AnnexBCheck.leadingStartCodeLength([0, 0, 1, 0x40][...]), 3)
        XCTAssertEqual(AnnexBCheck.leadingStartCodeLength([0, 0, 0, 1, 0x40][...]), 4)

        let trail: [UInt8] = [0, 0, 1, 0x02, 0x01, 0x10]
        let cra: [UInt8] = [0, 0, 0, 1, 0x2A, 0x01, 0x10]
        let cases: [([UInt8], Bool, Bool)] = [
            ([], false, false),
            (trail, true, false),
            (cra, true, true),
            ([0xFF] + cra, false, true),
            ([0, 0, 1, 0x26], false, false),
            ([0, 0, 0, 1, 0x40, 0x01, 0x0C], false, false),
        ]
        for (bytes, shaped, irap) in cases {
            XCTAssertEqual(AnnexBCheck.classifyFrame(bytes), AnnexBFrameClassification(
                isFrameShaped: shaped,
                containsIrap: irap
            ))
        }
    }

    func testWalkerMatchesReferenceOnSeededMalformedCorpus() {
        var rng = AnnexBRng()
        for trial in 0..<500 {
            let count = Int.random(in: 0...256, using: &rng)
            let body = (0..<count).map { _ in UInt8.random(in: 0...7, using: &rng) }
            let padded = [UInt8(0xAA), 0xBB] + body + [0xCC]
            let slice = padded[2..<(2 + count)]
            let expected = referenceNalUnits(in: slice)
            XCTAssertEqual(AnnexBCheck.nalUnits(in: slice), expected, "trial \(trial)")
            XCTAssertEqual(
                AnnexBCheck.classifyFrame(slice),
                AnnexBFrameClassification(
                    isFrameShaped: AnnexBCheck.leadingStartCodeLength(slice) != nil
                        && expected.contains { HevcNalType.isVcl($0.type) },
                    containsIrap: expected.contains { HevcNalType.isIrap($0.type) }
                ),
                "trial \(trial)"
            )
        }
    }

    func testHostBootstrapAndSummarySemantics() {
        let good = nal(HevcNalType.vps) + nal(HevcNalType.sps)
            + nal(HevcNalType.pps) + nal(HevcNalType.idrWRadl)
        XCTAssertTrue(AnnexBCheck.startsWithParameterSetsAndIrap(good))
        XCTAssertFalse(AnnexBCheck.startsWithParameterSetsAndIrap(
            nal(HevcNalType.vps) + nal(HevcNalType.sps)
                + nal(HevcNalType.pps) + nal(HevcNalType.trailR)
        ))
        XCTAssertEqual(
            AnnexBCheck.summary(of: good),
            "VPS SPS PPS IDR_W_RADL"
        )
        XCTAssertTrue(HevcNalType.isIdr(HevcNalType.idrWRadl))
        XCTAssertTrue(HevcNalType.isIrap(HevcNalType.craNut))
        XCTAssertFalse(HevcNalType.isIrap(HevcNalType.vps))
    }

    func testAccessUnitSplittingPreservesEveryOldBoundaryRule() {
        let au0 = nal(HevcNalType.vps) + nal(HevcNalType.sps)
            + nal(HevcNalType.pps) + nal(HevcNalType.idrWRadl)
        let au1 = nal(HevcNalType.trailR)
        let au2 = nal(HevcNalType.trailN)
        let stream = au0 + au1 + au2
        let ranges = AnnexBAccessUnits.ranges(in: stream)
        XCTAssertEqual(ranges.map { Array(stream[$0]) }, [au0, au1, au2])
        XCTAssertTrue(ranges.allSatisfy {
            AnnexBCheck.isFrameShaped(Array(stream[$0]))
        })

        let multiSlice = nal(HevcNalType.idrWRadl)
            + nal(HevcNalType.idrWRadl, firstSlice: false)
        let next = nal(HevcNalType.trailR)
        let multiRanges = AnnexBAccessUnits.ranges(in: multiSlice + next)
        XCTAssertEqual(multiRanges.count, 2)
        XCTAssertEqual(Array((multiSlice + next)[multiRanges[0]]), multiSlice)
    }

    func testAccessUnitPrefixSuffixAndMalformedBoundarySemantics() {
        let au0 = nal(HevcNalType.idrWRadl) + nal(HevcNalType.suffixSei)
        let au1 = nal(HevcNalType.sps) + nal(HevcNalType.pps)
            + nal(HevcNalType.prefixSei) + nal(HevcNalType.trailR)
        let stream = au0 + au1
        let ranges = AnnexBAccessUnits.ranges(in: stream)
        XCTAssertEqual(ranges.map { Array(stream[$0]) }, [au0, au1])

        let garbage: [UInt8] = [0xDE, 0xAD]
        let three0 = nal(HevcNalType.idrWRadl, fourByte: false)
        let three1 = nal(HevcNalType.trailR, fourByte: false)
        let malformed = garbage + three0 + three1
        let malformedRanges = AnnexBAccessUnits.ranges(in: malformed)
        XCTAssertEqual(malformedRanges.map { Array(malformed[$0]) }, [three0, three1])
        XCTAssertEqual(AnnexBAccessUnits.ranges(in: nal(HevcNalType.vps)), [])
        XCTAssertEqual(AnnexBAccessUnits.ranges(in: []), [])
    }
}
