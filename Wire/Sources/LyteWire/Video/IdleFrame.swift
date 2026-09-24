// IdleFrame: the ratchet's final converged frame, re-sent on a reliable
// ARQ one-shot group so a lost last refinement can never leave a stale
// screen. The sender flips ACTIVE→IDLE only when this group is fully
// acknowledged (see SessionStateMachine).
//
// It rides the CTRL endpoint's one-shot groups; moving it to a chan-4
// (videoIdle) endpoint would change routing, not message bytes.
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
// Truncation below the header and an empty frame body reject; a foreign
// type byte rejects with what it found. Never traps on hostile bytes.

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
