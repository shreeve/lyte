// CPace, the balanced composable PAKE (draft-irtf-cfrg-cpace-21), cipher
// suite CPACE-X25519-SHA512 — the W6 primitive layer beneath PairingPake.
// One protocol, one suite: G_X25519 (single-coordinate Montgomery ladder,
// DSI "CPace255") with SHA-512, the draft's recommended small-message
// suite. X25519 itself stays swift-crypto's (the risk-register ruling);
// the hand-written parts are the Elligator 2 map beside this file and
// the string/derivation plumbing here, all pinned by the draft's
// appendix-B vectors in Vectors/pairing-v1.json.
//
// Initiator-responder setting only (transcript_ir): Lyte pairing always
// has clear roles — the client initiates, the host responds — so the
// symmetric o_cat ordering is deliberately not implemented.
//
// Like NoisePrimitives, this file imports Crypto (SHA-512, HMAC, X25519,
// and the scalar-sampling CSPRNG) and is lint-confined to Crypto/.

import Crypto

/// The CPACE-X25519-SHA512 functions, named after the draft's own
/// vocabulary so the code reads against the spec. Byte-level behavior is
/// frozen by the external draft vectors; `PairingPake` composes these
/// into Lyte's pairing flow.
public enum CPace {
    /// G_X25519.DSI = b"CPace255".
    public static let domainSeparator: [UInt8] = Array("CPace255".utf8)
    /// The ISK derivation label, G.DSI ‖ b"_ISK".
    static let iskDomainSeparator: [UInt8] = Array("CPace255_ISK".utf8)
    /// The §10.4 key-confirmation label.
    static let macDomainSeparator: [UInt8] = Array("CPaceMac".utf8)
    /// G_X25519.field_size_bytes: scalars, group elements, and K.
    public static let elementByteCount = 32
    /// SHA-512's output — the ISK and the §10.4 confirmation tags.
    public static let iskByteCount = 64
    public static let tagByteCount = 64
    /// H.s_in_bytes for SHA-512: the zero-padding target that fills the
    /// first hash block with DSI ‖ PRS regardless of PIN length.
    static let hashBlockByteCount = 128
    /// G_X25519.I — scalar_mult_vfy's error signal, never a valid K.
    public static let neutralElement = [UInt8](
        repeating: 0, count: elementByteCount
    )

    // MARK: String utilities (draft §6.3)

    /// prepend_len: LEB128 length prefix ‖ data.
    public static func prependLength(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        var remaining = data.count
        repeat {
            let sevenBits = UInt8(remaining & 0x7F)
            remaining >>= 7
            out.append(remaining == 0 ? sevenBits : sevenBits | 0x80)
        } while remaining != 0
        out.append(contentsOf: data)
        return out
    }

    /// lv_cat: concatenation with each part's length prepended.
    public static func lvCat(_ parts: [UInt8]...) -> [UInt8] {
        lvCat(parts)
    }

    public static func lvCat(_ parts: [[UInt8]]) -> [UInt8] {
        parts.reduce(into: [UInt8]()) { $0 += prependLength($1) }
    }

    /// transcript_ir — the initiator-responder protocol transcript.
    public static func transcript(
        ya: [UInt8], ada: [UInt8], yb: [UInt8], adb: [UInt8]
    ) -> [UInt8] {
        lvCat(ya, ada) + lvCat(yb, adb)
    }

    // MARK: Generator (draft §8.1–8.2)

    /// generator_string(G.DSI, PRS, CI, sid, H.s_in_bytes): the zero
    /// padding after PRS fills the first SHA-512 input block, so hashing
    /// cost is independent of PIN length (§10.10's side-channel note).
    public static func generatorString(
        prs: [UInt8], ci: [UInt8], sid: [UInt8]
    ) -> [UInt8] {
        let zeroPadLength = max(
            0,
            hashBlockByteCount - 1 - prependLength(prs).count
                - prependLength(domainSeparator).count
        )
        return lvCat(
            domainSeparator, prs,
            [UInt8](repeating: 0, count: zeroPadLength),
            ci, sid
        )
    }

