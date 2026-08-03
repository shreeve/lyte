// VideoPostureState (0x26), host→client — the postures design's video
// quiet/wake axis (docs/20260802-013946-postures-design.md). After
// ~30 s without damage the host's 1 s retained keepalive backs off
// exponentially (2 → 4 → 8 → 16 → 30 s); EVERY step rides a fresh
// announcement carrying the interval now in force, so the client's
// freshness contracts arm against the ANNOUNCED heartbeat instead of
// guessing. Damage is its own wake (the frame IS the announcement's
// companion) and client input wakes the posture preemptively — the
// input packet is the wake signal, zero added latency.
//
// CAPABILITY CARRIAGE — key 16 (videoQuietPosture), the W7 spine used
// exactly as keys 9–15 use it: one canonical `10 F5` map entry through
// `unknownEntries`, byte-equal intersection, capabilities-v1.json
// never regenerates. A host never backs off against a set without the
// key — a legacy client keeps today's 1 s keepalive forever.
//
// Layout (ARQ ordered stream — the 0x18/0x19/0x25 carriage argument):
//
//   offset size field
//   0      1    type              0x26
//   1      1    posture           0x01 active / 0x02 quiet
//   2      1    keepaliveSeconds  the interval now in force (1–255;
//                                 active always carries 1)
//
// Unknown postures, a zero interval, trailing bytes, and truncation
// all reject — reliable ordered carriage between negotiated peers,
// so a foreign byte is a protocol break to surface. Never traps.

// MARK: - The capability spine helpers

extension Capabilities {
    /// The key-16 entry as it rides the wire: CBOR bool under
    /// unsigned key 16 (`10 F5` inside the map).
    private static var videoQuietPostureEntry: CborMapEntry {
        CborMapEntry(
            key: .unsigned(CapabilityKey.videoQuietPosture),
            value: .bool(true)
        )
    }

    /// True when this set carries `videoQuietPosture: true`.
    public var videoQuietPosture: Bool {
        unknownEntries.contains(Self.videoQuietPostureEntry)
    }

    /// A copy of this set declaring video-quiet-posture support.
    /// Idempotent; the CBOR encoder owns canonical key order.
    public func declaringVideoQuietPosture() -> Capabilities {
        guard !videoQuietPosture else { return self }
        var declared = self
        declared.unknownEntries.append(Self.videoQuietPostureEntry)
        return declared
    }
}

// MARK: - The CTRL codec

/// The host's video posture announcement (type 0x26).
public struct VideoPostureState: Hashable, Sendable {
    public enum Posture: UInt8, Hashable, CaseIterable, Sendable {
        /// Damage-driven frames with the 1 s retained keepalive.
        case active = 0x01
        /// The keepalive backed off; `keepaliveSeconds` is the
        /// interval now in force. Repeated at every backoff step.
        case quiet = 0x02
    }

    public var posture: Posture
    /// The keepalive interval in force, seconds (1–255; never zero —
    /// "no keepalive at all" is a future posture, not an interval).
    public var keepaliveSeconds: UInt8

    public init(posture: Posture, keepaliveSeconds: UInt8) {
        self.posture = posture
        self.keepaliveSeconds = max(keepaliveSeconds, 1)
    }

    public func encode() -> [UInt8] {
        [CtrlMessageType.videoPostureState, posture.rawValue, keepaliveSeconds]
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> VideoPostureState {
        guard payload.count >= 3 else {
            throw VideoPostureStateError.truncatedMessage
        }
        let base = payload.startIndex
        guard payload[base] == CtrlMessageType.videoPostureState else {
            throw VideoPostureStateError.unexpectedType(payload[base])
        }
        guard payload.count == 3 else {
            throw VideoPostureStateError.trailingBytes(payload.count - 3)
        }
        guard let posture = Posture(rawValue: payload[base + 1]) else {
            throw VideoPostureStateError.unknownPosture(payload[base + 1])
        }
        guard payload[base + 2] > 0 else {
            throw VideoPostureStateError.zeroInterval
        }
        return VideoPostureState(
            posture: posture, keepaliveSeconds: payload[base + 2])
    }

    public static func decode(_ payload: [UInt8]) throws -> VideoPostureState {
        try decode(payload[...])
    }
}

public enum VideoPostureStateError: Error, Equatable, Sendable {
    case truncatedMessage
    case unexpectedType(UInt8)
    case trailingBytes(Int)
    case unknownPosture(UInt8)
    case zeroInterval
}
