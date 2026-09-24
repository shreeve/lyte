import LyteIO
import XCTest

final class CBufferTests: XCTestCase {
    private func buffer(_ bytes: [UInt8]) -> [CChar] {
        bytes.map { CChar(bitPattern: $0) }
    }

    func testStopsAtTheFirstNul() {
        let buf = buffer(Array("no sink".utf8) + [0] + Array("stale".utf8))
        XCTAssertEqual(String(cBuffer: buf), "no sink")
    }

    func testUnterminatedBufferDecodesWhole() {
        XCTAssertEqual(String(cBuffer: buffer(Array("full".utf8))), "full")
    }

    func testEmptyAndLeadingNulDecodeEmpty() {
        XCTAssertEqual(String(cBuffer: []), "")
        XCTAssertEqual(String(cBuffer: buffer([0, 0x41])), "")
    }

    func testMultibyteUtf8SurvivesAndInvalidBytesAreReplaced() {
        let dash = Array("a — b".utf8)
        XCTAssertEqual(String(cBuffer: buffer(dash + [0])), "a — b")
        XCTAssertEqual(String(cBuffer: buffer([0x41, 0xFF, 0])), "A\u{FFFD}")
    }
}
