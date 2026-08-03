// The retry-cookie message pair (CTRL types 0x13/0x14) — the wire half
// of the stateless msg1-flood defense (core plan §5; RetryCookie.swift
// owns the mint/verify crypto). Both are bare pre-transport CTRL
// datagrams like the handshake carriage 0x05/0x06: no session exists
// yet, so nothing seals them, and they are ARQ-exempt by nature — a
// lost challenge is answered by the client's own msg1 retransmit timer
// drawing a fresh one.
//
// Flow, host under flood: msg1 (0x05) arrives → host answers with a
// RetryChallenge (0x13) carrying a cookie minted statelessly from
// (source tuple, now, secret) and forgets the exchange entirely → the
// honest client resubmits as a RetryHandshake1 (0x14) = the SAME msg1
// verbatim (0443beb's rule) with the cookie echoed → host verifies the
// cookie against the tuple the datagram actually came from and, only
// then, spends the Noise crypto. A spoofer never sees the challenge; a
// replayer is closed out by the cookie's lifetime window and its
// binding to one exact msg1.
//
// The cookie is OPAQUE to the client — echoed verbatim, never parsed —
// so the codec carries it length-prefixed (1…255 bytes) and the host
// may evolve the interior without touching this layout. RetryCookie's
// v1 interior is 24 bytes; the vectors pin that size, the codec does
// not.
//
// Retry challenge (type 0x13), host→client, 2 + cookieLen bytes:
//
//   offset size field
//   0      1    type       0x13
//   1      1    cookieLen  1…255 (0 is the loud zero-fill bug)
//   2      …    cookie     opaque, echoed verbatim in the resubmission
//
// Retry handshake 1 (type 0x14), client→host, 2 + cookieLen + |msg1|:
//
//   offset size field
//   0      1    type       0x14
//   1      1    cookieLen  1…255
//   2      …    cookie     the challenge's cookie, verbatim
//   …      …    message1   the raw Noise IK message 1, verbatim — the
//                          remainder of the payload, self-delimiting
//                          because msg1 is the sole trailing field
//
// The challenge is exactly its layout (trailing bytes reject); the
// resubmission's message 1 must be at least msg1's structural minimum
// (32 + 48 + 16) — anything shorter could never handshake and is
// refused before the host does cookie work.

/// Everything the retry codecs can refuse. Hostile bytes throw, never
/// trap.
public enum RetryMessageError: Error, Hashable, Sendable {
    case truncatedMessage
    case trailingBytes
    case unexpectedType(UInt8)
    case zeroCookieLength
    case invalidCookieLength(Int)
    case message1TooShort(Int)
}

/// The host's stateless answer to a msg1 it will not yet pay for
/// (type 0x13).
public struct RetryChallenge: Hashable, Sendable {
    public var cookie: [UInt8]

    public init(cookie: [UInt8]) {
        self.cookie = cookie
    }

    /// Encodes the 2 + cookieLen message. Throws on a cookie outside
    /// 1…255 bytes.
    public func encode() throws -> [UInt8] {
        guard (1...255).contains(cookie.count) else {
            throw RetryMessageError.invalidCookieLength(cookie.count)
        }
        return [CtrlMessageType.retryChallenge, UInt8(cookie.count)]
            + cookie
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> RetryChallenge {
        let (cookie, remainder) = try decodeRetryHeader(
            payload, type: CtrlMessageType.retryChallenge
        )
        guard remainder.isEmpty else {
            throw RetryMessageError.trailingBytes
        }
        return RetryChallenge(cookie: cookie)
    }

    public static func decode(_ payload: [UInt8]) throws -> RetryChallenge {
        try decode(payload[...])
    }
}

/// The client's msg1 resubmission carrying its cookie (type 0x14).
public struct RetryHandshake1: Hashable, Sendable {
    public var cookie: [UInt8]
    /// The raw Noise IK message 1, byte-identical to the one the
    /// challenge answered — the client's retransmit rule makes that
    /// free, and the cookie's MAC makes it mandatory.
    public var message1: [UInt8]

    public init(cookie: [UInt8], message1: [UInt8]) {
        self.cookie = cookie
        self.message1 = message1
    }

    /// The well-formed resubmission — the client-side rule.
    public init(echoing challenge: RetryChallenge, message1: [UInt8]) {
        self.init(cookie: challenge.cookie, message1: message1)
    }

    /// Encodes 2 + cookieLen + |msg1| bytes. Throws on a cookie
    /// outside 1…255 bytes or a msg1 below its structural minimum.
    public func encode() throws -> [UInt8] {
        guard (1...255).contains(cookie.count) else {
            throw RetryMessageError.invalidCookieLength(cookie.count)
        }
        guard message1.count >= NoiseHandshake.message1MinimumByteCount
        else {
            throw RetryMessageError.message1TooShort(message1.count)
        }
        return [CtrlMessageType.retryHandshake1, UInt8(cookie.count)]
            + cookie + message1
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> RetryHandshake1 {
        let (cookie, remainder) = try decodeRetryHeader(
            payload, type: CtrlMessageType.retryHandshake1
        )
        guard remainder.count >= NoiseHandshake.message1MinimumByteCount
        else {
            throw RetryMessageError.message1TooShort(remainder.count)
        }
        return RetryHandshake1(
            cookie: cookie, message1: Array(remainder)
        )
    }

    public static func decode(_ payload: [UInt8]) throws -> RetryHandshake1 {
        try decode(payload[...])
    }
}

/// The shared `type ‖ cookieLen ‖ cookie` prefix: returns the cookie
/// and whatever follows it.
private func decodeRetryHeader(
    _ payload: ArraySlice<UInt8>, type: UInt8
) throws -> (cookie: [UInt8], remainder: ArraySlice<UInt8>) {
    guard payload.count >= 2 else {
        throw RetryMessageError.truncatedMessage
    }
    let base = payload.startIndex
    guard payload[base] == type else {
        throw RetryMessageError.unexpectedType(payload[base])
    }
    let cookieLength = Int(payload[base + 1])
    guard cookieLength > 0 else {
        throw RetryMessageError.zeroCookieLength
    }
    guard payload.count >= 2 + cookieLength else {
        throw RetryMessageError.truncatedMessage
    }
    let cookieEnd = base + 2 + cookieLength
    return (
        cookie: Array(payload[(base + 2)..<cookieEnd]),
        remainder: payload[cookieEnd...]
    )
}
