// Everything the Noise layer can refuse (W5). Hostile bytes off the wire
// must throw one of these — never trap, and never carry key material in
// associated values (transcript-safety is gate W-G6's fuzz requirement).

public enum NoiseError: Error, Equatable, Sendable {
    /// A raw key or DH output was not exactly 32 bytes.
    case invalidKeyLength(Int)
    /// The DH produced an all-zero / low-order shared secret, or the peer
    /// public key was not a valid Curve25519 point.
    case invalidPublicKey
    /// AEAD open failed: wrong key, wrong nonce, or tampered
    /// ciphertext/AAD. Deliberately carries nothing else.
    case authenticationFailure
    /// A handshake message was shorter than its pattern requires.
    case truncatedHandshakeMessage
    /// A handshake step was driven out of order (e.g. writing message 2
    /// before reading message 1, or reusing a completed handshake).
    case handshakeOutOfOrder
    /// The first handshake payload's wire major version differs from ours
    /// (Lyte-UDP decision §8.3 — no ALPN, the version rides here).
    case versionMismatch(received: UInt8, expected: UInt8)
    /// The handshake payload was too short to carry the version byte.
    case missingVersionPayload
    /// The Noise nonce counter is exhausted (2^64−1 is reserved for
    /// rekey); the session must rekey or terminate, never wrap.
    case nonceExhausted
    /// Plaintext exceeds the 1112 B shard budget (master plan §4.2).
    case plaintextOverBudget(Int)
    /// Wire payload is over 1128 B or under the 16 B AEAD tag floor.
    case wirePayloadOutOfBounds(Int)
    /// The reconstructed extended counter fell behind the replay window —
    /// the datagram is too old to judge, dropped per policy.
    case staleSequence
    /// This exact extended counter was already accepted once. A
    /// byte-identical retransmit that lost the race — dropped per the
    /// core-plan rule that replay protection admits each seq once.
    case replayedSequence
    /// The sender was asked to seal a (chan, seq) at or behind one it
    /// already sealed. A retransmit is a byte-identical datagram resend
    /// (core plan pinned decision 2) — the caller resends its bytes, it
    /// never re-seals, so a non-advancing counter here is (key, nonce)
    /// reuse in the making and is refused.
    case sendSequenceNotMonotonic
    /// `makeTransport()` before the handshake completed.
    case handshakeIncomplete
}
