// The stateless retry cookie (core plan §5: "Core provides a stateless
// HMAC retry-cookie codec for the first handshake datagram; the host
// shell decides when to demand it") — QUIC Retry's shape without QUIC.
// A Noise message 1 costs the responder an X25519 before anything is
// authenticated; under a msg1 flood the host escalates from its token
// bucket (HS-9's HandshakeGate) to cookie mode: answer each msg1 with a
// RetryChallenge carrying a cookie minted from (client tuple, now,
// secret) — NO per-client state allocated — and process only msg1s that
// come back inside a RetryHandshake1 whose cookie verifies. Proving the
// cookie proves the sender receives at the claimed address; blind
// spoofers never graduate to costing crypto.
//
// Cookie interior (opaque to the client, echoed verbatim; both mint and
// verify are host-side, but the layout is wire contract because the
// bytes travel):
//
//   offset size field
//   0      8    timestamp  u64 LE, the host's injected monotonic ns at
//                          mint — never interpreted by the client
//   8      16   mac        HMAC-SHA256 truncated to 16 bytes (the W5
//                          16-byte-proof precedent), keyed by the host's
//                          cookie secret, over the transcript
//                            "lyte-retry-cookie-v1"
//                            ‖ timestamp u64 LE
//                            ‖ tupleLen u8 ‖ tuple
//                            ‖ message1
//
// Bindings, and why each is in the transcript:
// - the CLIENT TUPLE (the host's own serialization of the source
//   address — opaque bytes here, sans-IO; only the minter ever parses
//   it) — the cookie proves ownership of exactly that address;
// - the TIMESTAMP — verify enforces `mintTime ≤ now ≤ mintTime +
//   lifetime`, so a harvested cookie dies quickly and a forged future
//   stamp is rejected outright (one monotonic host clock mints and
//   verifies — skew is not a thing here);
// - MESSAGE 1, whole and verbatim — the resubmission must carry the
//   exact msg1 the challenge answered, which the client already
//   guarantees (0443beb's hard-won rule: ONE msg1 retransmitted
//   verbatim across the retry window, never a fresh session per
//   attempt), so one cookie cannot be replayed under a different
//   handshake from the same address.
//
// Rotation: the host rotates its cookie secret on its own schedule and
// hands `verify` the ordered list [current, previous]; a cookie minted
// just before a rotation still verifies under the previous key until
// the lifetime window closes it. Verification is one HMAC per candidate
// secret — still far cheaper than the X25519 it gates.
//
// Sans-IO: `now` is injected monotonic ns (the HandshakeGate
// convention); the secret is injected bytes; randomness is not needed.
// Constant-time caveat (reviewed and CONFIRMED SOUND by the pre-H1
// Crypto/ review): the MAC comparison is constant-time via
// CPace.constantTimeEquals and the secrets loop never early-exits, but
// the length/window pre-checks return early — they gate exclusively on
// values the sender chose or already knows (cookie length, its own
// tuple length, the timestamp it echoed back), never on key material or
// any MAC computation, so their timing tells an attacker nothing it
// didn't tell itself.

import Crypto

/// Structural misuse of `mint` — caller bugs, thrown loudly. Hostile
/// input never reaches mint; `verify` answers hostile input with
/// `false`, cheaply and quietly.
public enum RetryCookieError: Error, Hashable, Sendable {
    case invalidSecretLength(Int)
    case invalidTupleLength(Int)
}

public enum RetryCookie {
    /// The truncated-HMAC proof — the W5 16-byte precedent.
    public static let macByteCount = 16
    /// timestamp(8) ‖ mac(16).
    public static let byteCount = 8 + macByteCount
    /// Cookie secrets are one HMAC-SHA256 key's worth of entropy.
    public static let secretByteCount = 32
    /// How long a minted cookie verifies. Generous against the
    /// Wi-Fi-power-save latencies 0443beb documented (msg1 delivered
    /// seconds late), still short enough that a harvested cookie is
    /// near-worthless.
    public static let defaultLifetimeNanoseconds: UInt64 = 30_000_000_000

