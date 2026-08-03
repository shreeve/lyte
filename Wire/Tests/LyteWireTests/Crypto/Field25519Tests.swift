import XCTest
import LyteWire
import LyteWireTestKit

// The pre-H1 Crypto/ review's direct pins on the hand-written
// GF(2²⁵⁵ − 19) arithmetic: canonical-form enforcement at the
// decode/encode boundary (non-canonical inputs at every public entry),
// the constant-time zero mask and select primitives, and arithmetic
// identities that would catch a broken carry chain. The draft-vector
// end-to-end pins live in CPaceCoreTests; this file is where a
// field-arithmetic regression names itself.

final class Field25519Tests: XCTestCase {

    /// p = 2²⁵⁵ − 19 as 32 little-endian bytes.
    private static let pBytes: [UInt8] =
        [0xED] + [UInt8](repeating: 0xFF, count: 30) + [0x7F]

    private func littleEndian(_ value: UInt64) -> [UInt8] {
        (0..<32).map { $0 < 8 ? UInt8(truncatingIfNeeded: value >> (8 * $0)) : 0 }
    }

    /// p + small, for small ≤ 18 (so the sum stays below 2²⁵⁵ and
    /// survives fromBytes's bit-255 clear).
    private func pPlus(_ small: UInt8) -> [UInt8] {
        precondition(small <= 18)
        var bytes = Self.pBytes
        bytes[0] = 0xED &+ small
        return bytes
    }

    // MARK: Canonical-form enforcement at the decode/encode boundary

    func testNonCanonicalEncodingsReduceOnEncode() {
        // p itself is a non-canonical zero: toBytes must canonicalize.
        XCTAssertEqual(
            Fe25519.fromBytes(Self.pBytes).toBytes(), littleEndian(0)
        )
        // p + k ≡ k for every k the 255-bit window can still hold.
        for k: UInt8 in [1, 2, 17, 18] {
            XCTAssertEqual(
                Fe25519.fromBytes(pPlus(k)).toBytes(),
                littleEndian(UInt64(k)),
                "p + \(k)"
            )
        }
        // 2²⁵⁵ − 1 (all ones under the bit-255 mask) ≡ 18.
        var allOnes = [UInt8](repeating: 0xFF, count: 32)
        allOnes[31] = 0x7F
        XCTAssertEqual(Fe25519.fromBytes(allOnes).toBytes(), littleEndian(18))
        // Bit #255 is cleared on decode, per RFC 7748: setting it must
        // not change the decoded element.
        var topBitSet = littleEndian(5)
        topBitSet[31] |= 0x80
        XCTAssertEqual(Fe25519.fromBytes(topBitSet).toBytes(), littleEndian(5))
    }

    func testCanonicalValuesRoundTripExactly() {
        // p − 1 is the largest canonical element; it must survive
        // decode/encode untouched (no spurious reduction).
        var pMinusOne = Self.pBytes
        pMinusOne[0] = 0xEC
        XCTAssertEqual(Fe25519.fromBytes(pMinusOne).toBytes(), pMinusOne)
        XCTAssertEqual(Fe25519.fromBytes(littleEndian(0)).toBytes(), littleEndian(0))
        XCTAssertEqual(Fe25519.fromBytes(littleEndian(1)).toBytes(), littleEndian(1))
    }

    // MARK: The constant-time primitives

    func testIsZeroMaskCoversNonCanonicalZero() {
        XCTAssertEqual(Fe25519.zero.isZeroMask, UInt64.max)
        // p decodes non-canonically but IS zero mod p — the mask must
        // judge the canonical form, not the limbs.
        XCTAssertEqual(Fe25519.fromBytes(Self.pBytes).isZeroMask, UInt64.max)
        XCTAssertEqual(Fe25519.one.isZeroMask, 0)
        XCTAssertEqual(Fe25519.fromBytes(pPlus(1)).isZeroMask, 0)
        XCTAssertTrue(Fe25519.zero.isZero)
        XCTAssertFalse(Fe25519.one.isZero)
    }

    func testSelectPicksByMask() {
        let a = Fe25519(1234)
        let b = Fe25519(5678)
        XCTAssertEqual(
            Fe25519.select(a, b, mask: UInt64.max).toBytes(), a.toBytes()
        )
        XCTAssertEqual(
            Fe25519.select(a, b, mask: 0).toBytes(), b.toBytes()
        )
    }

