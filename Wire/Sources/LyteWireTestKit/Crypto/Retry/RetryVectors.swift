// The retry-cookie vector-file model and loader: `Wire/Vectors/retry-v1.json`.
// - `cookieVectors`: RetryCookie mint/verify as data, pinned
//   self-consistent (the HMAC beneath is anchored in RetryCookieTests).
// - `messageVectors`: the CTRL 0x13/0x14 codec layouts, anchored against
//   the hand-built bytes in RetryCodecTests.

import Foundation
import LyteWire

public struct RetryVectorFile: FrozenVectorFile {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var cookieVectors: [RetryCookieVector]
    public var messageVectors: [RetryMessageVector]

    public static let expectedFormat = "lyte-wire-retry-vectors"
    public static let fileName = "retry-v1.json"

    public var vectorNameGroups: [[String]] {
        [cookieVectors.map(\.name), messageVectors.map(\.name)]
    }

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        cookieVectors: [RetryCookieVector],
        messageVectors: [RetryMessageVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.cookieVectors = cookieVectors
        self.messageVectors = messageVectors
    }

}

/// One cookie vector. `mint`: minting with (tupleHex, message1Hex,
/// mintNowHex, secretHex) must produce exactly `cookieHex`, and verifying
/// it at `verifyNowHex` under `secretsHex` (current-first) must answer
/// `valid`. `verify`: `cookieHex` is presented as-is and must answer
/// `valid`. `lifetimeNowHex` overrides the default lifetime when present.
public struct RetryCookieVector: Codable, Sendable {
    public var name: String
    public var description: String
    /// Honesty marker; always "pinned-self-consistent" in v1.
    public var provenance: String
    public var kind: Kind
    public var tupleHex: String
    public var message1Hex: String
    public var mintNowHex: String?
    public var secretHex: String?
    public var cookieHex: String
    public var verifyNowHex: String
    public var secretsHex: [String]
    public var lifetimeHex: String?
    public var valid: Bool

    public enum Kind: String, Codable, Sendable {
        case mint
        case verify
    }

    public init(
        name: String,
        description: String,
        provenance: String,
        kind: Kind,
        tupleHex: String,
        message1Hex: String,
        mintNowHex: String? = nil,
        secretHex: String? = nil,
        cookieHex: String,
        verifyNowHex: String,
        secretsHex: [String],
        lifetimeHex: String? = nil,
        valid: Bool
    ) {
        self.name = name
        self.description = description
        self.provenance = provenance
        self.kind = kind
        self.tupleHex = tupleHex
        self.message1Hex = message1Hex
        self.mintNowHex = mintNowHex
        self.secretHex = secretHex
        self.cookieHex = cookieHex
        self.verifyNowHex = verifyNowHex
        self.secretsHex = secretsHex
        self.lifetimeHex = lifetimeHex
        self.valid = valid
    }
}

/// One codec vector for the 0x13/0x14 layouts, the lifecycle file's
/// kinds over `messageHex`.
public struct RetryMessageVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var codec: Codec
    public var messageHex: String
    /// Roundtrip fields: the decoded cookie, and (handshake1 only)
    /// the decoded message 1.
    public var cookieHex: String?
    public var message1Hex: String?
    /// decodeReject: the RetryMessageError case name.
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeReject
    }

    public enum Codec: String, Codable, Sendable {
        case challenge
        case handshake1
    }

    public init(
        name: String,
        description: String,
        kind: Kind,
        codec: Codec,
        messageHex: String,
        cookieHex: String? = nil,
        message1Hex: String? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.codec = codec
        self.messageHex = messageHex
        self.cookieHex = cookieHex
        self.message1Hex = message1Hex
        self.error = error
    }
}
