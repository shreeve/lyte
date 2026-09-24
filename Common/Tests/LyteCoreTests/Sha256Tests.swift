import XCTest
@testable import LyteCore

final class Sha256Tests: XCTestCase {
    func testPublishedFipsKnownAnswers() {
        XCTAssertEqual(
            Sha256.digest([]),
            [0xE3, 0xB0, 0xC4, 0x42, 0x98, 0xFC, 0x1C, 0x14,
             0x9A, 0xFB, 0xF4, 0xC8, 0x99, 0x6F, 0xB9, 0x24,
             0x27, 0xAE, 0x41, 0xE4, 0x64, 0x9B, 0x93, 0x4C,
             0xA4, 0x95, 0x99, 0x1B, 0x78, 0x52, 0xB8, 0x55]
        )
        XCTAssertEqual(
            Sha256.digest(Array("abc".utf8)),
            [0xBA, 0x78, 0x16, 0xBF, 0x8F, 0x01, 0xCF, 0xEA,
             0x41, 0x41, 0x40, 0xDE, 0x5D, 0xAE, 0x22, 0x23,
             0xB0, 0x03, 0x61, 0xA3, 0x96, 0x17, 0x7A, 0x9C,
             0xB4, 0x10, 0xFF, 0x61, 0xF2, 0x00, 0x15, 0xAD]
        )
        // 448 bits: the padding no longer fits the final block.
        XCTAssertEqual(
            Sha256.digest(Array(
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            [0x24, 0x8D, 0x6A, 0x61, 0xD2, 0x06, 0x38, 0xB8,
             0xE5, 0xC0, 0x26, 0x93, 0x0C, 0x3E, 0x60, 0x39,
             0xA3, 0x3C, 0xE4, 0x59, 0x64, 0xFF, 0x21, 0x67,
             0xF6, 0xEC, 0xED, 0xD4, 0x19, 0xDB, 0x06, 0xC1]
        )
        XCTAssertEqual(
            Sha256.digest(Array(repeating: UInt8(ascii: "a"), count: 1_000_000)),
            [0xCD, 0xC7, 0x6E, 0x5C, 0x99, 0x14, 0xFB, 0x92,
             0x81, 0xA1, 0xC7, 0xE2, 0x84, 0xD7, 0x3E, 0x67,
             0xF1, 0x80, 0x9A, 0x48, 0xA4, 0x97, 0x20, 0x0E,
             0x04, 0x6D, 0x39, 0xCC, 0xC7, 0x11, 0x2C, 0xD0]
        )
    }

    func testEveryBlockEdgeStreamsLikeThePublishedOneShotModel() {
        var state: UInt64 = 0x5348_4132_3536_5354
        var payload: [UInt8] = []
        for _ in 0..<200_001 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            payload.append(UInt8(truncatingIfNeeded: state >> 24))
        }
        let expected = Sha256.digest(payload)

        for chunkSize in [1, 2, 3, 31, 55, 56, 63, 64, 65, 127, 128,
                          129, 4_096, 131_072, 200_001] {
            var stream = Sha256()
            for start in stride(from: 0, to: payload.count, by: chunkSize) {
                stream.update(payload[start..<min(start + chunkSize, payload.count)])
            }
            XCTAssertEqual(stream.finalized(), expected, "chunk size \(chunkSize)")
        }
    }

    func testNonContiguousInputHashesLikeItsBytes() {
        let bytes = (0..<1_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let lazyBytes = (0..<bytes.count).lazy.map { bytes[$0] }
        XCTAssertEqual(Sha256.digest(lazyBytes), Sha256.digest(bytes))
    }
}
