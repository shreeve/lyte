// The repair-refusal CTRL message: the host's explicit "no" to a NACK, so
// the client can go straight to the (rate-windowed) IDR-request path
// instead of waiting out its repair deadline.
//
// Type byte 0x23, host→client only, sealed, ARQ-exempt fire-and-forget.
// The refusal is a latency optimization, not a correctness signal: a lost
// refusal degrades to the client's repair deadline expiring on its own,
// and nothing may be built that requires a refusal to arrive. For the
// same reason it needs no capability key — clients drop unknown CTRL types.
//
// Layout, fixed 6 bytes, multi-byte fields little-endian:
//
//   offset size field
//   0      1    type    0x23
//   1      4    frame   u32, the NACKed frame this refusal answers
//   5      1    reason  0x01 stale-budget, 0x02 superseded,
//                       0x03 unknown-frame; others reject (0x00 included)
//
// Exactly its fixed size: truncation and trailing bytes reject, a
// foreign type byte rejects with what it found.

/// Why the host refused a repair ask, as the wire carries it. The one
/// refusal the responder deliberately does NOT signal is
/// repairs-already-in-flight (a re-ask for shards that rode their one
/// attempt): a refusal there would push the client to an IDR while the
/// repair may still land — the client's own deadline arbitrates.
/// FROZEN/closed refusals send nothing either (the path is dark).
public enum RepairRefusalReason: UInt8, Hashable, CaseIterable, Sendable {
    /// The freeze budget can no longer be met — the repair would land
    /// after the client's glass gave up on the frame.
    case staleBudget = 0x01
    /// The frame is older than the last IDR — a dead reference; the
    /// newer IDR (in flight or delivered) is the heal.
    case superseded = 0x02
    /// The repair store no longer holds the frame (evicted by age or
    /// byte cap, or never packetized under that number).
    case unknownFrame = 0x03
}

/// The repair-refusal CTRL message (type 0x23, host→client).
public struct RepairRefusal: Hashable, Sendable, SliceDecodable {
    /// The NACKed frame whose ask is being refused.
    public var frame: FrameNumber
    public var reason: RepairRefusalReason

    public init(frame: FrameNumber, reason: RepairRefusalReason) {
        self.frame = frame
        self.reason = reason
    }

    public static let encodedByteCount = 6

    /// Encodes the 6-byte message, type byte included. Cannot fail.
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Self.encodedByteCount)
        out.append(CtrlMessageType.repairRefused)
        wireAppendLE(frame.rawValue, to: &out)
        out.append(reason.rawValue)
        return out
    }

    /// Decodes a whole CTRL payload (type byte first). Throws on the
    /// wrong type, truncation, trailing bytes, and an unknown reason
    /// value; never traps on hostile bytes.
    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> RepairRefusal {
        guard payload.count >= encodedByteCount else {
            throw RepairRefusalError.truncatedMessage
        }
        guard payload.count == encodedByteCount else {
            throw RepairRefusalError.trailingBytes
        }
        let base = payload.startIndex
        guard payload[base] == CtrlMessageType.repairRefused else {
            throw RepairRefusalError.unexpectedType(payload[base])
        }
        guard let reason = RepairRefusalReason(
            rawValue: payload[base + 5]
        ) else {
            throw RepairRefusalError.unknownReason(payload[base + 5])
        }
        return RepairRefusal(
            frame: FrameNumber(rawValue: wireReadLE(payload, at: base + 1)),
            reason: reason
        )
    }
}

/// Everything the repair-refusal codec can refuse. Hostile bytes throw,
/// never trap.
public enum RepairRefusalError: Error, Hashable, Sendable {
    case truncatedMessage
    case trailingBytes
    case unexpectedType(UInt8)
    case unknownReason(UInt8)
}
