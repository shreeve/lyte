// The Elligator 2 map onto Curve25519 (CPace draft §8.2 / appendix A.5,
// RFC 9380 map_to_curve_elligator2): field element → valid u-coordinate,
// the step that turns the hashed generator string into a curve point no
// party knows the discrete log of. Only the u-coordinate is produced —
// the v-coordinate the map also defines is unused by CPace and never
// computed. Constants are Curve25519's: A = 486662, B = 1, and the
// non-square Z = 2 (find_z_ell2's output for GF(2²⁵⁵ − 19)).
//
// Constant-time status (pre-H1 Crypto/ review): this function is
// branch-free. The two exceptional cases the draft's §10.10 side-channel
// note worried about are handled with constant-time mask selection —
// and both are in fact UNREACHABLE over GF(2²⁵⁵ − 19), not merely
// negligible; the arguments live at their sites below.

package enum Elligator2 {
    /// Curve25519's Montgomery A.
    private static let a = Fe25519(486662)
    /// A/2 — exact, A is even.
    private static let aHalf = Fe25519(243331)
    /// The non-square Z = 2 as a multiplication-ready element.
    private static let z = Fe25519(2)

    /// Maps 32 hashed bytes to a Curve25519 u-coordinate: decode as a
    /// field element per RFC 7748 (bit #255 cleared), apply the map,
    /// return the canonical 32-byte little-endian u-coordinate.
    ///
    ///     v = −A / (1 + Z·r²)
    ///     ε = (v³ + A·v² + v) ^ ((p−1)/2)
    ///     u = ε·v − (1 − ε)·A/2
    package static func mapToCurve(_ hashedBytes: [UInt8]) -> [UInt8] {
        let r = Fe25519.fromBytes(hashedBytes)
        let denominator = Fe25519.add(
            .one, Fe25519.mul(z, Fe25519.square(r))
        )
        // Fermat inversion with the inv0 convention (0 ↦ 0), then RFC
        // 9380's straight-line exceptional-case rule as a constant-time
        // select: v = −A when the denominator is zero. UNREACHABLE:
        // 1 + 2r² = 0 requires r² = −1/2, and −1/2 is a quadratic
        // non-residue mod 2²⁵⁵ − 19 ((−2⁻¹)^((p−1)/2) ≡ p − 1), so no
        // field element r satisfies it — the select is kept purely for
        // straight-line conformance with the RFC, and costs nothing.
        let negA = Fe25519.neg(a)
        let v = Fe25519.select(
            negA,
            Fe25519.mul(
                negA,
                Fe25519.pow(denominator, exponent: Fe25519.inversionExponent)
            ),
            mask: denominator.isZeroMask
        )
        // ε is the Legendre symbol of the curve equation's right side at
        // v, so u = v when v is on the curve and −v − A (the other
        // preimage) when it is not. ε = 0 (curveRHS = 0) is UNREACHABLE:
        // v = 0 requires the zero denominator excluded above, and the
        // remaining roots of v² + Av + 1 = 0 would need A² − 4 to be a
        // quadratic residue mod p — it is not (486662² − 4 raised to
        // (p−1)/2 is p − 1). So ε ∈ {1, p−1} always, and the u formula
        // below (which would yield −A/2 at ε = 0, where RFC 9380's
        // is_square(0) = true picks u = v instead) never sees the case
        // the two texts resolve differently.
        let vSquared = Fe25519.square(v)
        let curveRHS = Fe25519.add(
            Fe25519.add(Fe25519.mul(vSquared, v), Fe25519.mul(a, vSquared)),
            v
        )
        let epsilon = Fe25519.pow(
            curveRHS, exponent: Fe25519.legendreExponent
        )
        let u = Fe25519.sub(
            Fe25519.mul(epsilon, v),
            Fe25519.mul(Fe25519.sub(.one, epsilon), aHalf)
        )
        return u.toBytes()
    }
}
