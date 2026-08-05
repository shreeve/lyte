import LyteWire

/// A reliable media-posture word after portable decoding and capability
/// judgment. Platform shells execute the resulting audio and UI effects.
public enum ClientMediaPostureSessionEvent: Hashable, Sendable {
    case audioState(AudioTrackState)
    case videoState(VideoPostureState, changed: Bool)
    case malformedAudioState
    case malformedVideoState
    case unnegotiatedAudioState
    case unnegotiatedVideoState
}

/// IO-free ownership of the host's announced audio and video posture.
public struct ClientMediaPostureSession: Sendable {
    public private(set) var hostAnnouncedAudioQuiet = false
    public private(set) var announcedVideoPosture: VideoPostureState?

    public init() {}

    /// Authenticated audio is stronger evidence than an earlier quiet
    /// announcement and returns the track to its active posture.
    public mutating func noteAudioEvidence() {
        hostAnnouncedAudioQuiet = false
    }

    public mutating func receiveReliable(
        _ bytes: [UInt8],
        agreed: Capabilities?
    ) -> ClientMediaPostureSessionEvent? {
        switch bytes.first {
        case CtrlMessageType.audioTrackState:
            guard let state = try? AudioTrackState.decode(bytes) else {
                return .malformedAudioState
            }
            guard agreed?.audioQuietPosture == true else {
                return .unnegotiatedAudioState
            }
            hostAnnouncedAudioQuiet = state.state == .quiet
            return .audioState(state)

        case CtrlMessageType.videoPostureState:
            guard let posture = try? VideoPostureState.decode(bytes) else {
                return .malformedVideoState
            }
            guard agreed?.videoQuietPosture == true else {
                return .unnegotiatedVideoState
            }
            let changed = posture != announcedVideoPosture
            announcedVideoPosture = posture
            return .videoState(posture, changed: changed)

        default:
            return nil
        }
    }
}
