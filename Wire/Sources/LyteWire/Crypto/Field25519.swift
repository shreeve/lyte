// GF(2²⁵⁵ − 19) field arithmetic — the one crypto primitive W6 must
// hand-write, because CPace's calculate_generator needs the Elligator 2
// map onto Curve25519 and swift-crypto exposes no field ops (the risk
// register's "scope is one map function" row; X25519 itself stays
// swift-crypto's). Pure Swift, no imports, 5 × 51-bit limbs (the
// curve25519-donna representation). Sized for a task that runs once per
// pairing, not per datagram — clarity over throughput.
//
// Exponentiation is a fixed square-and-multiply over PUBLIC exponents
// ((p−1)/2 and p−2), so the operation sequence never depends on the
// PRS-derived base — the data-dependent branches the draft's §10.10
// warns about are limited to the negligible-probability exceptional
// cases called out at their sites in Elligator2.swift.

/// A field element of GF(2²⁵⁵ − 19) in 5 little-endian 51-bit limbs.
/// Arithmetic keeps limbs weakly reduced (< 2⁵¹ + ε); `toBytes()` is the
/// only place full canonical reduction happens.
struct Fe25519: Sendable {
    /// Always exactly 5 limbs.
    var l: [UInt64]

    static let limbMask: UInt64 = (1 << 51) - 1
    static let zero = Fe25519(l: [0, 0, 0, 0, 0])
    static let one = Fe25519(l: [1, 0, 0, 0, 0])
    /// 2p per limb — the subtraction bias that keeps a + 2p − b positive
    /// for weakly reduced inputs.
    private static let twoP: [UInt64] = [
        0xFFFF_FFFF_FFFDA, 0xFFFF_FFFF_FFFFE, 0xFFFF_FFFF_FFFFE,
        0xFFFF_FFFF_FFFFE, 0xFFFF_FFFF_FFFFE,
    ]

    /// (p − 1) / 2 = 2²⁵⁴ − 10, big-endian — the Legendre-symbol
    /// exponent (`epsilon` in the draft's Elligator 2 reference code).
    static let legendreExponent: [UInt8] =
        [0x3F] + [UInt8](repeating: 0xFF, count: 30) + [0xF6]
    /// p − 2 = 2²⁵⁵ − 21, big-endian — Fermat inversion, with the inv0
    /// convention (0 ↦ 0) RFC 9380's map relies on.
    static let inversionExponent: [UInt8] =
        [0x7F] + [UInt8](repeating: 0xFF, count: 30) + [0xEB]

    init(l: [UInt64]) {
        self.l = l
    }

    /// A small constant as a field element.
    init(_ value: UInt64) {
        l = [value & Self.limbMask, value >> 51, 0, 0, 0]
    }

