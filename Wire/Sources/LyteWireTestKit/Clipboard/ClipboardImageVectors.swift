// The clipboard-image vector-file model and loader:
// `Wire/Vectors/clipboard-images-v1.json` — ClipboardImageCargo 0x22 and
// the key-12 capability. u64 fields ride as hex.

import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/clipboard-images-v1.json`.
public struct ClipboardImageVectorFile: FrozenVectorFile {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var vectors: [ClipboardImageVector]

    public static let expectedFormat = "lyte-wire-clipboard-image-vectors"
    public static let fileName = "clipboard-images-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
    }

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        vectors: [ClipboardImageVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.vectors = vectors
    }

}

/// One clipboard-image vector. `codec` names the codec under test; kinds
/// match the bulk file (`encodeReject` throws `error` constructing the
/// value). `error` names are `ClipboardImageCargoError` case names. The
/// mime rides as `mimeUtf8Hex`. For `capabilitySet`, `messageHex` is a
/// declaration's CBOR map: decode must answer exactly `clipboardImages`
/// through the key-12 accessor and re-encode byte-exactly.
public struct ClipboardImageVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var codec: ClipboardImageCodec
    /// Absent for encodeReject (nothing ever encodes).
    public var messageHex: String?
    public var transferIdHex: String?
    public var mimeUtf8Hex: String?
    /// capabilitySet field.
    public var clipboardImages: Bool?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeReject
        case encodeReject
    }

    public enum ClipboardImageCodec: String, Codable, Sendable {
        case imageCargo
        case capabilitySet
    }

    public init(
        name: String,
        description: String,
        kind: Kind,
        codec: ClipboardImageCodec,
        messageHex: String? = nil,
        transferIdHex: String? = nil,
        mimeUtf8Hex: String? = nil,
        clipboardImages: Bool? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.codec = codec
        self.messageHex = messageHex
        self.transferIdHex = transferIdHex
        self.mimeUtf8Hex = mimeUtf8Hex
        self.clipboardImages = clipboardImages
        self.error = error
    }
}
