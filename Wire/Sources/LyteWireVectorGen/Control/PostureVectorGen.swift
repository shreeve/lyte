// Authors Vectors/postures-v1.json: AudioTrackState (0x25) and
// VideoPostureState (0x26) — every state and posture, the backoff
// ladder's intervals, every reject — plus the key-15/16 capability
// spine declared and absent. Roundtrip bytes come from the codecs;
// reject bytes are hand-built.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makePostureVectorFile() throws -> PostureVectorFile {
    var vectors: [PostureVector] = []

    // MARK: AudioTrackState (0x25)

    for (state, bytes) in [
        (AudioTrackState.State.active, "01"), (.quiet, "02"),
    ] {
        vectors.append(PostureVector(
            name: "audio-track-\(state)",
            description: "type ‖ state: [0x25, 0x\(bytes)].",
            kind: .roundtrip, codec: .audioTrackState,
            messageHex: Hex.string(AudioTrackState(state: state).encode()),
            state: "\(state)"
        ))
    }
    for (name, description, hex, error) in [
        ("audio-track-empty", "No bytes at all.", "", "truncatedMessage"),
        ("audio-track-truncated", "The bare type byte rejects.", "25",
         "truncatedMessage"),
        ("audio-track-foreign-type",
         "A VideoPostureState type byte at audio length rejects with what it found.",
         "2601", "unexpectedType"),
        ("audio-track-trailing-byte",
         "3 bytes reject — the message is exactly its layout.", "250100",
         "trailingBytes"),
        ("audio-track-state-zero", "State 0x00 rejects — the loud zero-fill bug.",
         "2500", "unknownState"),
        ("audio-track-state-unknown",
         "State 0x03 rejects — the state space is exactly active and quiet.",
         "2503", "unknownState"),
    ] {
        vectors.append(PostureVector(
            name: name, description: description,
            kind: .decodeReject, codec: .audioTrackState,
            messageHex: hex, error: error
        ))
    }

    // MARK: VideoPostureState (0x26)

    let ladder: [(VideoPostureState.Posture, UInt8)] = [
        (.active, 1), (.quiet, 2), (.quiet, 4), (.quiet, 8), (.quiet, 16),
        (.quiet, 30), (.quiet, 255),
    ]
    for (posture, seconds) in ladder {
        let message = VideoPostureState(
            posture: posture, keepaliveSeconds: seconds
        )
        vectors.append(PostureVector(
            name: "video-posture-\(posture)-\(seconds)s",
            description: posture == .active
                ? "Active always carries the 1 s keepalive."
                : "Quiet at a \(seconds) s keepalive (the backoff ladder; 255 is the u8 ceiling).",
            kind: .roundtrip, codec: .videoPostureState,
            messageHex: Hex.string(message.encode()),
            posture: "\(posture)",
            keepaliveSeconds: Int(seconds)
        ))
    }
    for (name, description, hex, error) in [
        ("video-posture-truncated", "Type and posture without the interval.",
         "2602", "truncatedMessage"),
        ("video-posture-foreign-type",
         "An AudioTrackState type byte at posture length rejects with what it found.",
         "250201", "unexpectedType"),
        ("video-posture-trailing-byte",
         "4 bytes reject — the message is exactly its layout.", "26020200",
         "trailingBytes"),
        ("video-posture-zero", "Posture 0x00 rejects — the loud zero-fill bug.",
         "260002", "unknownPosture"),
        ("video-posture-unknown",
         "Posture 0x03 rejects — the posture space is exactly active and quiet.",
         "260302", "unknownPosture"),
        ("video-posture-zero-interval",
         "A zero keepalive rejects — \"no keepalive\" is a future posture, not an interval.",
         "260200", "zeroInterval"),
    ] {
        vectors.append(PostureVector(
            name: name, description: description,
            kind: .decodeReject, codec: .videoPostureState,
            messageHex: hex, error: error
        ))
    }

    // MARK: Capability spine (keys 15, 16)

    for (name, description, set) in [
        ("capability-key15-declared",
         "wireDefault plus exactly `0F F5`: audioQuietPosture reads true.",
         Capabilities.wireDefault.declaringAudioQuietPosture()),
        ("capability-key16-declared",
         "wireDefault plus exactly `10 F5`: videoQuietPosture reads true.",
         Capabilities.wireDefault.declaringVideoQuietPosture()),
        ("capability-key15-and-key16",
         "Both posture keys, in canonical order.",
         Capabilities.wireDefault.declaringVideoQuietPosture()
            .declaringAudioQuietPosture()),
        ("capability-postures-absent",
         "wireDefault unchanged: both keys read false — \"not supported\", never an error.",
         Capabilities.wireDefault),
    ] {
        vectors.append(PostureVector(
            name: name, description: description,
            kind: .roundtrip, codec: .capabilitySet,
            messageHex: Hex.string(try set.encodeCbor()),
            audioQuietPosture: set.audioQuietPosture,
            videoQuietPosture: set.videoQuietPosture
        ))
    }

    return PostureVectorFile(vectors: vectors)
}
