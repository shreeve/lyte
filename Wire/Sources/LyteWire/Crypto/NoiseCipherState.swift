// Noise spec §5.1: a CipherState is (k, n) with encrypt/decrypt-with-AAD
// and REKEY. The nonce is 4 zero bytes ‖ LE64(n) for ChaChaPoly (spec
// §12.2). This is the handshake-phase state and the base the transport
// cipher (extended-counter nonces, NoiseTransport.swift) builds on.

package struct NoiseCipherState: Sendable {
    /// 32-byte key. Handshake states before the first MixKey have none.
    private(set) var key: [UInt8]?
    /// The spec's `n` — sequential during the handshake and for the
    /// vector-verified transport-message path.
    private(set) var nonce: UInt64 = 0

    /// 2^64−1 never encrypts a message: it is REKEY's reserved nonce and
    /// the exhaustion sentinel (spec §5.1).
    static let reservedNonce = UInt64.max

    package init(key: [UInt8]? = nil) {
        self.key = key
    }

    package var hasKey: Bool { key != nil }

    /// Spec nonce encoding: 32 zero bits ‖ LE64(n).
    package static func encodeNonce(_ n: UInt64) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: NoisePrimitives.nonceByteCount)
        for i in 0..<8 {
            bytes[4 + i] = UInt8(truncatingIfNeeded: n >> (8 * i))
        }
        return bytes
    }

    /// EncryptWithAd: with no key, returns the plaintext (pre-key
    /// handshake steps); otherwise seals with the current n and bumps it.
    package mutating func encryptWithAd(
        _ ad: ArraySlice<UInt8>, _ plaintext: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        guard let key else { return Array(plaintext) }
        guard nonce != Self.reservedNonce else {
            throw NoiseError.nonceExhausted
        }
        let sealed = try NoisePrimitives.aeadSeal(
            key: key,
            nonce: Self.encodeNonce(nonce),
            aad: ad,
            plaintext: plaintext
        )
        nonce += 1
        return sealed
    }

    /// DecryptWithAd: n advances only on success (spec §5.1 — a failed
    /// open must not desync the stream).
    package mutating func decryptWithAd(
        _ ad: ArraySlice<UInt8>, _ ciphertext: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        guard let key else { return Array(ciphertext) }
        guard nonce != Self.reservedNonce else {
            throw NoiseError.nonceExhausted
        }
        let plaintext = try NoisePrimitives.aeadOpen(
            key: key,
            nonce: Self.encodeNonce(nonce),
            aad: ad,
            ciphertextAndTag: ciphertext
        )
        nonce += 1
        return plaintext
    }

    /// One-shot seal at an explicit nonce, no counter side effects — the
    /// transport path, where the nonce comes from (chan, extended seq).
    func seal(
        nonceBytes: [UInt8],
        aad: ArraySlice<UInt8>,
        plaintext: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        guard let key else { throw NoiseError.handshakeIncomplete }
        return try NoisePrimitives.aeadSeal(
            key: key, nonce: nonceBytes, aad: aad, plaintext: plaintext
        )
    }

    /// One-shot open at an explicit nonce, no counter side effects.
    func open(
        nonceBytes: [UInt8],
        aad: ArraySlice<UInt8>,
        ciphertextAndTag: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        guard let key else { throw NoiseError.handshakeIncomplete }
        return try NoisePrimitives.aeadOpen(
            key: key, nonce: nonceBytes, aad: aad, ciphertextAndTag: ciphertextAndTag
        )
    }

    /// Spec §4.2 REKEY: k = first 32 bytes of ENCRYPT(k, 2^64−1, "",
    /// zeros[32]) — the tag is dropped. n is NOT reset here; epoch
    /// bookkeeping is the transport layer's job.
    mutating func rekey() throws {
        guard let key else { throw NoiseError.handshakeIncomplete }
        let sealed = try NoisePrimitives.aeadSeal(
            key: key,
            nonce: Self.encodeNonce(Self.reservedNonce),
            aad: [][...],
            plaintext: [UInt8](repeating: 0, count: 32)[...]
        )
        self.key = Array(sealed.prefix(32))
    }
}
