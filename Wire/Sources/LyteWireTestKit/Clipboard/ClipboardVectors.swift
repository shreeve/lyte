// The clipboard-codec vector-file model and loader:
// `Wire/Vectors/clipboard-v1.json` — ClipboardSet 0x1A, ClipboardAnnounce
// 0x1B, and the key-10 capability.

import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/clipboard-v1.json`.
public struct ClipboardVectorFile: FrozenVectorFile {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var vectors: [ClipboardVector]

    public static let expectedFormat = "lyte-wire-clipboard-vectors"
    public static let fileName = "clipboard-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
    }

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        vectors: [ClipboardVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.vectors = vectors
    }

}

/// One clipboard vector. `codec` names the codec under test; kinds match
/// the control file (`error` is a `ClipboardMessageError` case name). Text
/// rides as `textUtf8Hex`. For `capabilitySet`, `messageHex` is a
/// declaration's CBOR map: decode must answer exactly `clipboardText`
/// through the key-10 accessor and re-encode byte-exactly.
public struct ClipboardVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var codec: ClipboardCodec
    public var messageHex: String
    /// clipboardSet/clipboardAnnounce roundtrip field: the text's
    /// UTF-8 bytes as hex.
    public var textUtf8Hex: String?
    /// capabilitySet field.
    public var clipboardText: Bool?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeReject
    }

    public enum ClipboardCodec: String, Codable, Sendable {
        case clipboardSet
        case clipboardAnnounce
        case capabilitySet
    }

    public init(
        name: String,
        description: String,
        kind: Kind,
        codec: ClipboardCodec,
        messageHex: String,
        textUtf8Hex: String? = nil,
        clipboardText: Bool? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.codec = codec
        self.messageHex = messageHex
        self.textUtf8Hex = textUtf8Hex
        self.clipboardText = clipboardText
        self.error = error
    }
}

/// Stable names for `ClipboardMessageError` cases, as they appear in
/// vectors.
public func clipboardMessageErrorName(
    _ error: ClipboardMessageError
) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .unexpectedType: return "unexpectedType"
    case .emptyText: return "emptyText"
    case .textOverBudget: return "textOverBudget"
    case .invalidUtf8: return "invalidUtf8"
    }
}
