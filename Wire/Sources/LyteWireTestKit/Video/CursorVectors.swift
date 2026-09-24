// The cursor-codec vector-file model and loader:
// `Wire/Vectors/cursor-v1.json` — CursorShape 0x24 and the key-13
// capability.

import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/cursor-v1.json`.
public struct CursorVectorFile: FrozenVectorFile {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var vectors: [CursorVector]

    public static let expectedFormat = "lyte-wire-cursor-vectors"
    public static let fileName = "cursor-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
    }

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        vectors: [CursorVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.vectors = vectors
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

    public init(
        name: String,
        description: String,
        kind: Kind,
        codec: CursorCodec,
        messageHex: String,
        width: Int? = nil,
        height: Int? = nil,
        hotspotX: Int? = nil,
        hotspotY: Int? = nil,
        pixelsHex: String? = nil,
        cursorShape: Bool? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.codec = codec
        self.messageHex = messageHex
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.pixelsHex = pixelsHex
        self.cursorShape = cursorShape
        self.error = error
    }
}

/// Stable names for `CursorMessageError` cases, as they appear in
/// vectors.
public func cursorMessageErrorName(
    _ error: CursorMessageError
) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .unexpectedType: return "unexpectedType"
    case .invalidDimensions: return "invalidDimensions"
    case .imageOverBudget: return "imageOverBudget"
    case .pixelCountMismatch: return "pixelCountMismatch"
    case .hotspotOutsideImage: return "hotspotOutsideImage"
    }
}
