import XCTest
import HostWire

// The paired-clients store format, pinned (HS-9): 64 lowercase hex
// chars per line + optional note; comments and blanks ignored; anything
// else is LOUD — a trust store is never guessed at.

final class ClientKeystoreTests: XCTestCase {

    private let keyA = [UInt8](repeating: 0xAB, count: 32)
    private let keyB: [UInt8] = (0..<32).map { UInt8($0) }

    func testRoundTripIsCanonical() throws {
        var store = ClientKeystore()
        XCTAssertTrue(store.pin(keyA, note: "paired 2026-07-22T08:00:00Z"))
        XCTAssertTrue(store.pin(keyB))
        let text = store.serialized()
        let reparsed = try ClientKeystore.parse(text)
        XCTAssertEqual(reparsed, store)
        XCTAssertEqual(reparsed.serialized(), text,
                       "serialize(parse(x)) must be canonical")
        XCTAssertEqual(reparsed.entries[0].note,
                       "paired 2026-07-22T08:00:00Z")
    }

    func testRePairingTheSameClientIsANoOp() {
        var store = ClientKeystore()
        XCTAssertTrue(store.pin(keyA, note: "first"))
        XCTAssertFalse(store.pin(keyA, note: "second"))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].note, "first",
                       "the original pairing record survives")
        XCTAssertTrue(store.contains(keyA))
        XCTAssertFalse(store.contains(keyB))
    }

    func testCommentsAndBlanksAreIgnored() throws {
        let hexA = String(repeating: "ab", count: 32)
        let text = """
        # header comment

        \(hexA) paired yesterday

        # trailing comment
        """
        let store = try ClientKeystore.parse(text)
        XCTAssertEqual(store.publicKeys, [keyA])
        XCTAssertEqual(store.entries[0].note, "paired yesterday")
    }

    func testMalformedLinesAreLoud() {
        let hexA = String(repeating: "ab", count: 32)
        let cases = [
            "tooshort",
            String(repeating: "ab", count: 31) + "zz", // non-hex tail
            String(repeating: "AB", count: 32),        // uppercase
            hexA + "extrahexglued",                    // no separator
        ]
        for bad in cases {
            XCTAssertThrowsError(
                try ClientKeystore.parse("# ok\n\(bad)\n"),
                "must reject: \(bad)"
            ) { error in
                guard case ClientKeystore.ParseError
                    .malformedLine(2, bad) = error else {
                    return XCTFail("wrong error for \(bad): \(error)")
                }
            }
        }
    }

    func testParsingDeduplicates() throws {
        let hexA = String(repeating: "ab", count: 32)
        let store = try ClientKeystore.parse("\(hexA) one\n\(hexA) two\n")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].note, "one")
    }
}
