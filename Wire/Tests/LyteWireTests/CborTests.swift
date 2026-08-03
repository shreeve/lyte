import LyteCore
import XCTest
import LyteWire
import LyteWireTestKit

// The CBOR profile beneath the capability layer, pinned three ways:
// RFC 8949 appendix-A examples as external hand-checkable anchors,
// the deterministic-encoding rejects (non-shortest arguments,
// misordered keys, everything outside the profile), and seeded fuzz —
// structured round trips plus hostile-bytes never-trap.

final class CborTests: XCTestCase {

    private func hex(_ s: String) -> [UInt8] {
        Hex.bytes(s)!
    }

    // MARK: - RFC 8949 appendix-A anchors

    func testRfc8949Anchors() throws {
        let anchors: [(CborValue, String)] = [
            (.unsigned(0), "00"),
            (.unsigned(23), "17"),
            (.unsigned(24), "1818"),
            (.unsigned(100), "1864"),
            (.unsigned(1000), "1903e8"),
            (.unsigned(1_000_000), "1a000f4240"),
            (.unsigned(1_000_000_000_000), "1b000000e8d4a51000"),
            (.unsigned(UInt64.max), "1bffffffffffffffff"),
            // Negative: encoded argument n represents −1 − n.
            (.negative(0), "20"),      // −1
            (.negative(9), "29"),      // −10
            (.negative(99), "3863"),   // −100
            (.negative(999), "3903e7"),// −1000
            (.bool(false), "f4"),
            (.bool(true), "f5"),
            (.null, "f6"),
            (.bytes([]), "40"),
            (.bytes([0x01, 0x02, 0x03, 0x04]), "4401020304"),
            (.text(""), "60"),
            (.text("a"), "6161"),
            (.text("IETF"), "6449455446"),
            (.text("\u{00fc}"), "62c3bc"),
            (.array([]), "80"),
            (
                .array([.unsigned(1), .unsigned(2), .unsigned(3)]),
                "83010203"
            ),
            (
                .array([
                    .unsigned(1),
                    .array([.unsigned(2), .unsigned(3)]),
                    .array([.unsigned(4), .unsigned(5)]),
                ]),
                "8301820203820405"
            ),
            (.map([]), "a0"),
            (
                .map([
                    .init(key: .unsigned(1), value: .unsigned(2)),
                    .init(key: .unsigned(3), value: .unsigned(4)),
                ]),
                "a201020304"
            ),
            (
                .map([
                    .init(key: .text("a"), value: .unsigned(1)),
                    .init(
                        key: .text("b"),
                        value: .array([.unsigned(2), .unsigned(3)])
                    ),
                ]),
                "a26161016162820203"
            ),
        ]
        for (value, expectedHex) in anchors {
            XCTAssertEqual(
                try Cbor.encode(value), hex(expectedHex),
                "encode \(expectedHex)"
            )
            XCTAssertEqual(
                try Cbor.decode(hex(expectedHex)), value,
                "decode \(expectedHex)"
            )
        }
    }

    func testMapSortsOnEncodeRegardlessOfConstructionOrder() throws {
        // §4.2.1 bytewise key order is produced, not merely required.
        let unsorted = CborValue.map([
            .init(key: .unsigned(3), value: .unsigned(4)),
            .init(key: .unsigned(1), value: .unsigned(2)),
        ])
        XCTAssertEqual(try Cbor.encode(unsorted), hex("a201020304"))
        // Integer keys before text keys (0x0X < 0x6X bytewise).
        let mixed = CborValue.map([
            .init(key: .text("a"), value: .null),
            .init(key: .unsigned(100), value: .null),
        ])
        XCTAssertEqual(try Cbor.encode(mixed), hex("a21864f66161f6"))
    }

    func testEncodeRejectsDuplicateMapKeys() {
        let duplicated = CborValue.map([
            .init(key: .unsigned(1), value: .unsigned(2)),
            .init(key: .unsigned(1), value: .unsigned(3)),
        ])
        XCTAssertThrowsError(try Cbor.encode(duplicated)) { error in
            XCTAssertEqual(error as? CborError, .duplicateMapKey)
        }
    }

    // MARK: - Deterministic-encoding and profile rejects

