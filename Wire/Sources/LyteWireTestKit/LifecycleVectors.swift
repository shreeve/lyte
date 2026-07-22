// The lifecycle-codec vector-file model and loader:
// `Wire/Vectors/lifecycle-v1.json` — the W4b session-lifecycle CTRL
// messages (mode transition 0x09, session teardown 0x0A). Same doctrine
// as the other loaders: TestKit may import Foundation, LyteWire may not.

import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/lifecycle-v1.json`.
public struct LifecycleVectorFile: Codable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var vectors: [LifecycleVector]

    public static let expectedFormat = "lyte-wire-lifecycle-vectors"

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        vectors: [LifecycleVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.vectors = vectors
    }

    public static func load(from path: String) throws -> LifecycleVectorFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(LifecycleVectorFile.self, from: data)
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

    public init(
        name: String,
        description: String,
        kind: Kind,
        codec: LifecycleCodec,
        messageHex: String,
        value: UInt8? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.codec = codec
        self.messageHex = messageHex
        self.value = value
        self.error = error
    }
}

/// Stable names for `LifecycleMessageError` cases, as they appear in
/// vectors.
public func lifecycleMessageErrorName(_ error: LifecycleMessageError) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .trailingBytes: return "trailingBytes"
    case .unexpectedType: return "unexpectedType"
    case .unknownMode: return "unknownMode"
    case .unknownReason: return "unknownReason"
    }
}
