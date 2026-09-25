// AudioTrackState (0x25, host→client): the audio quiet-posture
// announcement (docs/decisions/20260802-013946-postures-design.md). When
// the track goes quiet the host gates transmission while capture
// continues; this message makes the wire silence honest:
//
//   quiet  — sent when the gate closes, then repeated as a ~5 s check-in
//            (bounding staleness, not wake latency). The client relaxes
//            its audio-fed blackout detector to the beacon-bounded
//            threshold and lets the jitter buffer rest.
//   active — sent immediately before the pre-roll burst; the resumed
//            packets are the liveness evidence.
//
// Gated by capability key 15 (audioQuietPosture) through `unknownEntries`;
// a host never gates audio for a peer without the key. Rides the ARQ
// ordered stream. Layout:
//
//   offset size field
//   0      1    type   0x25
//   1      1    state  0x01 active / 0x02 quiet
//
// Unknown states, trailing bytes and truncation all throw; never traps on
// hostile bytes.

// MARK: - The CTRL codec

/// The host's audio track-state announcement (type 0x25).
public struct AudioTrackState: Hashable, Sendable, SliceDecodable {
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
}

public enum AudioTrackStateError: Error, Equatable, Sendable {
    case truncatedMessage
    case unexpectedType(UInt8)
    case trailingBytes(Int)
    case unknownState(UInt8)
}
