// VideoPostureState (0x26), host→client
// (docs/decisions/20260802-013946-postures-design.md). When the host's
// retained keepalive backs off during quiet, every step rides a fresh
// announcement carrying the interval now in force, so the client's
// freshness contracts arm against the announced heartbeat. Damage and
// client input are their own wake signals.
//
// Capability key 16 (videoQuietPosture) rides `unknownEntries`; a host
// never backs off against a peer that did not declare it.
//
// Layout (ARQ ordered stream):
//
//   offset size field
//   0      1    type              0x26
//   1      1    posture           0x01 active / 0x02 quiet
//   2      1    keepaliveSeconds  the interval now in force (1–255;
//                                 active always carries 1)
//
// Unknown postures, a zero interval, trailing bytes, and truncation all
// reject. Never traps.

// MARK: - The capability spine helpers

extension Capabilities {
    /// True when this set carries `videoQuietPosture: true` (key 16) — see
    /// `declaresFlag(_:)`.
    public var videoQuietPosture: Bool {
        declaresFlag(CapabilityKey.videoQuietPosture)
    }

    /// A copy of this set declaring `videoQuietPosture`.
    public func declaringVideoQuietPosture() -> Capabilities {
        declaringFlag(CapabilityKey.videoQuietPosture)
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
