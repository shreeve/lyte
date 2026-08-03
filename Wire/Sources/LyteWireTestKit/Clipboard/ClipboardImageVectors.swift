// The clipboard-image vector-file model and loader:
// `Wire/Vectors/clipboard-images-v1.json` — the P-1 cargo marker
// (ClipboardImageCargo 0x22) and the key-12 capability spine, born in
// the registry rather than promoted (the clipboard-v1 precedent).
// Same doctrine as the other loaders: TestKit may import Foundation,
// LyteWire may not. u64 fields ride as hex, the house JSON-precision
// rule.

import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/clipboard-images-v1.json`.
public struct ClipboardImageVectorFile: Codable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var vectors: [ClipboardImageVector]

    public static let expectedFormat = "lyte-wire-clipboard-image-vectors"

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

    public static func load(
        from path: String
    ) throws -> ClipboardImageVectorFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(
            ClipboardImageVectorFile.self, from: data
        )
    }
}

/// One clipboard-image vector. `codec` names the codec under test;
/// kinds match the bulk file (`roundtrip` builds the typed value from
/// the fields, encodes to exactly `messageHex`, and decodes back
/// field-exact; `decodeReject` throws `error` decoding `messageHex`;
/// `encodeReject` throws `error` CONSTRUCTING the value — bounds only
/// the u8 mime-length wire width makes inexpressible as bytes).
/// `error` names are `ClipboardImageCargoError` case names. The mime
/// rides as `mimeUtf8Hex` — hex of the UTF-8 bytes, so the file is
/// encoding-unambiguous and auditable by eye. For `capabilitySet`,
/// `messageHex` is a declaration's CBOR map: decode must answer
/// exactly `clipboardImages` through the key-12 accessor and
/// re-encode byte-exactly (the key-10/key-11 precedent).
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

/// Stable names for `ClipboardImageCargoError` cases, as they appear
/// in vectors.
public func clipboardImageCargoErrorName(
    _ error: ClipboardImageCargoError
) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .unexpectedType: return "unexpectedType"
    case .trailingBytes: return "trailingBytes"
    case .zeroTransferId: return "zeroTransferId"
    case .emptyMime: return "emptyMime"
    case .mimeOverBudget: return "mimeOverBudget"
    case .invalidUtf8: return "invalidUtf8"
    }
}
