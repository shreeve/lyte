// Retry-cookie vector authoring (W8, the HS-9 deferred flood
// hardening): RetryCookie's transcript MAC frozen as data, plus the
// CTRL 0x13/0x14 codec layouts. Run once, commit, freeze. The
// circularity is broken twice over: the codec bytes are anchored by
// the hand-built layouts in RetryCodecTests, and the MAC beneath the
// cookie vectors is anchored in RetryCookieTests against an
// independent RFC 2104 HMAC over TestKit's FIPS-verified Sha256.

import LyteWire
import LyteWireTestKit

func makeRetryVectorFile() throws -> RetryVectorFile {
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
    let alteredMessage1 = message1.prefix(40) + [message1[40] ^ 0x01]
        + message1.dropFirst(41)
    let mintNow: UInt64 = 5_000_000_000

    let cookie = try RetryCookie.mint(
        clientTuple: tuple, message1: message1,
        now: mintNow, secret: secret
    )

    var cookieVectors: [RetryCookieVector] = []
    let pinned = "pinned-self-consistent"

    // MARK: Mint rows — the exact cookie bytes, then the decisions.

    cookieVectors.append(RetryCookieVector(
        name: "mint-nominal",
        description: "The reference mint: (tuple, msg1, now, secret) →"
            + " these exact 24 bytes, verifying fresh under the minting"
            + " secret. Stateless: same inputs always yield these bytes.",
        provenance: pinned,
        kind: .mint,
        tupleHex: Hex.string(tuple),
        message1Hex: Hex.string(message1),
        mintNowHex: Hex.uint64String(mintNow),
        secretHex: Hex.string(secret),
        cookieHex: Hex.string(cookie),
        verifyNowHex: Hex.uint64String(mintNow + 200_000_000),
        secretsHex: [Hex.string(secret)],
        valid: true
    ))
    cookieVectors.append(RetryCookieVector(
        name: "mint-verify-at-lifetime-edge",
        description: "Verification at exactly mint + lifetime still"
            + " accepts — the window is closed-ended.",
        provenance: pinned,
        kind: .mint,
        tupleHex: Hex.string(tuple),
        message1Hex: Hex.string(message1),
        mintNowHex: Hex.uint64String(mintNow),
        secretHex: Hex.string(secret),
        cookieHex: Hex.string(cookie),
        verifyNowHex: Hex.uint64String(
            mintNow + RetryCookie.defaultLifetimeNanoseconds
        ),
        secretsHex: [Hex.string(secret)],
        valid: true
    ))
    cookieVectors.append(RetryCookieVector(
        name: "mint-expired",
        description: "One nanosecond past the lifetime: a harvested"
            + " cookie is dead.",
        provenance: pinned,
        kind: .mint,
        tupleHex: Hex.string(tuple),
        message1Hex: Hex.string(message1),
        mintNowHex: Hex.uint64String(mintNow),
        secretHex: Hex.string(secret),
        cookieHex: Hex.string(cookie),
        verifyNowHex: Hex.uint64String(
            mintNow + RetryCookie.defaultLifetimeNanoseconds + 1
        ),
        secretsHex: [Hex.string(secret)],
        valid: false
    ))
    cookieVectors.append(RetryCookieVector(
        name: "mint-future-stamp",
        description: "A timestamp from the future rejects outright —"
            + " one monotonic host clock mints and verifies, so a"
            + " future stamp is a forgery.",
        provenance: pinned,
        kind: .mint,
        tupleHex: Hex.string(tuple),
        message1Hex: Hex.string(message1),
        mintNowHex: Hex.uint64String(mintNow),
        secretHex: Hex.string(secret),
        cookieHex: Hex.string(cookie),
        verifyNowHex: Hex.uint64String(mintNow - 1),
        secretsHex: [Hex.string(secret)],
        valid: false
    ))
    cookieVectors.append(RetryCookieVector(
        name: "mint-custom-lifetime",
        description: "A caller-chosen 1 ms lifetime is honored: this"
            + " verify sits past it and rejects.",
        provenance: pinned,
        kind: .mint,
        tupleHex: Hex.string(tuple),
        message1Hex: Hex.string(message1),
        mintNowHex: Hex.uint64String(mintNow),
        secretHex: Hex.string(secret),
        cookieHex: Hex.string(cookie),
        verifyNowHex: Hex.uint64String(mintNow + 1_000_001),
        secretsHex: [Hex.string(secret)],
        lifetimeHex: Hex.uint64String(1_000_000),
        valid: false
    ))
    cookieVectors.append(RetryCookieVector(
        name: "mint-rotation-previous-secret",
        description: "After rotation the previous secret (second in"
            + " the current-first list) still verifies the cookie it"
            + " minted.",
        provenance: pinned,
        kind: .mint,
        tupleHex: Hex.string(tuple),
        message1Hex: Hex.string(message1),
        mintNowHex: Hex.uint64String(mintNow),
        secretHex: Hex.string(secret),
        cookieHex: Hex.string(cookie),
        verifyNowHex: Hex.uint64String(mintNow + 200_000_000),
        secretsHex: [Hex.string(rotatedSecret), Hex.string(secret)],
        valid: true
    ))
    cookieVectors.append(RetryCookieVector(
        name: "mint-rotated-out",
        description: "The minting secret rotated fully out of the"
            + " list: reject — rotation tolerance is exactly one"
            + " configured window, not forever.",
        provenance: pinned,
        kind: .mint,
        tupleHex: Hex.string(tuple),
        message1Hex: Hex.string(message1),
        mintNowHex: Hex.uint64String(mintNow),
        secretHex: Hex.string(secret),
        cookieHex: Hex.string(cookie),
        verifyNowHex: Hex.uint64String(mintNow + 200_000_000),
        secretsHex: [Hex.string(rotatedSecret)],
        valid: false
    ))

    // MARK: Verify rows — presented bytes, no mint step.

    cookieVectors.append(RetryCookieVector(
        name: "verify-foreign-tuple",
        description: "The nominal cookie presented from a different"
            + " address: reject — address ownership is the whole"
            + " point.",
        provenance: pinned,
        kind: .verify,
        tupleHex: Hex.string(movedTuple),
        message1Hex: Hex.string(message1),
        cookieHex: Hex.string(cookie),
        verifyNowHex: Hex.uint64String(mintNow + 200_000_000),
        secretsHex: [Hex.string(secret)],
        valid: false
    ))
    cookieVectors.append(RetryCookieVector(
        name: "verify-altered-message1",
        description: "Same address, one msg1 byte flipped: reject —"
            + " one cookie authorizes one exact handshake attempt.",
        provenance: pinned,
        kind: .verify,
        tupleHex: Hex.string(tuple),
        message1Hex: Hex.string(Array(alteredMessage1)),
        cookieHex: Hex.string(cookie),
        verifyNowHex: Hex.uint64String(mintNow + 200_000_000),
        secretsHex: [Hex.string(secret)],
        valid: false
    ))
    var tamperedMac = cookie
    tamperedMac[8] ^= 0x01
    cookieVectors.append(RetryCookieVector(
        name: "verify-tampered-mac",
        description: "First MAC byte flipped: reject.",
        provenance: pinned,
        kind: .verify,
        tupleHex: Hex.string(tuple),
        message1Hex: Hex.string(message1),
        cookieHex: Hex.string(tamperedMac),
        verifyNowHex: Hex.uint64String(mintNow + 200_000_000),
        secretsHex: [Hex.string(secret)],
        valid: false
    ))
    var tamperedStamp = cookie
    tamperedStamp[0] ^= 0x01
    cookieVectors.append(RetryCookieVector(
        name: "verify-tampered-timestamp",
        description: "A timestamp byte flipped: the stamp no longer"
            + " matches the MAC's transcript — reject.",
        provenance: pinned,
        kind: .verify,
        tupleHex: Hex.string(tuple),
        message1Hex: Hex.string(message1),
        cookieHex: Hex.string(tamperedStamp),
        verifyNowHex: Hex.uint64String(mintNow + 200_000_000),
        secretsHex: [Hex.string(secret)],
        valid: false
    ))
    cookieVectors.append(RetryCookieVector(
        name: "verify-truncated-cookie",
        description: "23 bytes where the interior is exactly 24:"
            + " quietly false, never a throw — the flood path stays"
            + " cheap.",
        provenance: pinned,
        kind: .verify,
        tupleHex: Hex.string(tuple),
        message1Hex: Hex.string(message1),
        cookieHex: Hex.string(Array(cookie.dropLast())),
        verifyNowHex: Hex.uint64String(mintNow + 200_000_000),
        secretsHex: [Hex.string(secret)],
        valid: false
    ))

    // MARK: Message codec rows — anchored by RetryCodecTests.

    var messageVectors: [RetryMessageVector] = []
    let codecCookie = counting(from: 0xA0, count: 24)
    let codecMessage1 = counting(from: 0x00, count: 96)

    messageVectors.append(RetryMessageVector(
        name: "challenge-nominal",
        description: "The hand-computed anchor: type ‖ cookieLen 24 ‖"
            + " cookie.",
        kind: .roundtrip,
        codec: .challenge,
        messageHex: Hex.string(
            try RetryChallenge(cookie: codecCookie).encode()
        ),
        cookieHex: Hex.string(codecCookie)
    ))
    messageVectors.append(RetryMessageVector(
        name: "challenge-min-cookie",
        description: "A 1-byte cookie — the codec carries any 1…255"
            + " bytes; the interior size is the minter's business.",
        kind: .roundtrip,
        codec: .challenge,
        messageHex: Hex.string(
            try RetryChallenge(cookie: [0x5A]).encode()
        ),
        cookieHex: Hex.string([0x5A])
    ))
    messageVectors.append(RetryMessageVector(
        name: "challenge-max-cookie",
        description: "A 255-byte cookie — the length byte's ceiling.",
        kind: .roundtrip,
        codec: .challenge,
        messageHex: Hex.string(
            try RetryChallenge(
                cookie: counting(from: 0, count: 255)
            ).encode()
        ),
        cookieHex: Hex.string(counting(from: 0, count: 255))
    ))
    messageVectors.append(RetryMessageVector(
        name: "handshake1-nominal",
        description: "The hand-computed anchor: type ‖ cookieLen 24 ‖"
            + " cookie ‖ msg1 (96 B, the structural minimum).",
        kind: .roundtrip,
        codec: .handshake1,
        messageHex: Hex.string(
            try RetryHandshake1(
                cookie: codecCookie, message1: codecMessage1
            ).encode()
        ),
        cookieHex: Hex.string(codecCookie),
        message1Hex: Hex.string(codecMessage1)
    ))
    messageVectors.append(RetryMessageVector(
        name: "handshake1-real-msg1-shape",
        description: "A 122 B msg1 (version byte + 25 B application"
            + " payload) — msg1 is the sole trailing field,"
            + " self-delimiting.",
        kind: .roundtrip,
        codec: .handshake1,
        messageHex: Hex.string(
            try RetryHandshake1(
                cookie: codecCookie,
                message1: counting(from: 0x10, count: 122)
            ).encode()
        ),
        cookieHex: Hex.string(codecCookie),
        message1Hex: Hex.string(counting(from: 0x10, count: 122))
    ))

    messageVectors.append(RetryMessageVector(
        name: "challenge-truncated-header",
        description: "The type byte alone.",
        kind: .decodeReject, codec: .challenge,
        messageHex: "13", error: "truncatedMessage"
    ))
    messageVectors.append(RetryMessageVector(
        name: "challenge-truncated-cookie",
        description: "cookieLen 24 but only 23 cookie bytes present.",
        kind: .decodeReject, codec: .challenge,
        messageHex: "1318" + Hex.string(counting(from: 0xA0, count: 23)),
        error: "truncatedMessage"
    ))
    messageVectors.append(RetryMessageVector(
        name: "challenge-zero-cookie-len",
        description: "cookieLen 0 — the loud zero-fill bug.",
        kind: .decodeReject, codec: .challenge,
        messageHex: "1300", error: "zeroCookieLength"
    ))
    messageVectors.append(RetryMessageVector(
        name: "challenge-trailing-byte",
        description: "One byte past the cookie — a challenge is"
            + " exactly its layout.",
        kind: .decodeReject, codec: .challenge,
        messageHex: "1318" + Hex.string(codecCookie) + "00",
        error: "trailingBytes"
    ))
    messageVectors.append(RetryMessageVector(
        name: "challenge-bad-type",
        description: "A handshake1 type byte fed to the challenge"
            + " decoder.",
        kind: .decodeReject, codec: .challenge,
        messageHex: "1418" + Hex.string(codecCookie),
        error: "unexpectedType"
    ))
    messageVectors.append(RetryMessageVector(
        name: "handshake1-truncated-cookie",
        description: "cookieLen 24 but the payload ends mid-cookie.",
        kind: .decodeReject, codec: .handshake1,
        messageHex: "1418" + Hex.string(counting(from: 0xA0, count: 10)),
        error: "truncatedMessage"
    ))
    messageVectors.append(RetryMessageVector(
        name: "handshake1-zero-cookie-len",
        description: "cookieLen 0 — the loud zero-fill bug.",
        kind: .decodeReject, codec: .handshake1,
        messageHex: "1400" + Hex.string(codecMessage1),
        error: "zeroCookieLength"
    ))
    messageVectors.append(RetryMessageVector(
        name: "handshake1-msg1-too-short",
        description: "95 B where IK msg1's structural minimum is 96 —"
            + " could never handshake, refused before cookie work.",
        kind: .decodeReject, codec: .handshake1,
        messageHex: "1418" + Hex.string(codecCookie)
            + Hex.string(counting(from: 0, count: 95)),
        error: "message1TooShort"
    ))
    messageVectors.append(RetryMessageVector(
        name: "handshake1-bad-type",
        description: "A challenge type byte fed to the handshake1"
            + " decoder.",
        kind: .decodeReject, codec: .handshake1,
        messageHex: "1318" + Hex.string(codecCookie)
            + Hex.string(codecMessage1),
        error: "unexpectedType"
    ))

    return RetryVectorFile(
        format: RetryVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        cookieVectors: cookieVectors,
        messageVectors: messageVectors
    )
}
