// The session-codec vector-file model and loader:
// `Wire/Vectors/session-v1.json` — the conn-id TLV, the path pair, and the
// IDR request.

import LyteWire
import LyteWireTestKit

/// One vector file: `Wire/Vectors/session-v1.json`.
public struct SessionVectorFile: FrozenVectorFile {
    public var format = Self.expectedFormat
    public var formatVersion = 1
    public var wireVersion = 1
    public var vectors: [SessionVector]

    public static let expectedFormat = "lyte-wire-session-vectors"
    public static let fileName = "session-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
    }
}

/// One session-codec vector. `codec` names the codec under test; kinds
/// match the envelope file (`error` is a case name of the codec's error
/// type). For `connectionIdTlv`, `messageHex` is a whole envelope datagram:
/// decode must yield the conn-id `connectionIdHex` and re-encode
/// byte-exactly.
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
}
