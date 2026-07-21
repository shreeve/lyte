// The IDR-request CTRL message — the on-wire closing of CL-2's
// fecImpossible seam. Build-plan ruling §4.7: at H0b the heal path for an
// unrecoverable frame is IDR-request, NOT NACK — the host's NACK responder
// is HS-17 (H2), and until then the feedback report's NACK section stays
// empty while this message asks for the one thing the host can already do
// (HS-6's pacer has IDR-on-demand from day one).
//
// History: CL-3 pinned the codec in the client package, HS-7 mirrored it
// byte-for-byte host-side (the packages cannot import each other); the
// codec-unification slice reconciles both copies into this one canonical
// codec. Type byte 0x10, client→host, sealed, ARQ-exempt fire-and-forget:
// a lost request is superseded by the requester's next coalesced emission.
//
// Layout, fixed 10 bytes, multi-byte fields little-endian:
//
//   offset size field
//   0      1    type            0x10
//   1      4    requestSeq      u32, from 0 per session, one per emitted
//                               request — the host's dedupe/log handle
//   5      4    frame           u32, the newest frame written off as
//                               FEC-impossible when this request fired
//   9      1    coalescedCount  how many fecImpossible verdicts this
//                               request covers (≥1; saturates at 255) —
//                               burst-severity evidence for the host
//
// Exactly its fixed size: truncation and trailing bytes reject, a foreign
// type byte rejects with what it found (the beacon codecs' doctrine).

public struct IdrRequest: Hashable, Sendable {
    public var requestSeq: UInt32
    /// The newest FEC-impossible frame at emit time.
    public var frame: FrameNumber
    /// fecImpossible verdicts covered by this request, saturating at 255.
    public var coalescedCount: UInt8

    public init(requestSeq: UInt32, frame: FrameNumber, coalescedCount: UInt8) {
        self.requestSeq = requestSeq
        self.frame = frame
        self.coalescedCount = coalescedCount
    }

    public static let encodedByteCount = 10

    /// Encodes the 10-byte message, type byte included. Cannot fail.
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Self.encodedByteCount)
        out.append(CtrlMessageType.idrRequest)
        wireAppendLE(requestSeq, to: &out)
        wireAppendLE(frame.rawValue, to: &out)
        out.append(coalescedCount)
        return out
    }

    /// Decodes a whole CTRL payload (type byte first). Throws on the wrong
    /// type, truncation, and trailing bytes; never traps on hostile bytes.
    public static func decode(_ payload: ArraySlice<UInt8>) throws -> IdrRequest {
        guard payload.count >= encodedByteCount else {
            throw IdrRequestError.truncatedMessage
        }
        guard payload.count == encodedByteCount else {
            throw IdrRequestError.trailingBytes
        }
        let base = payload.startIndex
        guard payload[base] == CtrlMessageType.idrRequest else {
            throw IdrRequestError.unexpectedType(payload[base])
        }
        return IdrRequest(
            requestSeq: wireReadLE(payload, at: base + 1),
            frame: FrameNumber(rawValue: wireReadLE(payload, at: base + 5)),
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
