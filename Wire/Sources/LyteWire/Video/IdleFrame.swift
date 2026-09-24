// IdleFrame (HS-11 → CL-8, promoted home by the second codec-promotion
// slice — the bytes never changed): the ratchet's final converged frame,
// re-sent on a reliable ARQ ONE-SHOT group so a lost last refinement can
// never leave a stale screen (overview §2, the ratchet-boundary ruling).
// The sender's SessionStateMachine flips ACTIVE→IDLE only when this
// message's group is fully acknowledged — one-shot groups are unordered
// against the CTRL stream, so the ack is what guarantees the receiver
// holds the converged frame before it learns the session went idle.
//
// Type byte 0x15 was pinned host-side first (the HS-7/HS-12 precedent),
// byte-mirrored client-side at CL-8, and lands in the registry here —
// the number carried verbatim; both ends already speak it.
//
// Carriage note: the ChannelId registry reserves chan 4 (videoIdle,
// reliableOneShotGroups) as the idle frames' eventual home. This
// message rides the CTRL endpoint's one-shot groups instead, because
// that is the reliable sublayer BOTH ends possess today — moving
// carriage to a chan-4 endpoint changes routing, not message bytes or
// semantics.
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
        out.append(CtrlMessageType.idleFrame)
        wireAppendLE(frame.rawValue, to: &out)
        wireAppendLE(captureTimestampMicroseconds, to: &out)
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
        guard payload[base] == CtrlMessageType.idleFrame else {
            throw IdleFrameError.unexpectedType(payload[base])
        }
        return IdleFrame(
            frame: FrameNumber(rawValue: wireReadLE(payload, at: base + 1)),
            captureTimestampMicroseconds: wireReadLE(payload, at: base + 5),
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
