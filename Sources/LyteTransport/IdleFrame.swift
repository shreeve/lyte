// IdleFrame (CL-8): the client-side mirror of HS-11's host-pinned
// reliable idle-frame message — the ratchet's final converged frame,
// re-sent on a reliable ARQ ONE-SHOT group so a lost last refinement can
// never leave a stale screen. The host's SessionStateMachine flips
// ACTIVE→IDLE only when this message's group is fully acknowledged, and
// the acknowledgment is nothing extra here: ReliableCtrlEndpoint's
// ingest ACKs the one-shot in the same pass that delivers it.
//
// BYTE MIRROR of Host/Sources/HostWire/IdleFrame.swift — the HS-7/HS-8
// precedent (0x03–0x06, 0x10 all rode end-side pins before their
// codec-unification promotion). The type byte 0x15 is pinned host-side
// FIRST (first past W8's 0x13/0x14, the registry's high-water mark);
// promotion into LyteWire.CtrlMessageType is a file move plus a registry
// append owned by a Wire/ slice — the bytes never change, and both
// copies delete together when it lands.
//
// Carriage note: chan 4 (videoIdle, reliableOneShotGroups) is this
// message's eventual home; today it rides the CTRL endpoint's one-shot
// groups because that is the reliable sublayer both ends possess.
// Moving carriage changes routing, not message bytes or semantics.
//
// Layout, 13-byte header + the frame, multi-byte fields little-endian:
//
//   offset size field
//   0      1    type       0x15
//   1      4    frame      u32, the frame number the converged frame
//                          was last sent with on the datagram path —
//                          the receiver's dedupe handle
//   5      8    timestamp  u64 capture µs (host graph clock), verbatim
//                          from the retained frame
//   13     …    annexB     the converged frame's Annex-B bytes, to the
//                          end of the ARQ-delivered message
//
// Truncation below the header rejects; an empty frame body rejects (a
// frameless idle frame is a construction bug); a foreign type byte
// rejects with what it found. Never traps on hostile bytes.

import LyteWire

/// Client-side-pinned CTRL type bytes awaiting promotion into
/// LyteWire.CtrlMessageType (see the file comment).
public enum ClientCtrlMessageType {
    /// The reliable idle-frame message (HS-11 → CL-8).
    public static let idleFrame: UInt8 = 0x15
}

/// The reliable idle-frame message (type 0x15).
public struct IdleFrame: Hashable, Sendable {
    /// The frame number this frame last rode the datagram path with.
    public var frame: FrameNumber
    /// The retained frame's capture stamp (host graph-clock µs).
    public var captureTimestampMicroseconds: UInt64
    /// The converged frame's Annex-B bytes.
    public var annexB: [UInt8]

    public init(
        frame: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        annexB: [UInt8]
    ) {
        self.frame = frame
        self.captureTimestampMicroseconds = captureTimestampMicroseconds
        self.annexB = annexB
    }

    public static let headerByteCount = 13

    /// Encodes header + frame, type byte included. Cannot fail.
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Self.headerByteCount + annexB.count)
        out.append(ClientCtrlMessageType.idleFrame)
        for shift in stride(from: 0, to: 32, by: 8) {
            out.append(UInt8(truncatingIfNeeded: frame.rawValue >> shift))
        }
        for shift in stride(from: 0, to: 64, by: 8) {
            out.append(UInt8(
                truncatingIfNeeded: captureTimestampMicroseconds >> shift
            ))
        }
        out.append(contentsOf: annexB)
        return out
    }

    /// Decodes a whole ARQ-delivered message (type byte first). Throws
    /// on the wrong type, truncation, and an empty frame body; never
    /// traps on hostile bytes.
    public static func decode(_ payload: ArraySlice<UInt8>) throws -> IdleFrame {
        guard payload.count > headerByteCount else {
            throw IdleFrameError.truncatedMessage
        }
        let base = payload.startIndex
        guard payload[base] == ClientCtrlMessageType.idleFrame else {
            throw IdleFrameError.unexpectedType(payload[base])
        }
        var frame: UInt32 = 0
        for i in 0..<4 {
            frame |= UInt32(payload[base + 1 + i]) << (8 * i)
        }
        var micros: UInt64 = 0
        for i in 0..<8 {
            micros |= UInt64(payload[base + 5 + i]) << (8 * i)
        }
        return IdleFrame(
            frame: FrameNumber(rawValue: frame),
            captureTimestampMicroseconds: micros,
            annexB: Array(payload[(base + headerByteCount)...])
        )
    }

    public static func decode(_ payload: [UInt8]) throws -> IdleFrame {
        try decode(payload[...])
    }
}

public enum IdleFrameError: Error, Equatable, Sendable {
    case truncatedMessage
    case unexpectedType(UInt8)
}
