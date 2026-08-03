import XCTest
@testable import LyteCore

final class HevcBitsTests: XCTestCase {
    func testExpGolombAnchorsAndSignedInverse() {
        var writer = HevcBitWriter()
        writer.ue(0); writer.ue(1); writer.ue(2); writer.ue(3); writer.ue(4)
        writer.rbspTrailingBits()
        XCTAssertEqual(Array(writer.rbsp.prefix(2)), [0b1010_0110, 0b0100_0010])

        var signed = HevcBitWriter()
        let values: [Int32] = [-100, -2, -1, 0, 1, 2, 100]
        for value in values { signed.se(value) }
        var reader = HevcBitReader(rbsp: signed.rbsp)
        XCTAssertEqual(values.compactMap { _ in reader.readSe() }, values)
    }

    func testEmulationPreventionAnchors() {
        XCTAssertEqual(HevcRbsp.escaped([0, 0, 0]), [0, 0, 3, 0])
        XCTAssertEqual(HevcRbsp.escaped([0, 0, 1]), [0, 0, 3, 1])
        XCTAssertEqual(HevcRbsp.escaped([0, 0, 4]), [0, 0, 4])
        XCTAssertEqual(
            HevcRbsp.escaped([0, 0, 0, 0, 2]),
            [0, 0, 3, 0, 0, 3, 2]
        )
        XCTAssertEqual(
            HevcBitWriter.nal(type: 33, rbsp: [0, 0, 2, 0, 2]),
            [0x42, 0x01, 0, 0, 3, 2, 0, 2]
        )
    }

    func testEscapeAndUnescapeAreInverseAcrossSeededByteCorpus() {
        var state: UInt64 = 0x4845_5643_5242_5350
        for length in 0...512 {
            var bytes: [UInt8] = []
            for _ in 0..<length {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                bytes.append(UInt8(truncatingIfNeeded: state >> 24))
            }
            if length > 6 {
                bytes[1...6] = [0, 0, 0, 0, 2, 3]
            }
            XCTAssertEqual(HevcRbsp.unescaped(HevcRbsp.escaped(bytes)), bytes)
        }
    }

    func testFixedWidthAndGolombRoundTrip() {
        var writer = HevcBitWriter()
        writer.u(0b10101, 5)
        let values: [UInt32] = [0, 1, 2, 3, 4, 31, 255, 65_535]
        for value in values { writer.ue(value) }
        var reader = HevcBitReader(rbsp: writer.rbsp)
        XCTAssertEqual(reader.read(bits: 5), 0b10101)
        XCTAssertEqual(values.compactMap { _ in reader.readUe() }, values)
    }

    func testHostileReadsFailWithoutAdvancingPastStorage() {
        var reader = HevcBitReader(rbsp: [0])
        XCTAssertNil(reader.read(bits: -1))
        XCTAssertNil(reader.read(bits: 33))
        XCTAssertNil(reader.readUe())
        XCTAssertFalse(reader.skip(bits: 1))

        XCTAssertEqual(HevcRbsp.unescaped([0, 0, 3]), [0, 0, 3])
        XCTAssertEqual(HevcRbsp.unescaped([0, 0, 3, 4]), [0, 0, 3, 4])
    }
}
