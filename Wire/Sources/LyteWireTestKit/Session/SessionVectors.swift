// The session-codec vector-file model and loader:
// `Wire/Vectors/session-v1.json` — the CTRL/TLV codecs that were pinned
// end-side (HS-12's conn-id TLV + path pair, HS-7/CL-3's IDR request) and
// promoted into LyteWire by the codec-unification slice. Same doctrine as
// the other loaders: TestKit may import Foundation, LyteWire may not.

import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/session-v1.json`.
public struct SessionVectorFile: Codable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var vectors: [SessionVector]

    public static let expectedFormat = "lyte-wire-session-vectors"

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        vectors: [SessionVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.vectors = vectors
    }

    public static func load(from path: String) throws -> SessionVectorFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(SessionVectorFile.self, from: data)
    }
}

/// One session-codec vector. `codec` names the codec under test; kinds
/// match the envelope file (`roundtrip` encodes fields to exactly
/// `messageHex` and decodes back; `decodeReject` throws `error`, a case
/// name of the codec's error type). For `connectionIdTlv`, `messageHex`
/// is a whole envelope datagram: decode must yield the conn-id whose
/// bytes are `connectionIdHex` (roundtrip: re-encoding the decoded
/// envelope + payload reproduces the datagram byte-exactly).
public struct SessionVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var codec: SessionCodec
    public var messageHex: String
    /// pathChallenge/pathResponse: the u64 token (hex, LE on the wire).
    public var tokenHex: String?
    /// idrRequest fields.
    public var requestSeq: UInt32?
    public var frame: UInt32?
    public var coalescedCount: UInt8?
    /// connectionIdTlv: the 8 identity bytes.
    public var connectionIdHex: String?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeReject
    }

    public enum SessionCodec: String, Codable, Sendable {
        case pathChallenge
        case pathResponse
        case idrRequest
        case connectionIdTlv
    }

    public init(
        name: String,
        description: String,
        kind: Kind,
        codec: SessionCodec,
        messageHex: String,
        tokenHex: String? = nil,
        requestSeq: UInt32? = nil,
        frame: UInt32? = nil,
        coalescedCount: UInt8? = nil,
        connectionIdHex: String? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.codec = codec
        self.messageHex = messageHex
        self.tokenHex = tokenHex
        self.requestSeq = requestSeq
        self.frame = frame
        self.coalescedCount = coalescedCount
        self.connectionIdHex = connectionIdHex
        self.error = error
    }
}

/// Stable names for `PathMessageError` cases, as they appear in vectors.
public func pathMessageErrorName(_ error: PathMessageError) -> String {
    switch error {
    case .truncated: return "truncated"
    case .unexpectedType: return "unexpectedType"
    }
}

/// Stable names for `IdrRequestError` cases, as they appear in vectors.
public func idrRequestErrorName(_ error: IdrRequestError) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .trailingBytes: return "trailingBytes"
    case .unexpectedType: return "unexpectedType"
    }
}

/// Stable names for `ConnectionIdError` cases, as they appear in vectors.
public func connectionIdErrorName(_ error: ConnectionIdError) -> String {
    switch error {
    case .invalidValueLength: return "invalidValueLength"
    case .duplicateTlv: return "duplicateTlv"
    }
}
