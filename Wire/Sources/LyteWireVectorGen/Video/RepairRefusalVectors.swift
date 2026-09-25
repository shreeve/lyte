// The repair-refusal vector-file model and loader:
// `Wire/Vectors/repair-refusal-v1.json` — the repair-refusal CTRL message
// (0x23).

import LyteWire
import LyteWireTestKit

/// One vector file: `Wire/Vectors/repair-refusal-v1.json`.
public struct RepairRefusalVectorFile: FrozenVectorFile {
    public var format = Self.expectedFormat
    public var formatVersion = 1
    public var wireVersion = 1
    public var vectors: [RepairRefusalVector]

    public static let expectedFormat = "lyte-wire-repair-refusal-vectors"
    public static let fileName = "repair-refusal-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
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
}
