// Path-validation challenge/response, the anti-spoof half of connection
// migration (resiliency §6: "handshake-free address rebind + anti-spoof
// path validation (echo challenge), per QUIC §9 semantics"). Both ride
// CTRL (chan 0) as ARQ-exempt fire-and-forget datagrams — deliberately,
// like the beacon pair: the challenge MUST travel on the exact unvalidated
// 4-tuple being probed (that is what it proves), and the reliable ARQ
// stream lives on the old path. A lost challenge is superseded by the next
// probe trigger, not retransmitted.
//
// Pinned host-side in HS-12 as 0x03/0x04 (W4a's registry stopped at 0x02);
// promoted here with the codec-unification slice — the client must echo
// these exact bytes.
//
// Both messages are fixed 10 bytes, all multi-byte fields little-endian:
//
//   offset size field
//   0      1    type    0x03 challenge (host→client, on the NEW path) /
//                       0x04 response (client→host, token echoed)
//   1      1    flags   reserved, MUST be 0 on send, ignored on receive
//   2      8    token   random u64 minted per challenge; the response
//                       echoes it verbatim — receipt proves the peer saw
//                       the challenge at the probed address
//
// The envelope wrap (chan 0, the connection-ID TLV so the client can
// attribute the challenge) is the send loop's job, mirroring how ClockBeacon
// leaves body encoding here and datagram framing to the caller.

public enum PathMessageError: Error, Equatable {
    case truncated(Int)
    case unexpectedType(UInt8)
}

public struct PathChallenge: Hashable, Sendable {
    public let token: UInt64

    public init(token: UInt64) {
        self.token = token
    }

    public static let encodedByteCount = 10

    public func encode() -> [UInt8] {
        encodePathMessage(type: CtrlMessageType.pathChallenge,
                          token: token)
    }

    public static func decode(_ payload: [UInt8]) throws -> PathChallenge {
        PathChallenge(token: try decodePathMessage(
            payload, expecting: CtrlMessageType.pathChallenge
        ))
    }
}

public struct PathResponse: Hashable, Sendable {
    public let token: UInt64

    public init(token: UInt64) {
        self.token = token
    }

    public static let encodedByteCount = 10

    public func encode() -> [UInt8] {
        encodePathMessage(type: CtrlMessageType.pathResponse,
                          token: token)
    }

    public static func decode(_ payload: [UInt8]) throws -> PathResponse {
        PathResponse(token: try decodePathMessage(
            payload, expecting: CtrlMessageType.pathResponse
        ))
    }

    /// The well-formed echo of a challenge — the client-side rule.
    public init(echoing challenge: PathChallenge) {
        self.init(token: challenge.token)
    }
}

// MARK: - Shared 10-byte codec

private func encodePathMessage(type: UInt8, token: UInt64) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(PathChallenge.encodedByteCount)
    out.append(type)
    out.append(0) // flags
    wireAppendLE(token, to: &out)
    return out
}

private func decodePathMessage(
    _ payload: [UInt8], expecting type: UInt8
) throws -> UInt64 {
    guard payload.count == PathChallenge.encodedByteCount else {
        throw PathMessageError.truncated(payload.count)
    }
    guard payload[0] == type else {
        throw PathMessageError.unexpectedType(payload[0])
    }
    // payload[1] is flags: reserved bits ignored on receive, house rule.
    return wireReadLE(payload[...], at: 2)
}
