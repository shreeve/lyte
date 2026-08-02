// AudioTrackState (0x25), host→client — the postures design's audio
// tripwire announcement (docs/20260802-013946-postures-design.md:
// "silence with a signed IOU"). When the track goes auto-quiet the
// host GATES transmission while capture continues; this message is
// the contract that makes the resulting wire silence honest:
//
//   quiet  — sent when the gate closes, then repeated as the ~5 s
//            still-quiet check-in (the cadence bounds staleness, not
//            wake latency — detection is continuous host-side). The
//            client relaxes its audio-fed blackout detector back to
//            the beacon-bounded threshold and lets the jitter buffer
//            rest instead of concealing.
//   active — sent the instant the tripwire fires, immediately before
//            the pre-roll burst; the resumed 5 ms packets themselves
//            are the liveness evidence (the client re-tightens on the
//            first authenticated audio datagram).
//
// CAPABILITY CARRIAGE — key 15 (audioQuietPosture), the W7 spine used
// exactly as keys 9–14 use it: one canonical `0F F5` map entry through
// `unknownEntries`, byte-equal intersection, capabilities-v1.json
// never regenerates. A host never gates against a set without the
// key — a legacy client keeps today's always-on contract, silence
// included on the wire.
//
// Layout (ARQ ordered stream — announcements are session control:
// reliable, ordered, exactly-once; the 0x18/0x19 carriage argument
// verbatim):
//
//   offset size field
//   0      1    type   0x25
//   1      1    state  0x01 active / 0x02 quiet
//
// Unknown states, trailing bytes, and truncation all reject — these
// ride a reliable ordered stream between capability-negotiated peers,
// so a foreign byte is a protocol break to surface (the InputEvent
// rule). Never traps on hostile bytes.

// MARK: - The capability spine helpers

extension Capabilities {
    /// The key-15 entry as it rides the wire: CBOR bool under
    /// unsigned key 15 — one canonical byte image (`0F F5` inside the
    /// map) so the intersection's byte-equal rule is an exact AND.
    private static var audioQuietPostureEntry: CborMapEntry {
        CborMapEntry(
            key: .unsigned(CapabilityKey.audioQuietPosture),
            value: .bool(true)
        )
    }

    /// True when this set (a declaration or an agreed intersection)
    /// carries `audioQuietPosture: true` — the tripwire's gate.
    public var audioQuietPosture: Bool {
        unknownEntries.contains(Self.audioQuietPostureEntry)
    }

    /// A copy of this set declaring audio-quiet-posture support.
    /// Idempotent; the CBOR encoder owns canonical key order, so the
    /// entry may append here regardless of surrounding keys.
    public func declaringAudioQuietPosture() -> Capabilities {
        guard !audioQuietPosture else { return self }
        var declared = self
        declared.unknownEntries.append(Self.audioQuietPostureEntry)
        return declared
    }
}

// MARK: - The CTRL codec

/// The host's audio track-state announcement (type 0x25).
public struct AudioTrackState: Hashable, Sendable {
    public enum State: UInt8, Hashable, CaseIterable, Sendable {
        /// The track is transmitting (the tripwire fired, or it never
        /// gated).
        case active = 0x01
        /// Transmission is gated on announced silence; capture
        /// continues and the pre-roll ring is armed. Repeated as the
        /// still-quiet check-in.
        case quiet = 0x02
    }

    public var state: State

    public init(state: State) {
        self.state = state
    }

    public func encode() -> [UInt8] {
        [CtrlMessageType.audioTrackState, state.rawValue]
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> AudioTrackState {
        guard payload.count >= 2 else {
            throw AudioTrackStateError.truncatedMessage
        }
        let base = payload.startIndex
        guard payload[base] == CtrlMessageType.audioTrackState else {
            throw AudioTrackStateError.unexpectedType(payload[base])
        }
        guard payload.count == 2 else {
            throw AudioTrackStateError.trailingBytes(payload.count - 2)
        }
        guard let state = State(rawValue: payload[base + 1]) else {
            throw AudioTrackStateError.unknownState(payload[base + 1])
        }
        return AudioTrackState(state: state)
    }

    public static func decode(_ payload: [UInt8]) throws -> AudioTrackState {
        try decode(payload[...])
    }
}

public enum AudioTrackStateError: Error, Equatable, Sendable {
    case truncatedMessage
    case unexpectedType(UInt8)
    case trailingBytes(Int)
    case unknownState(UInt8)
}
