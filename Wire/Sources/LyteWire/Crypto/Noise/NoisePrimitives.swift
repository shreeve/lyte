// The Noise suite's primitive surface (core plan §1): DH, AEAD, hash
// and HMAC over swift-crypto's `Crypto` module on all platforms
// (CryptoKit shim on Apple, vendored BoringSSL on Linux; never CryptoKit
// directly, which is Apple-only). Everything in the Noise stack —
// CipherState, SymmetricState, the IK handshake, the transport — calls
// through this enum. `import Crypto` is confined to Crypto/ (this file,
// Pairing/CPace.swift, Retry/RetryCookie.swift);
// Scripts/lint-no-foundation.sh enforces the confinement.

import Crypto

/// DH, AEAD seal/open, hash, and HMAC over `[UInt8]`, exactly the
/// primitive set `Noise_IK_25519_ChaChaPoly_SHA256` names. HKDF is not
/// here because the Noise spec defines its own (HMAC-chained, §4.3) —
/// built on `hmac` in `NoiseSymmetricState`.
enum NoisePrimitives {
    /// DHLEN = HASHLEN = key length = 32 for this suite.
    static let keyByteCount = 32
    /// Poly1305 tag — the 1112→1128 budget gap (WireBudget.aeadTagByteCount).
    static let tagByteCount = 16
    /// ChaChaPoly nonce: 4 zero (or discriminator) bytes + 8-byte LE counter.
    static let nonceByteCount = 12

    /// A fresh X25519 private key from the platform CSPRNG.
    static func generatePrivateKey() -> [UInt8] {
        Array(Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
    }

    /// The X25519 public key for a raw 32-byte private key.
    static func publicKey(forPrivateKey privateKey: [UInt8]) throws -> [UInt8] {
        guard privateKey.count == keyByteCount else {
            throw NoiseError.invalidKeyLength(privateKey.count)
        }
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: privateKey
        ) else {
            throw NoiseError.invalidPublicKey
        }
        return Array(key.publicKey.rawRepresentation)
    }

    /// Raw X25519: returns the 32-byte shared secret. Throws
    /// `invalidPublicKey` on a malformed point or an all-zero result
    /// (low-order point) — the abort the Noise spec permits and we take.
    static func dh(privateKey: [UInt8], publicKey: [UInt8]) throws -> [UInt8] {
        guard privateKey.count == keyByteCount else {
            throw NoiseError.invalidKeyLength(privateKey.count)
        }
        guard publicKey.count == keyByteCount else {
            throw NoiseError.invalidKeyLength(publicKey.count)
        }
        guard
            let secretKey = try? Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: privateKey
            ),
            let peerKey = try? Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: publicKey
            ),
            let shared = try? secretKey.sharedSecretFromKeyAgreement(
                with: peerKey
            )
        else {
            throw NoiseError.invalidPublicKey
        }
        return shared.withUnsafeBytes { Array($0) }
    }

    /// A ChaCha20-Poly1305 key: the raw bytes (REKEY derives from them)
    /// plus the provider's key object, built once per key rather than
    /// once per datagram.
    struct AeadKey: Sendable {
        let bytes: [UInt8]
        fileprivate let symmetric: SymmetricKey

        /// Keys come only from the Noise HKDF and REKEY, both of which
        /// produce exactly 32 bytes.
        init(_ bytes: [UInt8]) {
            precondition(bytes.count == keyByteCount)
            self.bytes = bytes
            symmetric = SymmetricKey(data: bytes)
        }
    }

    /// ChaCha20-Poly1305 seal: returns ciphertext ‖ 16-byte tag.
    static func aeadSeal(
        key: AeadKey,
        nonce: [UInt8],
        aad: ArraySlice<UInt8>,
        plaintext: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        guard nonce.count == nonceByteCount else {
            throw NoiseError.invalidKeyLength(nonce.count)
        }
        // The seal path throws only on structural misuse (bad lengths),
        // which the guards above exclude — a throw here is a logic bug.
        let box = try ChaChaPoly.seal(
            plaintext,
            using: key.symmetric,
            nonce: ChaChaPoly.Nonce(data: nonce),
            authenticating: aad
        )
        var out = [UInt8]()
        out.reserveCapacity(plaintext.count + tagByteCount)
        out.append(contentsOf: box.ciphertext)
        out.append(contentsOf: box.tag)
        return out
    }

    /// ChaCha20-Poly1305 open of ciphertext ‖ tag. Throws
    /// `authenticationFailure` — and deliberately nothing more specific.
    static func aeadOpen(
        key: AeadKey,
        nonce: [UInt8],
        aad: ArraySlice<UInt8>,
        ciphertextAndTag: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        guard nonce.count == nonceByteCount else {
            throw NoiseError.invalidKeyLength(nonce.count)
        }
        guard ciphertextAndTag.count >= tagByteCount else {
            throw NoiseError.authenticationFailure
        }
        guard
            let box = try? ChaChaPoly.SealedBox(
                combined: nonce + ciphertextAndTag
            ),
            let plaintext = try? ChaChaPoly.open(
                box, using: key.symmetric, authenticating: aad
            )
        else {
            throw NoiseError.authenticationFailure
        }
        return Array(plaintext)
    }

    /// SHA-256.
    static func hash(_ data: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }

    /// HMAC-SHA-256 — the Noise HKDF's one building block.
    static func hmac(key: [UInt8], data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(
            for: data, using: SymmetricKey(data: key)
        ))
    }
}
