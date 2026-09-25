// Authors Vectors/retry-v1.json: RetryCookie's transcript MAC and the
// CTRL 0x13/0x14 layouts. Anchored by RetryCodecTests, and the MAC by
// RetryCookieTests against an independent RFC 2104 HMAC.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeRetryVectorFile() throws -> RetryVectorFile {
    // Counting-byte fixtures, auditable by eye.
    let secret = counting(from: 0x40, count: RetryCookie.secretByteCount)
    let rotatedSecret = counting(
        from: 0x80, count: RetryCookie.secretByteCount
    )
    // An IPv4:port tuple as the host would serialize it (opaque bytes
    // to the codec — the minter owns the serialization).
    let tuple: [UInt8] = [10, 0, 0, 249, 0xA0, 0x2B]
    let movedTuple: [UInt8] = [10, 0, 0, 250, 0xA0, 0x2B]
    // msg1-shaped counting bytes at the IK structural minimum
    // (e ‖ enc(s) ‖ enc(version byte)): 32 + 48 + 17.
    let message1 = counting(from: 0x00, count: 97)
    let alteredMessage1 = Array(
        message1.prefix(40) + [message1[40] ^ 0x01] + message1.dropFirst(41)
    )
    let mintNow: UInt64 = 5_000_000_000

    let cookie = try RetryCookie.mint(
        clientTuple: tuple, message1: message1,
        now: mintNow, secret: secret
    )

    var cookieVectors: [RetryCookieVector] = []
    let pinned = "pinned-self-consistent"
    let later = mintNow + 200_000_000
    let lifetime = RetryCookie.defaultLifetimeNanoseconds

    // MARK: Mint rows — the exact cookie bytes, then the decisions.

    for (name, description, verifyNow, secrets, lifetimeHex, valid) in [
        ("mint-nominal",
         "The reference mint: (tuple, msg1, now, secret) → these exact 24 "
            + "bytes, verifying fresh under the minting secret. Stateless: "
            + "same inputs always yield these bytes.",
         later, [secret], nil, true),
        ("mint-verify-at-lifetime-edge",
         "Verification at exactly mint + lifetime still accepts — the "
            + "window is closed-ended.",
         mintNow + lifetime, [secret], nil, true),
        ("mint-expired",
         "One nanosecond past the lifetime: a harvested cookie is dead.",
         mintNow + lifetime + 1, [secret], nil, false),
        ("mint-future-stamp",
         "A timestamp from the future rejects outright — one monotonic host "
            + "clock mints and verifies, so a future stamp is a forgery.",
         mintNow - 1, [secret], nil, false),
        ("mint-custom-lifetime",
         "A caller-chosen 1 ms lifetime is honored: this verify sits past it "
            + "and rejects.",
         mintNow + 1_000_001, [secret], Hex.uint64String(1_000_000), false),
        ("mint-rotation-previous-secret",
         "After rotation the previous secret (second in the current-first "
            + "list) still verifies the cookie it minted.",
         later, [rotatedSecret, secret], nil, true),
        ("mint-rotated-out",
         "The minting secret rotated fully out of the list: reject — "
            + "rotation tolerance is exactly one configured window, not "
            + "forever.",
         later, [rotatedSecret], nil, false),
    ] as [(String, String, UInt64, [[UInt8]], String?, Bool)] {
        cookieVectors.append(RetryCookieVector(
            name: name, description: description, provenance: pinned,
            kind: .mint,
            tupleHex: Hex.string(tuple),
            message1Hex: Hex.string(message1),
            mintNowHex: Hex.uint64String(mintNow),
            secretHex: Hex.string(secret),
            cookieHex: Hex.string(cookie),
            verifyNowHex: Hex.uint64String(verifyNow),
            secretsHex: secrets.map { Hex.string($0) },
            lifetimeHex: lifetimeHex,
            valid: valid
        ))
    }

    // MARK: Verify rows — presented bytes, no mint step.

    var tamperedMac = cookie
    tamperedMac[8] ^= 0x01
    var tamperedStamp = cookie
    tamperedStamp[0] ^= 0x01
    for (name, description, presentedTuple, presentedMessage1, presented) in [
        ("verify-foreign-tuple",
         "The nominal cookie presented from a different address: reject — "
            + "address ownership is the whole point.",
         movedTuple, message1, cookie),
        ("verify-altered-message1",
         "Same address, one msg1 byte flipped: reject — one cookie "
            + "authorizes one exact handshake attempt.",
         tuple, alteredMessage1, cookie),
        ("verify-tampered-mac", "First MAC byte flipped: reject.",
         tuple, message1, tamperedMac),
        ("verify-tampered-timestamp",
         "A timestamp byte flipped: the stamp no longer matches the MAC's "
            + "transcript — reject.",
         tuple, message1, tamperedStamp),
        ("verify-truncated-cookie",
         "23 bytes where the interior is exactly 24: quietly false, never a "
            + "throw — the flood path stays cheap.",
         tuple, message1, Array(cookie.dropLast())),
    ] {
        cookieVectors.append(RetryCookieVector(
            name: name, description: description, provenance: pinned,
            kind: .verify,
            tupleHex: Hex.string(presentedTuple),
            message1Hex: Hex.string(presentedMessage1),
            cookieHex: Hex.string(presented),
            verifyNowHex: Hex.uint64String(later),
            secretsHex: [Hex.string(secret)],
            valid: false
        ))
    }

    // MARK: Message codec rows — anchored by RetryCodecTests.

    var messageVectors: [RetryMessageVector] = []
    let codecCookie = counting(from: 0xA0, count: 24)
    let codecMessage1 = counting(from: 0x00, count: 96)

    for (name, description, cookie) in [
        ("challenge-nominal",
         "The hand-computed anchor: type ‖ cookieLen 24 ‖ cookie.",
         codecCookie),
        ("challenge-min-cookie",
         "A 1-byte cookie — the codec carries any 1…255 bytes; the interior "
            + "size is the minter's business.",
         [0x5A]),
        ("challenge-max-cookie",
         "A 255-byte cookie — the length byte's ceiling.",
         counting(from: 0, count: 255)),
    ] {
        messageVectors.append(RetryMessageVector(
            name: name, description: description,
            kind: .roundtrip, codec: .challenge,
            messageHex: Hex.string(try RetryChallenge(cookie: cookie).encode()),
            cookieHex: Hex.string(cookie)
        ))
    }
    for (name, description, message1) in [
        ("handshake1-nominal",
         "The hand-computed anchor: type ‖ cookieLen 24 ‖ cookie ‖ msg1 "
            + "(96 B, the structural minimum).",
         codecMessage1),
        ("handshake1-real-msg1-shape",
         "A 122 B msg1 (version byte + 25 B application payload) — msg1 is "
            + "the sole trailing field, self-delimiting.",
         counting(from: 0x10, count: 122)),
    ] {
        messageVectors.append(RetryMessageVector(
            name: name, description: description,
            kind: .roundtrip, codec: .handshake1,
            messageHex: Hex.string(try RetryHandshake1(
                cookie: codecCookie, message1: message1
            ).encode()),
            cookieHex: Hex.string(codecCookie),
            message1Hex: Hex.string(message1)
        ))
    }

    let cookieHex = Hex.string(codecCookie)
    for (name, description, codec, hex, error) in [
        ("challenge-truncated-header", "The type byte alone.",
         RetryMessageVector.Codec.challenge, "13", "truncatedMessage"),
        ("challenge-truncated-cookie",
         "cookieLen 24 but only 23 cookie bytes present.",
         .challenge, "1318" + Hex.string(counting(from: 0xA0, count: 23)),
         "truncatedMessage"),
        ("challenge-zero-cookie-len", "cookieLen 0 — the loud zero-fill bug.",
         .challenge, "1300", "zeroCookieLength"),
        ("challenge-trailing-byte",
         "One byte past the cookie — a challenge is exactly its layout.",
         .challenge, "1318" + cookieHex + "00", "trailingBytes"),
        ("challenge-bad-type",
         "A handshake1 type byte fed to the challenge decoder.",
         .challenge, "1418" + cookieHex, "unexpectedType"),
        ("handshake1-truncated-cookie",
         "cookieLen 24 but the payload ends mid-cookie.",
         .handshake1, "1418" + Hex.string(counting(from: 0xA0, count: 10)),
         "truncatedMessage"),
        ("handshake1-zero-cookie-len", "cookieLen 0 — the loud zero-fill bug.",
         .handshake1, "1400" + Hex.string(codecMessage1), "zeroCookieLength"),
        ("handshake1-msg1-too-short",
         "95 B where IK msg1's structural minimum is 96 — could never "
            + "handshake, refused before cookie work.",
         .handshake1,
         "1418" + cookieHex + Hex.string(counting(from: 0, count: 95)),
         "message1TooShort"),
        ("handshake1-bad-type",
         "A challenge type byte fed to the handshake1 decoder.",
         .handshake1, "1318" + cookieHex + Hex.string(codecMessage1),
         "unexpectedType"),
    ] {
        messageVectors.append(RetryMessageVector(
            name: name, description: description,
            kind: .decodeReject, codec: codec,
            messageHex: hex, error: error
        ))
    }

    return RetryVectorFile(
        cookieVectors: cookieVectors,
        messageVectors: messageVectors
    )
}
