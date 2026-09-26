// The lifecycle-codec vector-file model and loader:
// `Wire/Vectors/lifecycle-v1.json` — mode transition 0x09 and session
// teardown 0x0A.

import LyteWire
import LyteWireTestKit

/// One vector file: `Wire/Vectors/lifecycle-v1.json`.
public struct LifecycleVectorFile: FrozenVectorFile {
    public var format = Self.expectedFormat
    public var formatVersion = 1
    public var wireVersion = 1
    public var vectors: [LifecycleVector]

    public static let expectedFormat = "lyte-wire-lifecycle-vectors"
    public static let fileName = "lifecycle-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
    }
}

/// One lifecycle-codec vector. `codec` names the codec under test;
/// kinds match the session file (`roundtrip` encodes the typed value
/// byte-exact to `messageHex` and decodes back; `decodeReject` throws
/// `error`, a `LifecycleMessageError` case name). `value` is the mode
/// or reason raw byte, present on roundtrips.
public struct LifecycleVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var codec: LifecycleCodec
    public var messageHex: String
    public var value: UInt8?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeReject
    }

    public enum LifecycleCodec: String, Codable, Sendable {
        case modeTransition
        case sessionTeardown
    }
}
