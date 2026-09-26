// The cursor-codec vector-file model and loader:
// `Wire/Vectors/cursor-v1.json` — CursorShape 0x24 and the key-13
// capability.

import LyteWire
import LyteWireTestKit

/// One vector file: `Wire/Vectors/cursor-v1.json`.
public struct CursorVectorFile: FrozenVectorFile {
    public var format = Self.expectedFormat
    public var formatVersion = 1
    public var wireVersion = 1
    public var vectors: [CursorVector]

    public static let expectedFormat = "lyte-wire-cursor-vectors"
    public static let fileName = "cursor-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
    }
}

/// One cursor vector. `codec` names the codec under test; kinds match the
/// control file (`error` is a `CursorMessageError` case name). `cursorShape`
/// roundtrips carry `width`/`height`/`hotspotX`/`hotspotY` plus `pixelsHex`
/// (BGRA). For `capabilitySet`, `messageHex` is a declaration's CBOR map:
/// decode must answer exactly `cursorShape` through the key-13 accessor and
/// re-encode byte-exactly.
public struct CursorVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var codec: CursorCodec
    public var messageHex: String
    /// cursorShape roundtrip fields.
    public var width: Int?
    public var height: Int?
    public var hotspotX: Int?
    public var hotspotY: Int?
    public var pixelsHex: String?
    /// capabilitySet field.
    public var cursorShape: Bool?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeReject
    }

    public enum CursorCodec: String, Codable, Sendable {
        case cursorShape
        case capabilitySet
    }
}
