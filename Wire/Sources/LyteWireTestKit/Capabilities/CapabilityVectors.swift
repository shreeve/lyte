// The capability vector-file model and loader:
// `Wire/Vectors/capabilities-v1.json` — the W7 layer top to bottom:
// the deterministic CBOR profile, the typed capability set, the
// intersect algebra as data, and the CTRL message codecs 0x0F/0x11/
// 0x12. Same doctrine as the other loaders: TestKit may import
// Foundation, LyteWire may not.

import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/capabilities-v1.json`.
public struct CapabilityVectorFile: Codable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var cborVectors: [CapabilityCborVector]
    public var setVectors: [CapabilitySetVector]
    public var intersectVectors: [CapabilityIntersectVector]
    public var messageVectors: [CapabilityMessageVector]

    public static let expectedFormat = "lyte-wire-capability-vectors"

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        cborVectors: [CapabilityCborVector],
        setVectors: [CapabilitySetVector],
        intersectVectors: [CapabilityIntersectVector],
        messageVectors: [CapabilityMessageVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.cborVectors = cborVectors
        self.setVectors = setVectors
        self.intersectVectors = intersectVectors
        self.messageVectors = messageVectors
    }

    public static func load(from path: String) throws -> CapabilityVectorFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(
            CapabilityVectorFile.self, from: data
        )
    }
}

/// One CBOR-profile vector. `canonical`: `cborHex` must decode and
/// re-encode byte-exact (canonical admission + deterministic
/// re-emission in one check). `decodeReject`: decoding throws `error`,
/// a `CborError` case name.
public struct CapabilityCborVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var cborHex: String
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case canonical
        case decodeReject
    }

    public init(
        name: String,
        description: String,
        kind: Kind,
        cborHex: String,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.cborHex = cborHex
        self.error = error
    }
}

/// The typed field view of a capability set, JSON-friendly. Unknown
/// entries appear only as a count — their bytes are pinned by the
/// vector's `cborHex` through the re-encode check.
public struct CapabilitySetFields: Codable, Sendable {
    public var wireMinor: UInt16
    public var videoCodecs: [UInt64]
    public var chromaModes: [UInt64]
    public var idleSilence: Bool
    public var featureChannels: [UInt64]
    public var audioExpress: Bool
    public var resume: Bool
    public var maxDatagramBytes: UInt32
    public var unknownKeyCount: Int

    public init(_ capabilities: Capabilities) {
        self.wireMinor = capabilities.wireMinor
        self.videoCodecs = capabilities.videoCodecs
        self.chromaModes = capabilities.chromaModes
        self.idleSilence = capabilities.idleSilence
        self.featureChannels = capabilities.featureChannels
        self.audioExpress = capabilities.audioExpress
        self.resume = capabilities.resume
        self.maxDatagramBytes = capabilities.maxDatagramBytes
        self.unknownKeyCount = capabilities.unknownEntries.count
    }

    /// The typed set, unknown entries excepted (only constructible
    /// when `unknownKeyCount` is 0 — the loader's test enforces it).
    public var capabilities: Capabilities {
        Capabilities(
            wireMinor: wireMinor,
            videoCodecs: videoCodecs,
            chromaModes: chromaModes,
            idleSilence: idleSilence,
            featureChannels: featureChannels,
            audioExpress: audioExpress,
            resume: resume,
            maxDatagramBytes: maxDatagramBytes
        )
    }

    public func matches(_ capabilities: Capabilities) -> Bool {
        wireMinor == capabilities.wireMinor
            && videoCodecs == capabilities.videoCodecs
            && chromaModes == capabilities.chromaModes
            && idleSilence == capabilities.idleSilence
            && featureChannels == capabilities.featureChannels
            && audioExpress == capabilities.audioExpress
            && resume == capabilities.resume
            && maxDatagramBytes == capabilities.maxDatagramBytes
            && unknownKeyCount == capabilities.unknownEntries.count
    }
}

/// One capability-set vector. `roundtrip`: `cborHex` decodes to a set
/// matching `set` and re-encodes byte-exact; with `unknownKeyCount`
/// 0, encoding the typed fields must also produce `cborHex` exactly.
/// `decodeLenient`: decodes to `set` but is a non-canonical form of
/// it (omitted optional keys re-encode explicit) — decode-only.
/// `decodeReject`: decoding throws `error`, a `CapabilityError` case
/// name.
public struct CapabilitySetVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var cborHex: String
    public var set: CapabilitySetFields?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeLenient
        case decodeReject
    }

    public init(
        name: String,
        description: String,
        kind: Kind,
        cborHex: String,
        set: CapabilitySetFields? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.cborHex = cborHex
        self.set = set
        self.error = error
    }
}

/// One intersect vector — the W-G8 algebra as frozen data: decoding
/// `aHex` and `bHex` and intersecting IN BOTH ORDERS must produce
/// exactly `agreedHex` (commutativity is pinned by construction).
public struct CapabilityIntersectVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var aHex: String
    public var bHex: String
    public var agreedHex: String

    public init(
        name: String,
        description: String,
        aHex: String,
        bHex: String,
        agreedHex: String
    ) {
        self.name = name
        self.description = description
        self.aHex = aHex
        self.bHex = bHex
        self.agreedHex = agreedHex
    }
}

/// One message-codec vector. `codec` names the codec under test;
/// `roundtrip` decodes `messageHex` and re-encodes byte-exact,
/// `decodeReject` throws `error`, a `CapabilityMessageError` case
/// name.
public struct CapabilityMessageVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var codec: Codec
    public var messageHex: String
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeReject
    }

    public enum Codec: String, Codable, Sendable {
        case declaration
        case update
        case updateAck
    }

    public init(
        name: String,
        description: String,
        kind: Kind,
        codec: Codec,
        messageHex: String,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.codec = codec
        self.messageHex = messageHex
        self.error = error
    }
}

/// Stable names for `CborError` cases, as they appear in vectors.
public func cborErrorName(_ error: CborError) -> String {
    switch error {
    case .truncatedItem: return "truncatedItem"
    case .trailingBytes: return "trailingBytes"
    case .unsupportedItem: return "unsupportedItem"
    case .nonCanonicalArgument: return "nonCanonicalArgument"
    case .misorderedMapKeys: return "misorderedMapKeys"
    case .duplicateMapKey: return "duplicateMapKey"
    case .invalidUtf8: return "invalidUtf8"
    case .nestingTooDeep: return "nestingTooDeep"
    }
}

/// Stable names for `CapabilityError` cases, as they appear in
/// vectors.
public func capabilityErrorName(_ error: CapabilityError) -> String {
    switch error {
    case .malformedCbor: return "malformedCbor"
    case .notAMap: return "notAMap"
    case .missingKey: return "missingKey"
    case .wrongValueType: return "wrongValueType"
    case .nonCanonicalIdList: return "nonCanonicalIdList"
    case .datagramCeilingBelowFloor: return "datagramCeilingBelowFloor"
    }
}

/// Stable names for `CapabilityMessageError` cases, as they appear in
/// vectors.
public func capabilityMessageErrorName(
    _ error: CapabilityMessageError
) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .unexpectedType: return "unexpectedType"
    case .unknownStatus: return "unknownStatus"
    case .messageOverBudget: return "messageOverBudget"
    case .emptyUpdate: return "emptyUpdate"
    case .nonIntegerParameterKey: return "nonIntegerParameterKey"
    case .malformedBody: return "malformedBody"
    }
}