    // MARK: Arithmetic identities (carry-chain regression pins)

    func testFieldIdentities() {
        let x = Fe25519.fromBytes(
            (0..<32).map { UInt8(truncatingIfNeeded: 0x61 &+ $0) }
        )
        // x − x = 0, x + (−x) = 0, x · 1 = x.
        XCTAssertTrue(Fe25519.sub(x, x).isZero)
        XCTAssertTrue(Fe25519.add(x, Fe25519.neg(x)).isZero)
        XCTAssertEqual(Fe25519.mul(x, .one).toBytes(), x.toBytes())
        // (p − 1) + 2 = 1: the wrap through the modulus.
        var pMinusOne = Self.pBytes
        pMinusOne[0] = 0xEC
        XCTAssertEqual(
            Fe25519.add(Fe25519.fromBytes(pMinusOne), Fe25519(2)).toBytes(),
            littleEndian(1)
        )
        // Fermat inversion: x · x⁻¹ = 1, and inv0(0) = 0.
        let inverse = Fe25519.pow(x, exponent: Fe25519.inversionExponent)
        XCTAssertEqual(Fe25519.mul(x, inverse).toBytes(), littleEndian(1))
        XCTAssertTrue(
            Fe25519.pow(.zero, exponent: Fe25519.inversionExponent).isZero
        )
        // Legendre: a square (4) → 1; a known non-square (2) → p − 1.
        XCTAssertEqual(
            Fe25519.pow(Fe25519(4), exponent: Fe25519.legendreExponent)
                .toBytes(),
            littleEndian(1)
        )
        XCTAssertEqual(
            Fe25519.pow(Fe25519(2), exponent: Fe25519.legendreExponent)
                .toBytes(),
            pMinusOne
        )
    }

    func testRepeatedSquaringStaysReduced() {
        // 200 squarings chained through mul: if any carry bound were
        // wrong, limb overflow would corrupt the value long before the
        // end. Cross-checked by inverting the result.
        var x = Fe25519.fromBytes(
            (0..<32).map { UInt8(truncatingIfNeeded: 3 &* $0 &+ 7) }
        )
        for _ in 0..<200 {
            x = Fe25519.square(x)
        }
        let inverse = Fe25519.pow(x, exponent: Fe25519.inversionExponent)
        XCTAssertEqual(Fe25519.mul(x, inverse).toBytes(), littleEndian(1))
    }

    // MARK: Elligator 2 decode-boundary behavior

    func testMapToCurveTreatsNonCanonicalInputsAsReduced() {
        // r and r + p decode to the same field element, so the map must
        // produce identical u-coordinates — non-canonical hashed bytes
        // cannot smuggle in a second preimage.
        for k: UInt8 in [0, 1, 5, 18] {
            XCTAssertEqual(
                Elligator2.mapToCurve(pPlus(k)),
                Elligator2.mapToCurve(littleEndian(UInt64(k))),
                "r = \(k)"
            )
        }
        // Bit #255 is cleared before mapping, per decodeUCoordinate.
        var topBitSet = littleEndian(9)
        topBitSet[31] |= 0x80
        XCTAssertEqual(
            Elligator2.mapToCurve(topBitSet),
            Elligator2.mapToCurve(littleEndian(9))
        )
    }

    func testMapToCurveOfZeroIsWellDefined() {
        // r = 0: denominator = 1, v = −A, ε = legendre(−A³ + A³ − A)
        // = legendre(−A)… the point is only that the output is a
        // stable, canonical 32 bytes — the exceptional SELECT path is
        // unreachable (see Elligator2.swift) and r = 0 does not hit it.
        let u = Elligator2.mapToCurve(littleEndian(0))
        XCTAssertEqual(u.count, 32)
        XCTAssertEqual(u, Elligator2.mapToCurve(littleEndian(0)))
        // The output must itself be canonical: decode/encode fixed point.
        XCTAssertEqual(Fe25519.fromBytes(u).toBytes(), u)
    }

    func testMapToCurveOutputsAreCanonical() {
        // Every map output is an encode of toBytes — spot-check the
        // canonical fixed-point property across assorted inputs.
        var rng = SplitMix64(seed: 0xE11162)
        for _ in 0..<16 {
            let input = (0..<32).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            let u = Elligator2.mapToCurve(input)
            XCTAssertEqual(Fe25519.fromBytes(u).toBytes(), u)
        }
    }
}
