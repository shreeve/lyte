// The repair-refusal vector-file model and loader:
// `Wire/Vectors/repair-refusal-v1.json` — the repair-refusal CTRL message
// (0x23).

import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/repair-refusal-v1.json`.
public struct RepairRefusalVectorFile: FrozenVectorFile {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var vectors: [RepairRefusalVector]

    public static let expectedFormat = "lyte-wire-repair-refusal-vectors"
    public static let fileName = "repair-refusal-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
    }

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

}

/// One repair-refusal vector. Kinds match the session file; `error` is a
/// `RepairRefusalError` case name; `frame`/`reason` are present on
/// roundtrips.
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
