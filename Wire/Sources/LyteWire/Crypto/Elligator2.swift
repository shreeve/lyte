// The Elligator 2 map onto Curve25519 (CPace draft §8.2 / appendix A.5,
// RFC 9380 map_to_curve_elligator2): field element → valid u-coordinate,
// the step that turns the hashed generator string into a curve point no
// party knows the discrete log of. Only the u-coordinate is produced —
// the v-coordinate the map also defines is unused by CPace and never
// computed. Constants are Curve25519's: A = 486662, B = 1, and the
// non-square Z = 2 (find_z_ell2's output for GF(2²⁵⁵ − 19)).

enum Elligator2 {
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
    static func mapToCurve(_ hashedBytes: [UInt8]) -> [UInt8] {
        let r = Fe25519.fromBytes(hashedBytes)
        let denominator = Fe25519.add(
            .one, Fe25519.mul(z, Fe25519.square(r))
        )
        // Fermat inversion with the inv0 convention: for the negligible
        // r² = −1/2 case the draft's reference code would divide by
        // zero; RFC 9380's straight-line version resolves it to v = −A,
        // and we follow RFC 9380.
        var v = Fe25519.mul(
            Fe25519.neg(a),
            Fe25519.pow(denominator, exponent: Fe25519.inversionExponent)
        )
        if denominator.isZero {
            v = Fe25519.neg(a)
        }
        // ε is the Legendre symbol of the curve equation's right side at
        // v (1, p−1, or 0), so u = v when v is on the curve and −v − A
        // (the other preimage) when it is not.
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
