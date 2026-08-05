// The byte budget, per the master plan ruling (§4.2): the 24-byte envelope
// rides as AAD outside the AEAD; the plaintext shard budget is 1112 bytes;
// ciphertext + 16-byte tag is at most 1128; the whole datagram at most 1152.
// 1152 is also the bridge-safe ceiling (overview §2) — DPLPMTUD may raise it
// later as a negotiated session parameter, never per-packet.

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

    /// Plaintext available when the mandatory connection-id TLV rides
    /// beside the envelope. The TLV block contributes its count byte, the
    /// extension's type/length bytes, and the eight-byte id; the AEAD tag is
    /// already reserved by the plaintext shard ceiling above. Session ARQ
    /// uses this value from its first datagram so packing never changes after
    /// the peer id is learned.
    public static let maxConnectionIdTaggedPlaintextByteCount =
        maxPlaintextShardByteCount - 1 - 2 - ConnectionId.byteCount

    /// ChaCha20-Poly1305 tag; the gap between the two payload ceilings.
    public static let aeadTagByteCount = 16
}
