// The session-lifecycle wire messages (W4b): the ACTIVE⇄IDLE mode
// transition and the typed session teardown. Both ride CTRL's ARQ
// ordered stream (group 0) — the first ARQ-carried CTRL types, which is
// why they could not exist before W3. Reliable ordered carriage is
// load-bearing: a reordered mode flip would leave the two ends
// disagreeing about whether datagram video is flowing, and a teardown
// must never overtake the messages that explain it.
//
// Mode-transition ordering vs the converged frame (overview §2, the
// ratchet-boundary ruling): the final converged frame rides a video-idle
// ONE-SHOT group, and groups are mutually unordered — so the sender only
// flips (and only sends mode=idle) after the one-shot is ACKNOWLEDGED
// (ArqEvent.oneShotAcknowledged, the "final frame landed" signal). The
// receiver therefore always holds the converged frame before it learns
// the session went idle.
//
// Mode transition (type 0x09), fixed 2 bytes:
//
//   offset size field
//   0      1    type    0x09
//   1      1    mode    0x01 ACTIVE, 0x02 IDLE; others reject
//
// Session teardown (type 0x0A), fixed 2 bytes:
//
//   offset size field
//   0      1    type    0x0A
//   1      1    reason  0x01 taken-over-by (transport §4's multi-client
//                       ruling), 0x02 shutting-down; others reject —
//                       0x00 stays the loud zero-fill bug
//
// Both are exactly their fixed size: truncation and trailing bytes
// reject, a foreign type byte rejects with what it found (the beacon
// codecs' doctrine). FROZEN/RECOVERY never appear on the wire — they
// are the path-loss overlay each end derives locally (overview §2);
// only the two wire modes are signaled.

/// The two wire modes (overview §2): ACTIVE = unreliable datagram video
/// is flowing; IDLE = sparse reliable frames only. Signaled on CTRL by
/// the sender's SessionStateMachine; FROZEN/RECOVERY are local overlay
/// states, never wire values.
public enum SessionWireMode: UInt8, Hashable, CaseIterable, Sendable {
    case active = 0x01
    case idle = 0x02
}

/// Why a session ended, as the wire carries it. `takenOver` is the
/// transport pillar's multi-client ruling (`taken-over-by`);
/// `shuttingDown` is any orderly local end. Liveness timeouts send
/// nothing — the peer that would read the message is the one that died.
public enum SessionTeardownReason: UInt8, Hashable, CaseIterable, Sendable {
    case takenOver = 0x01
    case shuttingDown = 0x02
}

/// The ACTIVE⇄IDLE mode-transition CTRL message (type 0x09).
public struct ModeTransition: Hashable, Sendable {
    public var mode: SessionWireMode

    public init(mode: SessionWireMode) {
        self.mode = mode
    }

    public static let encodedByteCount = 2

    /// Encodes the 2-byte message, type byte included. Cannot fail.
    public func encode() -> [UInt8] {
        [CtrlMessageType.modeTransition, mode.rawValue]
    }

    /// Decodes a whole ARQ-delivered CTRL message (type byte first).
    /// Throws on the wrong type, truncation, trailing bytes, and an
    /// unknown mode value; never traps on hostile bytes.
    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> ModeTransition {
        guard payload.count >= encodedByteCount else {
            throw LifecycleMessageError.truncatedMessage
        }
        guard payload.count == encodedByteCount else {
            throw LifecycleMessageError.trailingBytes
        }
        let base = payload.startIndex
        guard payload[base] == CtrlMessageType.modeTransition else {
            throw LifecycleMessageError.unexpectedType(payload[base])
        }
        guard let mode = SessionWireMode(rawValue: payload[base + 1]) else {
            throw LifecycleMessageError.unknownMode(payload[base + 1])
        }
        return ModeTransition(mode: mode)
    }

    public static func decode(_ payload: [UInt8]) throws -> ModeTransition {
        try decode(payload[...])
    }
}

/// The typed session-teardown CTRL message (type 0x0A).
public struct SessionTeardown: Hashable, Sendable {
    public var reason: SessionTeardownReason

    public init(reason: SessionTeardownReason) {
        self.reason = reason
    }

    public static let encodedByteCount = 2

    /// Encodes the 2-byte message, type byte included. Cannot fail.
    public func encode() -> [UInt8] {
        [CtrlMessageType.sessionTeardown, reason.rawValue]
    }

    /// Decodes a whole ARQ-delivered CTRL message (type byte first).
    /// Throws on the wrong type, truncation, trailing bytes, and an
    /// unknown reason value; never traps on hostile bytes.
    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> SessionTeardown {
        guard payload.count >= encodedByteCount else {
            throw LifecycleMessageError.truncatedMessage
        }
        guard payload.count == encodedByteCount else {
            throw LifecycleMessageError.trailingBytes
        }
        let base = payload.startIndex
        guard payload[base] == CtrlMessageType.sessionTeardown else {
            throw LifecycleMessageError.unexpectedType(payload[base])
        }
        guard let reason = SessionTeardownReason(
            rawValue: payload[base + 1]
        ) else {
            throw LifecycleMessageError.unknownReason(payload[base + 1])
        }
        return SessionTeardown(reason: reason)
    }

    public static func decode(_ payload: [UInt8]) throws -> SessionTeardown {
        try decode(payload[...])
    }
}

/// Everything the lifecycle codecs can refuse. Hostile bytes throw,
/// never trap.
public enum LifecycleMessageError: Error, Hashable, Sendable {
    case truncatedMessage
    case trailingBytes
    case unexpectedType(UInt8)
    case unknownMode(UInt8)
    case unknownReason(UInt8)
}
