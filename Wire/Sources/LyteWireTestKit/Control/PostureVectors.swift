// The posture vector-file model: `Wire/Vectors/postures-v1.json` — the
// two quiet-posture announcements (AudioTrackState 0x25, VideoPosture-
// State 0x26) and their capability spine keys (15, 16).

import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/postures-v1.json`.
public struct PostureVectorFile: FrozenVectorFile {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var vectors: [PostureVector]

    public static let expectedFormat = "lyte-wire-posture-vectors"
    public static let fileName = "postures-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
    }

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        vectors: [PostureVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.vectors = vectors
    }
}

/// One posture vector. `roundtrip` encodes the typed fields to exactly
/// `messageHex` and decodes back; `decodeReject` throws `error`, the
/// codec's error case name. `state` (audioTrackState) and `posture`
/// (videoPostureState) are the enum case names; for `capabilitySet`,
/// `messageHex` is a declaration's CBOR map and the two flags are what
/// the key-15/16 accessors must read.
public struct PostureVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var codec: Codec
    public var messageHex: String
    public var state: String?
    public var posture: String?
    public var keepaliveSeconds: Int?
    public var audioQuietPosture: Bool?
    public var videoQuietPosture: Bool?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeReject
    }

    public enum Codec: String, Codable, Sendable {
        case audioTrackState
        case videoPostureState
        case capabilitySet
    }

    public init(
        name: String,
        description: String,
        kind: Kind,
        codec: Codec,
        messageHex: String,
        state: String? = nil,
        posture: String? = nil,
        keepaliveSeconds: Int? = nil,
        audioQuietPosture: Bool? = nil,
        videoQuietPosture: Bool? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.codec = codec
        self.messageHex = messageHex
        self.state = state
        self.posture = posture
        self.keepaliveSeconds = keepaliveSeconds
        self.audioQuietPosture = audioQuietPosture
        self.videoQuietPosture = videoQuietPosture
        self.error = error
    }
}

/// Stable names for `AudioTrackStateError` cases, as they appear in
/// vectors.
public func audioTrackStateErrorName(_ error: AudioTrackStateError) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .unexpectedType: return "unexpectedType"
    case .trailingBytes: return "trailingBytes"
    case .unknownState: return "unknownState"
    }
}

/// Stable names for `VideoPostureStateError` cases, as they appear in
/// vectors.
public func videoPostureStateErrorName(_ error: VideoPostureStateError) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .unexpectedType: return "unexpectedType"
    case .trailingBytes: return "trailingBytes"
    case .unknownPosture: return "unknownPosture"
    case .zeroInterval: return "zeroInterval"
    }
}