    /// calculate_generator: hash the generator string to the field size,
    /// decode per RFC 7748, and map through Elligator 2 to a Curve25519
    /// u-coordinate no party knows the discrete log of.
    public static func calculateGenerator(
        prs: [UInt8], ci: [UInt8], sid: [UInt8]
    ) -> [UInt8] {
        Elligator2.mapToCurve(
            hashPrefix(generatorString(prs: prs, ci: ci, sid: sid),
                       byteCount: elementByteCount)
        )
    }

    // MARK: Group operations (draft §8.2)

    /// G.sample_scalar() — 32 uniform CSPRNG bytes (X25519 clamps
    /// internally per RFC 7748). Tests and vectorgen inject fixed
    /// scalars instead, the NoiseSession fixedEphemeral pattern.
    public static func sampleScalar() -> [UInt8] {
        // swift-crypto's key generation is the platform CSPRNG already
        // trusted for Noise ephemerals.
        Array(Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
    }

    /// G.scalar_mult_vfy(y, g) = X25519(y, g), returning G.I (the
    /// neutral element) for every invalid case — low-order points on
    /// the curve or its twist — instead of throwing: the draft's error
    /// signal, which callers MUST check and abort on. Non-canonical
    /// u-coordinates with bit #255 set are accepted (RFC 7748 clears
    /// the bit inside X25519); swift-crypto rejects the all-zero shared
    /// secret on both platforms, which is exactly the G.I set.
    public static func scalarMultVfy(
        scalar: [UInt8], element: [UInt8]
    ) -> [UInt8] {
        guard
            scalar.count == elementByteCount,
            element.count == elementByteCount,
            let privateKey = try? Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: scalar
            ),
            let publicKey = try? Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: element
            ),
            let shared = try? privateKey.sharedSecretFromKeyAgreement(
                with: publicKey
            )
        else {
            return neutralElement
        }
        return shared.withUnsafeBytes { Array($0) }
    }

    /// G.scalar_mult — same function for G_X25519 (§8.2); the alias
    /// keeps call sites reading against the draft.
    public static func scalarMult(
        scalar: [UInt8], element: [UInt8]
    ) -> [UInt8] {
        scalarMultVfy(scalar: scalar, element: element)
    }

    // MARK: Key derivation (draft §7.2, §10.4)

    /// ISK = H(lv_cat(G.DSI ‖ b"_ISK", sid, K) ‖ transcript) — the full
    /// 64 SHA-512 bytes. K MUST have been checked against G.I first;
    /// this function derives, it does not validate.
    public static func intermediateSessionKey(
        sid: [UInt8], k: [UInt8], transcript: [UInt8]
    ) -> [UInt8] {
        Array(SHA512.hash(data: lvCat(iskDomainSeparator, sid, k) + transcript))
    }

    /// The §10.4 explicit-confirmation MAC key:
    /// H(b"CPaceMac" ‖ sid ‖ ISK).
    public static func confirmationKey(
        sid: [UInt8], isk: [UInt8]
    ) -> [UInt8] {
        Array(SHA512.hash(data: macDomainSeparator + sid + isk))
    }

    /// A party's §10.4 confirmation tag over its own message:
    /// HMAC-SHA-512(mac_key, lv_cat(Y, AD)).
    public static func confirmationTag(
        confirmationKey: [UInt8], share: [UInt8], associatedData: [UInt8]
    ) -> [UInt8] {
        Array(HMAC<SHA512>.authenticationCode(
            for: lvCat(share, associatedData),
            using: SymmetricKey(data: confirmationKey)
        ))
    }

    /// Constant-time equality — tag checks must not leak a prefix-match
    /// oracle.
    public static func constantTimeEquals(
        _ a: [UInt8], _ b: [UInt8]
    ) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count {
            difference |= a[i] ^ b[i]
        }
        return difference == 0
    }

    /// H.hash(m, l): the first l bytes of SHA-512.
    static func hashPrefix(_ message: [UInt8], byteCount: Int) -> [UInt8] {
        Array(Array(SHA512.hash(data: message)).prefix(byteCount))
    }
}
