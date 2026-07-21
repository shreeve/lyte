// The crypto seam W5 fills. The envelope header (fixed 24 bytes + any TLV
// block) is AAD-shaped already: `unseal` receives the exact received header
// bytes as `aad` and the envelope for nonce material (chan, seq feed the
// extended-counter nonce per the master plan §4.1), so the Noise impl slots
// in without touching the receive path. Until W5 lands, the only working
// mode is the CP-3 recorded `--insecure` fallback — passthrough, loudly
// labeled, mandatory re-gate when real Noise arrives.

import LyteWire

public enum TransportCryptoError: Error, Equatable, Sendable {
    /// The Noise implementation does not exist yet (W5 pending).
    case noisePending(String)
    /// AEAD open failed (tag mismatch, replay, bad epoch) — real cases
    /// arrive with W5; the type exists now so counters have a home.
    case unsealFailed(String)
}

/// Receive-side crypto for one transport session. `open()` is the transport-
/// open step: it must complete before any payload is accepted (Noise IK
/// handshake once W5 lands; immediate in insecure mode). `unseal` maps a
/// wire payload (ciphertext + 16 B tag, or the bare shard) to plaintext.
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
}

/// INSECURE passthrough — the CP-3 recorded fallback (master plan §4.1).
/// No confidentiality, no integrity: the payload is returned as-is. Only
/// for LAN debugging before W5; J-G1 runs with it at most once and re-runs
/// with Noise on.
public struct InsecureTransportCrypto: TransportCrypto {
    public init() {}

    public var modeDescription: String {
        "INSECURE passthrough (CP-3 fallback — no crypto, re-gate when W5 lands)"
    }

    public func open() throws {}

    public func unseal(
        wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> ArraySlice<UInt8> {
        wirePayload
    }
}

/// The real thing, pending W5 (Noise IK, extended-counter nonce/epoch,
/// rekey). Every entry point fails loudly so nothing silently streams
/// unauthenticated bytes through a seam that promises Noise.
public struct NoiseTransportCrypto: TransportCrypto {
    public init() {}

    public var modeDescription: String {
        "Noise IK (unimplemented — W5 pending)"
    }

    public func open() throws {
        throw TransportCryptoError.noisePending(
            "Noise transport-open unimplemented — W5 pending; use --insecure for the recorded CP-3 fallback")
    }

    public func unseal(
        wirePayload: ArraySlice<UInt8>,
        aad: ArraySlice<UInt8>,
        envelope: Envelope
    ) throws -> ArraySlice<UInt8> {
        throw TransportCryptoError.noisePending("Noise unseal unimplemented — W5 pending")
    }
}