    func testDecodeRejects() {
        let rejects: [(String, CborError)] = [
            // Well-formed but non-shortest arguments, every width.
            ("1817", .nonCanonicalArgument),
            ("1900ff", .nonCanonicalArgument),
            ("1a0000ffff", .nonCanonicalArgument),
            ("1b00000000ffffffff", .nonCanonicalArgument),
            ("3817", .nonCanonicalArgument),
            ("5817" + String(repeating: "00", count: 23),
             .nonCanonicalArgument),
            // Map-key ordering and duplicates.
            ("a202000100", .misorderedMapKeys),
            ("a201000100", .duplicateMapKey),
            ("a26162f66161f6", .misorderedMapKeys),
            // Outside the profile: indefinite lengths, tags, floats,
            // undefined, reserved info values.
            ("5f42010243030405ff", .unsupportedItem(0x5F)),
            ("9f018202039f0405ffff", .unsupportedItem(0x9F)),
            ("bf61610161629f0203ffff", .unsupportedItem(0xBF)),
            ("7f657374726561646d696e67ff", .unsupportedItem(0x7F)),
            ("c074323031332d30332d32315432303a30343a30305a",
             .unsupportedItem(0xC0)),
            ("f90000", .unsupportedItem(0xF9)),
            ("fa47c35000", .unsupportedItem(0xFA)),
            ("fb7e37e43c8800759c", .unsupportedItem(0xFB)),
            ("f7", .unsupportedItem(0xF7)),
            ("f0", .unsupportedItem(0xF0)),
            ("1c", .unsupportedItem(0x1C)),
            // Truncation at every structural layer.
            ("", .truncatedItem),
            ("19", .truncatedItem),
            ("1904", .truncatedItem),
            ("44010203", .truncatedItem),
            ("6449455446".dropLastPair, .truncatedItem),
            ("8101".dropLastPair, .truncatedItem),
            ("a20102", .truncatedItem),
            // Count larger than the remaining bytes refuses before
            // reserving hostile capacity.
            ("9b7fffffffffffffff00", .truncatedItem),
            ("bb7fffffffffffffff00", .truncatedItem),
            // Trailing garbage.
            ("0000", .trailingBytes),
            // Invalid UTF-8 in a text string.
            ("62c328", .invalidUtf8),
            // Nesting bound: 8 nested arrays put the innermost item
            // at the depth cap.
            (String(repeating: "81", count: 8) + "00", .nestingTooDeep),
        ]
        for (rawHex, expected) in rejects {
            let cleaned = rawHex.filter { !$0.isWhitespace }
            XCTAssertThrowsError(
                try Cbor.decode(hex(cleaned)), cleaned
            ) { error in
                XCTAssertEqual(error as? CborError, expected, cleaned)
            }
        }
    }

    func testNestingJustInsideTheBoundDecodes() throws {
        let sevenDeep = hex(String(repeating: "81", count: 7) + "00")
        XCTAssertNoThrow(try Cbor.decode(sevenDeep))
    }

    // MARK: - Seeded fuzz

    func testStructuredRoundTripFuzz() throws {
        var rng = SplitMix64(seed: 0x57C0_DE01)
        for iteration in 0..<2000 {
            let value = Self.randomValue(depth: 0, rng: &rng)
            let encoded = try Cbor.encode(value)
            let decoded = try Cbor.decode(encoded)
            // Decode yields canonical map order; re-encode must be
            // byte-identical — encode∘decode is the identity on
            // canonical bytes.
            XCTAssertEqual(
                try Cbor.encode(decoded), encoded, "iteration \(iteration)"
            )
        }
    }

    func testHostileBytesNeverTrap() {
        var rng = SplitMix64(seed: 0x57C0_DE02)
        for _ in 0..<5000 {
            let count = Int(rng.next() % 64)
            let bytes = rng.bytes(count)
            // Any outcome but a trap is acceptable; decoded values
            // must re-encode to the same bytes (canonical admission).
            if let value = try? Cbor.decode(bytes) {
                XCTAssertEqual(try? Cbor.encode(value), bytes)
            }
        }
    }

    /// Random profile values. Maps draw distinct unsigned keys so the
    /// generated value is already canonical up to entry order (encode
    /// sorts the entries).
    private static func randomValue(
        depth: Int, rng: inout SplitMix64
    ) -> CborValue {
        let scalarOnly = depth >= 3
        switch rng.next() % (scalarOnly ? 6 : 8) {
        case 0: return .unsigned(rng.next())
        case 1: return .negative(rng.next())
        case 2: return .bytes(rng.bytes(Int(rng.next() % 40)))
        case 3:
            let scalars = "abcdefghij κλμ 🜁"
            let count = Int(rng.next() % 12)
            return .text(String(
                (0..<count).map { _ in
                    scalars.randomElement(using: &rng)!
                }
            ))
        case 4: return .bool(rng.next() & 1 == 0)
        case 5: return .null
        case 6:
            let count = Int(rng.next() % 5)
            return .array((0..<count).map { _ in
                randomValue(depth: depth + 1, rng: &rng)
            })
        default:
            let count = Int(rng.next() % 5)
            var keys: Set<UInt64> = []
            while keys.count < count { keys.insert(rng.next() % 1000) }
            return .map(keys.sorted().map {
                CborMapEntry(
                    key: .unsigned($0),
                    value: randomValue(depth: depth + 1, rng: &rng)
                )
            })
        }
    }
}

private extension String {
    /// Drops the final hex byte pair — truncation-case helper.
    var dropLastPair: String {
        String(dropLast(2))
    }
}
