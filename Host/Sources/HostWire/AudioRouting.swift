// Host audio routing (HS-18): the wire shapes of the "does the host's
// own speaker keep playing while the client streams?" choice. HS-14's
// monitor capture deliberately taps the default sink's monitor, so the
// host stays AUDIBLE — the right default for a couch-copilot session
// and exactly wrong for remote work (the human, hearing the same audio
// on both machines: "we need a way to enable the audio on the host or
// not when the client is viewing"). hostMuted is the other posture:
// the audio leaf creates a virtual "Lyte Audio" null sink, makes it
// the system default, and captures ITS monitor — sound flows only to
// the wire and the physical speakers go silent. The sink lifecycle
// (creation, default switch, exact restore on teardown AND crash) is
// the C leaf's; this file is the sans-IO vocabulary and carriage.
//
// CAPABILITY CARRIAGE — the W7 forward-compat spine, used as designed.
// Wire v1's registry stops at key 8 and its rule 3 says "new semantics
// ship as NEW KEYS gated by intersection": key 9 (hostAudioRouting,
// bool) is pinned HOST-SIDE here and rides the declaration through
// `Capabilities.unknownEntries` — unknown keys are ignored+preserved
// by every v1 end and survive intersection only on byte-equal
// agreement, so the capability lights up exactly when BOTH ends
// declare it and vanishes against a legacy peer. ZERO frozen bytes
// move: capabilities-v1.json never regenerates (the unknown-key rule
// is itself frozen data, tested in both argument orders at W-G8), and
// the encoded declaration differs from wireDefault's by exactly the
// appended `09 F5` map entry (pinned by the gate tests). The client's
// auto-hiding control strip gates its mute button on the agreed set —
// absence is "not supported", never an error.
//
// PROMOTE-TO-LyteWire FLAG (with the client CL slice, the 0x15/0x16/
// 0x17 precedent): CTRL types 0x18/0x19 and capability key 9 are
// pinned HOST-SIDE FIRST because Wire/ is read-only territory this
// slice. Promotion is registry appends (CapabilityKey.hostAudioRouting
// = 9 as a typed bool field + CtrlMessageType 0x18/0x19); the bytes
// never change. 0x18/0x19 are the first bytes past HS-13's 0x17.
//
// AudioRoutingRequest (0x18), client→host, ARQ ordered stream (a
// routing flip is session control: reliable, ordered, exactly-once —
// the input-message carriage argument verbatim). Layout:
//
//   offset size field
//   0      1    type   0x18
//   1      1    mode   0x01 hostAudible / 0x02 hostMuted
//
// AudioRoutingStatus (0x19), host→client, same carriage: the posture
// the host ACTUALLY applied (the control strip renders truth, not
// hope). Sent once at capability agreement (the session's starting
// posture) and after every applied flip. Same layout, type 0x19.
//
// Unknown modes, trailing bytes, and truncation all reject — these
// ride a reliable ordered stream between capability-negotiated peers,
// so a foreign mode is a protocol break to surface (the InputEvent
// rule). Never traps on hostile bytes.

import LyteWire

extension HostCtrlMessageType {
    /// Client→host audio-routing flip request (HS-18 → client CL).
    public static let audioRoutingRequest: UInt8 = 0x18
    /// Host→client applied-posture status (HS-18 → client CL).
    public static let audioRoutingStatus: UInt8 = 0x19
}

/// Capability registry keys pinned host-side awaiting promotion into
/// `CapabilityKey` (see the file comment).
public enum HostCapabilityKey {
    /// bool — the host can route desktop audio to a virtual sink and
    /// mute its own speakers for the session (and honors 0x18 flips).
    /// Gated by intersection per W7 rule 3: enabled only when both
    /// ends declare it.
    public static let hostAudioRouting: UInt64 = 9
}

/// Where the host's own speakers stand while the session streams.
public enum HostAudioRoutingMode: UInt8, Hashable, CaseIterable, Sendable {
    /// Today's HS-14 posture: capture the default sink's monitor; the
    /// host's speakers keep playing.
    case hostAudible = 0x01
    /// The virtual-sink posture: "Lyte Audio" becomes the default
    /// sink, its monitor feeds the wire, the physical output is
    /// silent; the original default is restored at teardown (crash
    /// paths included).
    case hostMuted = 0x02
}

// MARK: - The capability spine helpers

extension Capabilities {
    /// The key-9 entry as it rides the wire: CBOR bool under unsigned
    /// key 9. One canonical byte image (`09 F5` inside the map) is
    /// what makes the intersection's byte-equal rule an exact AND.
    private static var hostAudioRoutingEntry: CborMapEntry {
        CborMapEntry(
            key: .unsigned(HostCapabilityKey.hostAudioRouting),
            value: .bool(true)
        )
    }

    /// True when this set (a declaration or an agreed intersection)
    /// carries `hostAudioRouting: true`. On a v1 build the key lives
    /// in `unknownEntries` — which is exactly what makes it survive
    /// intersection only on mutual declaration. A `false` or
    /// wrongly-typed value reads as absent: absence and refusal are
    /// the same posture ("not supported"), per the spine's rule 3.
    public var hostAudioRouting: Bool {
        unknownEntries.contains(Self.hostAudioRoutingEntry)
    }

    /// A copy of this set declaring hostAudioRouting support.
    /// Idempotent; the CBOR encoder owns canonical key order, so the
    /// entry may append here regardless of surrounding keys.
    public func declaringHostAudioRouting() -> Capabilities {
        guard !hostAudioRouting else { return self }
        var declared = self
        declared.unknownEntries.append(Self.hostAudioRoutingEntry)
        return declared
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
        [HostCtrlMessageType.audioRoutingRequest, mode.rawValue]
    }

    /// Decodes a whole ARQ-delivered message (type byte first). Throws
    /// on the wrong type, truncation, an unknown mode, and trailing
    /// bytes; never traps on hostile bytes.
    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> AudioRoutingRequest {
        AudioRoutingRequest(mode: try decodeRoutingBody(
            payload, type: HostCtrlMessageType.audioRoutingRequest
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
        [HostCtrlMessageType.audioRoutingStatus, mode.rawValue]
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> AudioRoutingStatus {
        AudioRoutingStatus(mode: try decodeRoutingBody(
            payload, type: HostCtrlMessageType.audioRoutingStatus
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
