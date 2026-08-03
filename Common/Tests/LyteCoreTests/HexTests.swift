import XCTest
@testable import LyteCore

final class HexTests: XCTestCase {
    func testEveryByteHasCanonicalLowercaseAndExplicitUppercaseSpellings() {
        let bytes = Array(UInt8.min...UInt8.max)
        let lowercase = Hex.string(bytes)
        let uppercase = Hex.string(bytes, uppercase: true)
        XCTAssertEqual(lowercase.count, 512)
        XCTAssertEqual(uppercase.count, 512)
        XCTAssertEqual(lowercase.prefix(32), "000102030405060708090a0b0c0d0e0f")
        XCTAssertEqual(uppercase.suffix(32), "F0F1F2F3F4F5F6F7F8F9FAFBFCFDFEFF")
        XCTAssertEqual(Hex.bytes(lowercase), bytes)
        XCTAssertEqual(Hex.bytes(uppercase), bytes)
    }

    func testDecoderPreservesVectorAndCliGrammar() {
        XCTAssertEqual(Hex.bytes(" 0x00 aB\nFF "), [0x00, 0xAB, 0xFF])
        XCTAssertEqual(Hex.bytes(""), [])
        XCTAssertNil(Hex.bytes("0"))
        XCTAssertNil(Hex.bytes("0x123"))
        XCTAssertNil(Hex.bytes("0xgg"))
    }

    func testIntegerFormattingPinsWidthCasePrefixAndNoTruncation() {
        XCTAssertEqual(Hex.string(UInt8(0x0A), width: 2), "0a")
        XCTAssertEqual(
            Hex.string(UInt8(0xEF), width: 2, uppercase: true, prefix: true),
            "0xEF"
        )
        XCTAssertEqual(Hex.string(UInt64(1), width: 16), "0000000000000001")
        XCTAssertEqual(Hex.string(UInt16.max, width: 2), "ffff")
        XCTAssertEqual(Hex.uint64String(0x0102_0304_0506_0708),
                       "0x102030405060708")
        XCTAssertEqual(Hex.uint64(" 0X0102030405060708 "),
                       0x0102_0304_0506_0708)
        XCTAssertNil(Hex.uint64(""))
        XCTAssertNil(Hex.uint64("10000000000000000"))
    }
}