    static let domainSeparator: [UInt8] = Array("lyte-retry-cookie-v1".utf8)

    /// Mints the 24-byte cookie for one (tuple, msg1) at `now`. Pure:
    /// same inputs, same bytes — which is what lets the host answer a
    /// flood without remembering anything.
    public static func mint(
        clientTuple: [UInt8],
        message1: ArraySlice<UInt8>,
        now: UInt64,
        secret: [UInt8]
    ) throws -> [UInt8] {
        guard secret.count == secretByteCount else {
            throw RetryCookieError.invalidSecretLength(secret.count)
        }
        guard (1...255).contains(clientTuple.count) else {
            throw RetryCookieError.invalidTupleLength(clientTuple.count)
        }
        var out = [UInt8]()
        out.reserveCapacity(byteCount)
        wireAppendLE(now, to: &out)
        out += mac(
            timestamp: now, clientTuple: clientTuple,
            message1: message1, secret: secret
        )
        return out
    }

    public static func mint(
        clientTuple: [UInt8],
        message1: [UInt8],
        now: UInt64,
        secret: [UInt8]
    ) throws -> [UInt8] {
        try mint(
            clientTuple: clientTuple, message1: message1[...],
            now: now, secret: secret
        )
    }

    /// True iff the cookie was minted by one of `secrets` for exactly
    /// this (tuple, msg1) within the lifetime window ending at `now`.
    /// `secrets` is ordered current-first; entries of the wrong length
    /// are skipped (they can never have minted anything). Any
    /// malformed input is simply `false` — the flood path must be
    /// cheap and quiet, never a throw site.
    public static func verify(
        cookie: ArraySlice<UInt8>,
        clientTuple: [UInt8],
        message1: ArraySlice<UInt8>,
        now: UInt64,
        secrets: [[UInt8]],
        lifetimeNanoseconds: UInt64 = defaultLifetimeNanoseconds
    ) -> Bool {
        guard cookie.count == byteCount else { return false }
        guard (1...255).contains(clientTuple.count) else { return false }
        let base = cookie.startIndex
        let timestamp: UInt64 = wireReadLE(cookie, at: base)
        // The window: a future stamp is a forgery (the same monotonic
        // clock minted it), a stale one is a harvested cookie.
        guard timestamp <= now, now - timestamp <= lifetimeNanoseconds
        else { return false }
        let presented = Array(cookie[(base + 8)...])
        // No early exit: every candidate secret costs its HMAC, so
        // timing never says which key (if any) matched.
        var valid = false
        for secret in secrets where secret.count == secretByteCount {
            let expected = mac(
                timestamp: timestamp, clientTuple: clientTuple,
                message1: message1, secret: secret
            )
            if CPace.constantTimeEquals(expected, presented) {
                valid = true
            }
        }
        return valid
    }

    public static func verify(
        cookie: [UInt8],
        clientTuple: [UInt8],
        message1: [UInt8],
        now: UInt64,
        secrets: [[UInt8]],
        lifetimeNanoseconds: UInt64 = defaultLifetimeNanoseconds
    ) -> Bool {
        verify(
            cookie: cookie[...], clientTuple: clientTuple,
            message1: message1[...], now: now, secrets: secrets,
            lifetimeNanoseconds: lifetimeNanoseconds
        )
    }

    /// The truncated transcript MAC. The transcript is unambiguous by
    /// construction: fixed-width timestamp, length-prefixed tuple,
    /// message 1 as the sole trailing field.
    private static func mac(
        timestamp: UInt64,
        clientTuple: [UInt8],
        message1: ArraySlice<UInt8>,
        secret: [UInt8]
    ) -> [UInt8] {
        var transcript = domainSeparator
        wireAppendLE(timestamp, to: &transcript)
        transcript.append(UInt8(clientTuple.count))
        transcript += clientTuple
        transcript += message1
        return Array(
            HMAC<SHA256>.authenticationCode(
                for: transcript, using: SymmetricKey(data: secret)
            ).prefix(macByteCount)
        )
    }
}
