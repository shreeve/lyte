// The session-lifecycle wire messages: the ACTIVE⇄IDLE mode transition
// and the typed session teardown. Both ride CTRL's ARQ ordered stream
// (group 0): a reordered mode flip would leave the ends disagreeing about
// whether datagram video is flowing, and a teardown must never overtake the
// messages that explain it.
//
// The final converged frame (IdleFrame 0x15) rides a CTRL one-shot group,
// unordered against group 0, so the sender only sends mode=idle after that
// one-shot is acknowledged (`ArqEvent.oneShotAcknowledged`). The receiver
// therefore always holds the converged frame before it learns the session
// went idle. Dormant in v1: the host has no convergence ratchet, so it
// never sends the frame or mode=idle.
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
//   1      1    reason  0x01 taken-over-by, 0x02 shutting-down; others
//                       reject (0x00 included)
//
// Both are exactly their fixed size: truncation and trailing bytes
// reject, a foreign type byte rejects with what it found.

/// The two wire modes: ACTIVE = unreliable datagram video is flowing;
/// IDLE = sparse reliable frames only. FROZEN/RECOVERY are local overlay
/// states, never wire values.
public enum SessionWireMode: UInt8, Hashable, CaseIterable, Sendable {
    case active = 0x01
    case idle = 0x02
}

/// Why a session ended, as the wire carries it. `takenOver`: another
/// client took the session; `shuttingDown`: any orderly local end.
/// Liveness timeouts send nothing — the reader is the peer that died.
public enum SessionTeardownReason: UInt8, Hashable, CaseIterable, Sendable {
    case takenOver = 0x01
    case shuttingDown = 0x02
}

/// The ACTIVE⇄IDLE mode-transition CTRL message (type 0x09).
public struct ModeTransition: Hashable, Sendable, SliceDecodable {
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
}

/// The typed session-teardown CTRL message (type 0x0A).
public struct SessionTeardown: Hashable, Sendable, SliceDecodable {
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
