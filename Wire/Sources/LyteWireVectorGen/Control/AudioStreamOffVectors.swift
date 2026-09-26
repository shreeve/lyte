// The key-14 vector-file model: `Wire/Vectors/audio-stream-off-v1.json` —
// the audioStreamOff capability spine. Routing mode 0x04 itself is pinned
// in control-v1.json.

import LyteWire
import LyteWireTestKit

/// One vector file: `Wire/Vectors/audio-stream-off-v1.json`.
public struct AudioStreamOffVectorFile: FrozenVectorFile {
    public var format = Self.expectedFormat
    public var formatVersion = 1
    public var wireVersion = 1
    public var vectors: [CapabilitySpineVector]

    public static let expectedFormat = "lyte-wire-audio-stream-off-vectors"
    public static let fileName = "audio-stream-off-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
    }
}
