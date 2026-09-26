// The posture vector-file model: `Wire/Vectors/postures-v1.json` — the
// two quiet-posture announcements (AudioTrackState 0x25, VideoPosture-
// State 0x26) and their capability spine keys (15, 16).

import LyteWire
import LyteWireTestKit

/// One vector file: `Wire/Vectors/postures-v1.json`.
public struct PostureVectorFile: FrozenVectorFile {
    public var format = Self.expectedFormat
    public var formatVersion = 1
    public var wireVersion = 1
    public var vectors: [PostureVector]

    public static let expectedFormat = "lyte-wire-posture-vectors"
    public static let fileName = "postures-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
    }
}

/// One posture vector. `roundtrip`/`decodeReject` as elsewhere (`error` is
/// the codec's error case name). `state`/`posture` are enum case names; for
/// `capabilitySet`, `messageHex` is a declaration's CBOR map and the two
/// flags are what the key-15/16 accessors must read.
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
}
