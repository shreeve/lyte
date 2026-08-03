// The repair-refusal vector-file model and loader:
// `Wire/Vectors/repair-refusal-v1.json` — the HS-32 repair-refusal CTRL
// message (0x23). Same doctrine as the other loaders: TestKit may
// import Foundation, LyteWire may not.

import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/repair-refusal-v1.json`.
public struct RepairRefusalVectorFile: Codable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var vectors: [RepairRefusalVector]

    public static let expectedFormat = "lyte-wire-repair-refusal-vectors"

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        vectors: [RepairRefusalVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.vectors = vectors
    }

    public static func load(from path: String) throws -> RepairRefusalVectorFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(RepairRefusalVectorFile.self, from: data)
    }
}

/// One repair-refusal vector. Kinds match the session file (`roundtrip`
/// encodes the typed fields byte-exact to `messageHex` and decodes
/// back; `decodeReject` throws `error`, a `RepairRefusalError` case
/// name). `frame`/`reason` are present on roundtrips.
public struct RepairRefusalVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var messageHex: String
    public var frame: UInt32?
    public var reason: UInt8?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeReject
    }

    public init(
        name: String,
        description: String,
        kind: Kind,
        messageHex: String,
        frame: UInt32? = nil,
        reason: UInt8? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.messageHex = messageHex
        self.frame = frame
        self.reason = reason
        self.error = error
    }
}

/// Stable names for `RepairRefusalError` cases, as they appear in
/// vectors.
public func repairRefusalErrorName(_ error: RepairRefusalError) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .trailingBytes: return "trailingBytes"
    case .unexpectedType: return "unexpectedType"
    case .unknownReason: return "unknownReason"
    }
}
