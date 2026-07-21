// The crypto seam W5 filled. The envelope header (fixed 24 bytes + any TLV
// block) is AAD-shaped already: `unseal` receives the exact received header
// bytes as `aad` and the envelope for nonce material (chan, seq feed the
// extended-counter nonce per the master plan §4.1), so the Noise impl
// (NoiseTransportCrypto.swift) slots in without touching the receive path.
// InsecureTransportCrypto is the CP-3 recorded `--insecure` fallback —
// passthrough, loudly labeled.

import LyteWire

public enum TransportCryptoError: Error, Equatable, Sendable {
    /// The `--host-key` argument (or a config key) is not a 32-byte hex
    /// X25519 public key.
    case invalidHostKey(String)
    /// The Noise IK handshake could not complete (no answer, message 2
    /// rejected, transport used before open).
    case handshakeFailed(String)
    /// AEAD open failed (tag mismatch, replay, stale sequence).
    case unsealFailed(String)
}

/// Both directions of one transport session's crypto. `open()` is the
/// transport-open step: it must complete before any payload is accepted
/// (Noise IK handshake once W5 lands; immediate in insecure mode). `unseal`
/// maps a wire payload (ciphertext + 16 B tag, or the bare shard) to
/// plaintext; `seal` is the mirror the CL-3 send path added — same AAD
/// discipline, same envelope-derived nonce material, so W5's Noise slots
/// into both directions without touching either path.
public protocol TransportCrypto: Sendable {
    /// Human-readable mode label for logs and the CLI banner.
    var modeDescription: String { get }

    /// Transport-open. Throws if the session cannot be established.
    func open() throws

    /// Unseals one received payload. `aad` is the exact header bytes as
    /// received (fixed envelope + TLV block) — the AEAD associated data.
    /// `envelope` carries the decoded (chan, seq, frame) the nonce derives
    /// from. Returns the plaintext shard.
    func unseal(
        wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> ArraySlice<UInt8>

    /// Seals one outbound plaintext shard. `aad` is the exact header bytes
    /// that will precede the payload on the wire (fixed envelope + TLV
    /// block); `envelope` carries the (chan, seq, frame) the nonce derives
    /// from. Returns the wire payload (ciphertext + tag with Noise, the
    /// shard unchanged in insecure mode).
    func seal(
        plaintext: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8]
}

/// INSECURE passthrough — the CP-3 recorded fallback (master plan §4.1).
/// No confidentiality, no integrity: the payload is returned as-is. LAN
/// debugging only; the default is Noise.
public struct InsecureTransportCrypto: TransportCrypto {
    public init() {}

    public var modeDescription: String {
        "INSECURE passthrough (CP-3 fallback — no crypto)"
    }

    public func open() throws {}

    public func unseal(
        wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> ArraySlice<UInt8> {
        wirePayload
    }

    public func seal(
        plaintext: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> [UInt8] {
        Array(plaintext)
    }
}

