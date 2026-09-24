// Host audio routing: whether the host's own speakers keep playing while
// the client streams. The sink lifecycle belongs to the host's audio
// leaf; this file is the sans-IO vocabulary and carriage.
//
// Gated by capability key 9 (hostAudioRouting, bool), carried through
// `Capabilities.unknownEntries`: it is agreed only when BOTH ends declare
// it, and absence means "not supported", never an error.
//
// AudioRoutingRequest (0x18, client→host) and AudioRoutingStatus (0x19,
// host→client) ride the ARQ ordered stream. Status reports the posture
// the host ACTUALLY applied: once at capability agreement and after every
// flip (a failed flip reports the old posture). Layout:
//
//   offset size field
//   0      1    type   0x18 / 0x19
//   1      1    mode   HostAudioRoutingMode raw value
//
// Unknown modes, trailing bytes and truncation all throw; never traps on
// hostile bytes.

/// Where the host's own speakers stand while the session streams.
public enum HostAudioRoutingMode: UInt8, Hashable, CaseIterable, Sendable {
    /// Capture the default sink's monitor; the host's speakers keep
    /// playing.
    case hostAudible = 0x01
    /// The virtual-sink posture: "Lyte Audio" becomes the default
    /// sink, its monitor feeds the wire, the physical output is
    /// silent; the original default is restored at teardown (crash
    /// paths included).
    case hostMuted = 0x02
    /// Mute at source: the host captures and encodes nothing and its
    /// own speakers keep playing. Sent only when both ends declared key
    /// 14 (audioStreamOff). 0x03 is never used: the frozen vector
    /// `routing-mode-unknown` pins it as unknownMode.
    case streamOff = 0x04
}

// MARK: - The capability spine helpers

extension Capabilities {
    /// True when this set carries `hostAudioRouting: true` (key 9) — see
    /// `declaresFlag(_:)`.
    public var hostAudioRouting: Bool {
        declaresFlag(CapabilityKey.hostAudioRouting)
    }

    /// A copy of this set declaring `hostAudioRouting`.
    public func declaringHostAudioRouting() -> Capabilities {
        declaringFlag(CapabilityKey.hostAudioRouting)
    }

    /// True when this set carries `audioStreamOff: true` (key 14) — see
    /// `declaresFlag(_:)`.
    public var audioStreamOff: Bool {
        declaresFlag(CapabilityKey.audioStreamOff)
    }

    /// A copy of this set declaring `audioStreamOff`.
    public func declaringAudioStreamOff() -> Capabilities {
        declaringFlag(CapabilityKey.audioStreamOff)
    }
}

// MARK: - The CTRL codecs

/// The client's routing flip ask (type 0x18).
public struct AudioRoutingRequest: Hashable, Sendable {
    public var mode: HostAudioRoutingMode

    public init(mode: HostAudioRoutingMode) {
        self.mode = mode
    }

    public func encode() -> [UInt8] {
        [CtrlMessageType.audioRoutingRequest, mode.rawValue]
    }

    /// Decodes a whole ARQ-delivered message (type byte first). Throws
    /// on the wrong type, truncation, an unknown mode, and trailing
    /// bytes; never traps on hostile bytes.
    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> AudioRoutingRequest {
        AudioRoutingRequest(mode: try decodeRoutingBody(
            payload, type: CtrlMessageType.audioRoutingRequest
        ))
    }

    public static func decode(_ payload: [UInt8]) throws -> AudioRoutingRequest {
        try decode(payload[...])
    }
}

/// The host's applied-posture report (type 0x19).
public struct AudioRoutingStatus: Hashable, Sendable {
    public var mode: HostAudioRoutingMode

    public init(mode: HostAudioRoutingMode) {
        self.mode = mode
    }

    public func encode() -> [UInt8] {
        [CtrlMessageType.audioRoutingStatus, mode.rawValue]
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> AudioRoutingStatus {
        AudioRoutingStatus(mode: try decodeRoutingBody(
            payload, type: CtrlMessageType.audioRoutingStatus
        ))
    }

    public static func decode(_ payload: [UInt8]) throws -> AudioRoutingStatus {
        try decode(payload[...])
    }
}

public enum AudioRoutingMessageError: Error, Equatable, Sendable {
    case truncatedMessage
    case unexpectedType(UInt8)
    case unknownMode(UInt8)
    case trailingBytes(Int)
}

/// Both messages share the `type ‖ mode u8` shape.
private func decodeRoutingBody(
    _ payload: ArraySlice<UInt8>, type: UInt8
) throws -> HostAudioRoutingMode {
    guard payload.count >= 2 else {
        throw AudioRoutingMessageError.truncatedMessage
    }
    let base = payload.startIndex
    guard payload[base] == type else {
        throw AudioRoutingMessageError.unexpectedType(payload[base])
    }
    guard payload.count == 2 else {
        throw AudioRoutingMessageError.trailingBytes(payload.count - 2)
    }
    guard let mode = HostAudioRoutingMode(rawValue: payload[base + 1]) else {
        throw AudioRoutingMessageError.unknownMode(payload[base + 1])
    }
    return mode
}
