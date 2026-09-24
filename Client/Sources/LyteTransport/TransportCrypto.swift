// The transport crypto seam: the exact envelope header bytes are the AAD,
// and the envelope's (chan, seq) feed the nonce.

import LyteWire

public enum TransportCryptoError: Error, Equatable, Sendable {
    /// Not a 32-byte hex X25519 public key.
    case invalidHostKey(String)
    /// The Noise IK handshake could not complete (no answer, message 2
    /// rejected, transport used before open).
    case handshakeFailed(String)
    /// A payload was refused by a crypto seam without a typed error of
    /// its own. The Noise seam rethrows the Wire transport's typed error.
    case unsealFailed(String)
}

/// Both directions of one transport session's crypto. `open()` must
/// complete before any payload is accepted.
public protocol TransportCrypto: Sendable {
    /// Human-readable mode label for logs and the CLI banner.
    var modeDescription: String { get }

    /// Transport-open. Throws if the session cannot be established.
    func open() throws

    /// Unseals one received payload. `aad` is the exact header bytes as
    /// received; `envelope` carries the nonce material.
    func unseal(
        wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8]

    /// Seals one outbound shard; `aad` is the exact header bytes that will
    /// precede it. Returns ciphertext + authentication tag.
    func seal(
        plaintext: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8]
}
