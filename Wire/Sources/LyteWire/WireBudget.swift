// The byte budget: the 24-byte envelope rides as AAD outside the AEAD; the
// plaintext shard is at most 1112 bytes, ciphertext + 16-byte tag at most
// 1128, the whole datagram at most 1152 (the bridge-safe ceiling).

public enum WireBudget {
    /// The fixed envelope, always present, always authenticated-not-encrypted.
    public static let envelopeByteCount = 24

    /// Hard ceiling for one datagram: envelope + extensions + payload.
    public static let maxDatagramByteCount = 1152

    /// What may follow the header in a live session: ciphertext + AEAD tag.
    /// Test/vector bare framing uses the same ceiling so FEC geometry stays
    /// independent of the crypto seam.
    public static let maxWirePayloadByteCount = 1128

    /// What a packetizer may put into one shard before sealing. Enforced
    /// identically by test/vector equipment so gate results carry over.
    public static let maxPlaintextShardByteCount = 1112

    /// Plaintext left when the connection-id TLV (count, type, length, and
    /// eight id bytes) rides beside the envelope. Session ARQ uses this from
    /// its first datagram so packing never changes once the peer id is known.
    public static let maxConnectionIdTaggedPlaintextByteCount =
        maxPlaintextShardByteCount - 1 - 2 - ConnectionId.byteCount

    /// ChaCha20-Poly1305 tag; the gap between the two payload ceilings.
    public static let aeadTagByteCount = 16
}
