// Noise spec §5.2: SymmetricState is (ck, h) over a CipherState, with the
// spec's own HKDF (§4.3: HMAC-chained, one to three outputs). `h` is the
// transcript hash — after Split it becomes the handshake hash W6's PAKE
// binds to (Lyte-UDP decision §8.2).

struct NoiseSymmetricState: Sendable {
    private(set) var chainingKey: [UInt8]
    private(set) var handshakeHash: [UInt8]
    var cipher: NoiseCipherState

    /// InitializeSymmetric: our protocol name is exactly HASHLEN (32)
    /// bytes, so h = the name itself, no hashing and no padding.
    init(protocolName: [UInt8]) {
        if protocolName.count <= NoisePrimitives.keyByteCount {
            var h = protocolName
            h.append(contentsOf: [UInt8](
                repeating: 0,
                count: NoisePrimitives.keyByteCount - protocolName.count
            ))
            handshakeHash = h
        } else {
            handshakeHash = NoisePrimitives.hash(protocolName)
        }
        chainingKey = handshakeHash
        cipher = NoiseCipherState()
    }

    /// Spec §4.3 HKDF(ck, input, n): temp = HMAC(ck, input);
    /// out1 = HMAC(temp, 0x01); out2 = HMAC(temp, out1 ‖ 0x02); …
    static func hkdf(
        chainingKey: [UInt8], input: [UInt8], outputs: Int
    ) -> [[UInt8]] {
        let temp = NoisePrimitives.hmac(key: chainingKey, data: input)
        var results: [[UInt8]] = []
        var previous: [UInt8] = []
        for i in 1...outputs {
            previous = NoisePrimitives.hmac(
                key: temp, data: previous + [UInt8(i)]
            )
            results.append(previous)
        }
        return results
    }

    /// MixKey (spec §5.2): (ck, temp_k) = HKDF(ck, input, 2); the cipher
    /// re-keys with temp_k and its n resets to 0.
    mutating func mixKey(_ input: [UInt8]) {
        let out = Self.hkdf(chainingKey: chainingKey, input: input, outputs: 2)
        chainingKey = out[0]
        cipher = NoiseCipherState(key: out[1])
    }

    /// MixHash: h = HASH(h ‖ data).
    mutating func mixHash(_ data: [UInt8]) {
        handshakeHash = NoisePrimitives.hash(handshakeHash + data)
    }

    /// EncryptAndHash: seal with h as AAD, then mix the ciphertext in.
    mutating func encryptAndHash(_ plaintext: ArraySlice<UInt8>) throws -> [UInt8] {
        let ciphertext = try cipher.encryptWithAd(handshakeHash[...], plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    /// DecryptAndHash: open with h as AAD; h mixes the received
    /// ciphertext only after a successful open.
    mutating func decryptAndHash(_ ciphertext: ArraySlice<UInt8>) throws -> [UInt8] {
        let plaintext = try cipher.decryptWithAd(handshakeHash[...], ciphertext)
        mixHash(Array(ciphertext))
        return plaintext
    }

    /// Split (spec §5.2): (temp_k1, temp_k2) = HKDF(ck, "", 2). First
    /// state encrypts initiator→responder traffic, second the reverse.
    func split() -> (NoiseCipherState, NoiseCipherState) {
        let out = Self.hkdf(chainingKey: chainingKey, input: [], outputs: 2)
        return (NoiseCipherState(key: out[0]), NoiseCipherState(key: out[1]))
    }
}
