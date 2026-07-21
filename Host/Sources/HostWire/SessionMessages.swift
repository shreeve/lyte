// The session stub's CTRL vocabulary (HS-7): the two Noise handshake
// carriage types, plus the host-side mirror of the client's IDR-request
// codec. All pinned HERE, host-side, because W4a's registry stopped at
// 0x02 and Wire/ is not this slice's territory — the same arrangement as
// HS-12's 0x03/0x04 path messages. Promote to LyteWire's CtrlMessageType
// with the next W slice that touches the registry.
//
// Handshake carriage, the "minimal hello" of the HS-7 row — the Noise IK
// handshake IS the session-open exchange, so all that is pinned here is
// how its two messages ride the wire: each travels as one CTRL (chan 0)
// datagram whose payload is the type byte followed by the raw Noise
// message. Handshake payloads are NOT sealed — no transport key exists
// yet; the messages are self-protecting (the IK pattern encrypts and
// authenticates its own payloads, and the version byte rides inside per
// W5's first-payload rule). Everything on CTRL after the handshake
// completes is sealed under the transport with header-as-AAD; a bare
// 0x05/0x06 arriving post-establishment is dropped, not interpreted.
//
//   0x05  noiseHandshake1  client → host  (IK message 1: e, es, s, ss)
//   0x06  noiseHandshake2  host → client  (IK message 2: e, ee, se)
//
// Like every CTRL message so far, both are ARQ-exempt fire-and-forget:
// a lost message 1 is the client's retry (it owns the timer); a lost
// message 2 leads to the same retry, which the host answers from a fresh
// responder state (a half-open handshake never wedges the session).

import LyteWire

extension HostCtrlMessageType {
    /// Client→host Noise IK message 1, bare (pre-transport). The payload
    /// after this byte is the raw handshake message.
    public static let noiseHandshake1: UInt8 = 0x05
    /// Host→client Noise IK message 2, bare (pre-transport).
    public static let noiseHandshake2: UInt8 = 0x06
    /// Client→host IDR request (CL-3's codec, mirrored below). Sealed,
    /// ARQ-exempt; the number is the client package's pin, not ours —
    /// carried here verbatim so both mirrors promote to Wire together.
    public static let idrRequest: UInt8 = 0x10
}

/// Host-side mirror of the client's `IdrRequest` codec (CL-3, root
/// package `LyteTransport/IdrRequest.swift` — the codec of record). The
/// host cannot import the client package, so the 10-byte layout is
/// duplicated byte-for-byte; both copies promote into Wire together.
///
///   offset size field
///   0      1    type            0x10
///   1      4    requestSeq      u32 LE, from 0 per session
///   5      4    frame           u32 LE, newest FEC-impossible frame
///   9      1    coalescedCount  verdicts covered (≥1, saturates 255)
///
/// Exactly its fixed size: truncation and trailing bytes reject, a
/// foreign type byte rejects with what it found (the beacon doctrine).
public struct IdrRequest: Hashable, Sendable {
    public var requestSeq: UInt32
    public var frame: FrameNumber
    public var coalescedCount: UInt8

    public init(requestSeq: UInt32, frame: FrameNumber, coalescedCount: UInt8) {
        self.requestSeq = requestSeq
        self.frame = frame
        self.coalescedCount = coalescedCount
    }

    public static let encodedByteCount = 10

    /// Encodes the 10-byte message, type byte included. Cannot fail.
    /// (The host never sends one; this exists for the loopback tests and
    /// the eventual shared codec.)
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Self.encodedByteCount)
        out.append(HostCtrlMessageType.idrRequest)
        for shift in stride(from: 0, to: 32, by: 8) {
            out.append(UInt8(truncatingIfNeeded: requestSeq >> shift))
        }
        for shift in stride(from: 0, to: 32, by: 8) {
            out.append(UInt8(truncatingIfNeeded: frame.rawValue >> shift))
        }
        out.append(coalescedCount)
        return out
    }

    /// Decodes a whole CTRL payload (type byte first). Throws on the
    /// wrong type, truncation, and trailing bytes; never traps.
    public static func decode(_ payload: ArraySlice<UInt8>) throws -> IdrRequest {
        guard payload.count >= encodedByteCount else {
            throw IdrRequestError.truncatedMessage
        }
        guard payload.count == encodedByteCount else {
            throw IdrRequestError.trailingBytes
        }
        let base = payload.startIndex
        guard payload[base] == HostCtrlMessageType.idrRequest else {
            throw IdrRequestError.unexpectedType(payload[base])
        }
        func le32(_ at: Int) -> UInt32 {
            UInt32(payload[at])
                | UInt32(payload[at + 1]) << 8
                | UInt32(payload[at + 2]) << 16
                | UInt32(payload[at + 3]) << 24
        }
        return IdrRequest(
            requestSeq: le32(base + 1),
            frame: FrameNumber(rawValue: le32(base + 5)),
            coalescedCount: payload[base + 9]
        )
    }

    public static func decode(_ payload: [UInt8]) throws -> IdrRequest {
        try decode(payload[...])
    }
}

public enum IdrRequestError: Error, Equatable, Sendable {
    case truncatedMessage
    case trailingBytes
    case unexpectedType(UInt8)
}
