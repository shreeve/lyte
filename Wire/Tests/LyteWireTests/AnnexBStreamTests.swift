import XCTest
import LyteWireTestKit

// TestKit's corpus splitter intentionally keeps its authoring semantics:
// exact whole-stream coverage, including any prefix bytes. The production
// first-slice splitter is pinned beside the one walker in LyteCore.
final class AnnexBStreamTests: XCTestCase {
    func testAccessUnitSplitMatchesTheHostStreamShape() {
        func nal(_ headerByte: UInt8, _ length: Int) -> [UInt8] {
            [0, 0, 0, 1, headerByte, 0x01]
                + Array(repeating: 0x77, count: length)
        }
        let au0 = nal(0x40, 2) + nal(0x42, 3) + nal(0x44, 1)
            + nal(0x4E, 2) + nal(0x26, 9)
        let au1 = nal(0x4E, 2) + nal(0x02, 7)
        let au2 = nal(0x4E, 2) + nal(0x02, 5)
        let stream = au0 + au1 + au2

        let ranges = AnnexBStream.accessUnitRanges(in: stream)
        XCTAssertEqual(ranges.map { Array(stream[$0]) }, [au0, au1, au2])
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, stream.count)
        for (left, right) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(left.upperBound, right.lowerBound)
        }
    }

    func testAccessUnitSplitWithThreeByteStartCodes() {
        func nal(_ headerByte: UInt8, _ length: Int) -> [UInt8] {
            [0, 0, 1, headerByte, 0x01]
                + Array(repeating: 0x55, count: length)
        }
        let au0 = nal(0x26, 4)
        let au1 = nal(0x02, 4)
        let ranges = AnnexBStream.accessUnitRanges(in: au0 + au1)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(Array((au0 + au1)[ranges[1]]), au1)
    }

    func testSha256KnownAnswers() {
        XCTAssertEqual(
            Sha256.hex([]),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            Sha256.hex(Array("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            Sha256.hex(Array(
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8
            )),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }
}