    /// decodeUCoordinate from RFC 7748 for field_size_bits = 255: 32
    /// little-endian bytes with bit #255 cleared. Non-canonical values
    /// (≥ p) are accepted; arithmetic reduces them.
    static func fromBytes(_ bytes: [UInt8]) -> Fe25519 {
        precondition(bytes.count == 32, "field element is exactly 32 bytes")
        var words = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            for j in 0..<8 {
                words[i] |= UInt64(bytes[i * 8 + j]) << (8 * j)
            }
        }
        words[3] &= 0x7FFF_FFFF_FFFF_FFFF
        return Fe25519(l: [
            words[0] & limbMask,
            (words[0] >> 51 | words[1] << 13) & limbMask,
            (words[1] >> 38 | words[2] << 26) & limbMask,
            (words[2] >> 25 | words[3] << 39) & limbMask,
            (words[3] >> 12) & limbMask,
        ])
    }

    /// encodeUCoordinate: the canonical (fully reduced) 32-byte
    /// little-endian encoding, bit #255 always clear.
    func toBytes() -> [UInt8] {
        // Two weak passes bring every limb ≤ 2⁵¹ − 1…
        var t = Self.weakReduce(Self.weakReduce(l))
        // …then the carry-chain trick: q = 1 iff value ≥ p (adding 19
        // would carry out of bit 254), so adding 19q and dropping bit
        // 255 subtracts p exactly when needed.
        var q = (t[0] &+ 19) >> 51
        q = (t[1] &+ q) >> 51
        q = (t[2] &+ q) >> 51
        q = (t[3] &+ q) >> 51
        q = (t[4] &+ q) >> 51
        t[0] &+= 19 &* q
        for i in 0..<4 {
            t[i + 1] &+= t[i] >> 51
            t[i] &= Self.limbMask
        }
        t[4] &= Self.limbMask
        let words = [
            t[0] | t[1] << 51,
            t[1] >> 13 | t[2] << 38,
            t[2] >> 26 | t[3] << 25,
            t[3] >> 39 | t[4] << 12,
        ]
        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in words {
            for j in 0..<8 {
                out.append(UInt8(truncatingIfNeeded: word >> (8 * j)))
            }
        }
        return out
    }

    var isZero: Bool {
        toBytes().allSatisfy { $0 == 0 }
    }

    static func add(_ a: Fe25519, _ b: Fe25519) -> Fe25519 {
        Fe25519(l: weakReduce((0..<5).map { a.l[$0] &+ b.l[$0] }))
    }

    static func sub(_ a: Fe25519, _ b: Fe25519) -> Fe25519 {
        Fe25519(l: weakReduce((0..<5).map { a.l[$0] &+ twoP[$0] &- b.l[$0] }))
    }

    static func neg(_ a: Fe25519) -> Fe25519 {
        sub(zero, a)
    }

    static func mul(_ a: Fe25519, _ b: Fe25519) -> Fe25519 {
        // Schoolbook 5×5 with the 2²⁵⁵ ≡ 19 fold. Weakly reduced inputs
        // keep every accumulator far inside UInt128.
        let x = a.l.map { UInt128($0) }
        let y = b.l.map { UInt128($0) }
        var r = [UInt128](repeating: 0, count: 5)
        r[0] = x[0] * y[0] + 19 * (x[1] * y[4] + x[2] * y[3] + x[3] * y[2] + x[4] * y[1])
        r[1] = x[0] * y[1] + x[1] * y[0] + 19 * (x[2] * y[4] + x[3] * y[3] + x[4] * y[2])
        r[2] = x[0] * y[2] + x[1] * y[1] + x[2] * y[0] + 19 * (x[3] * y[4] + x[4] * y[3])
        r[3] = x[0] * y[3] + x[1] * y[2] + x[2] * y[1] + x[3] * y[0] + 19 * (x[4] * y[4])
        r[4] = x[0] * y[4] + x[1] * y[3] + x[2] * y[2] + x[3] * y[1] + x[4] * y[0]
        for i in 0..<4 {
            r[i + 1] += r[i] >> 51
            r[i] &= UInt128(limbMask)
        }
        let fold = UInt64(r[4] >> 51)
        r[4] &= UInt128(limbMask)
        var out = r.map { UInt64($0) }
        out[0] &+= 19 &* fold
        return Fe25519(l: weakReduce(out))
    }

    static func square(_ a: Fe25519) -> Fe25519 {
        mul(a, a)
    }

    /// Square-and-multiply over a big-endian public exponent. Variable
    /// time in the EXPONENT only — both callers pass fixed constants.
    static func pow(_ base: Fe25519, exponent: [UInt8]) -> Fe25519 {
        var result = one
        for byte in exponent {
            for bit in (0..<8).reversed() {
                result = square(result)
                if (byte >> bit) & 1 == 1 {
                    result = mul(result, base)
                }
            }
        }
        return result
    }

    /// One carry pass: limbs settle below 2⁵¹ + ε, the top carry folds
    /// back through 19, and a final pass clears limb 0's residue.
    private static func weakReduce(_ limbs: [UInt64]) -> [UInt64] {
        var t = limbs
        for i in 0..<4 {
            t[i + 1] &+= t[i] >> 51
            t[i] &= limbMask
        }
        t[0] &+= 19 &* (t[4] >> 51)
        t[4] &= limbMask
        t[1] &+= t[0] >> 51
        t[0] &= limbMask
        return t
    }
}
