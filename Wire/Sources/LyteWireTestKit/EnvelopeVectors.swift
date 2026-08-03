// The envelope vector-file model and loader. Vector files under
// Wire/Vectors/ are the frozen wire contract (master plan §4.12): the
// client's CL-1 verifies against the same files this package's own tests
// do, byte-exact, on both platforms. TestKit may import Foundation — only
// LyteWire itself is Foundation-free.

import LyteCore
import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/envelope-v1.json`.
public struct EnvelopeVectorFile: Codable, Sendable {
    /// Always "lyte-wire-envelope-vectors"; guards against loading the
    /// wrong artifact once W1/W2/W4a ship their own vector kinds.
    public var format: String
    /// Version of the vector file format itself.
    public var formatVersion: Int
    /// The wire major version these vectors pin.
    public var wireVersion: Int
    public var vectors: [EnvelopeVector]
    /// The (chan, seq) serial-arithmetic contract, as data.
    public var seqComparisons: [SeqComparison]

    public static let expectedFormat = "lyte-wire-envelope-vectors"

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        vectors: [EnvelopeVector],
        seqComparisons: [SeqComparison]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.vectors = vectors
        self.seqComparisons = seqComparisons
    }

    public static func load(from path: String) throws -> EnvelopeVectorFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(EnvelopeVectorFile.self, from: data)
    }
}

/// One test vector. `kind` selects which fields apply:
/// - `roundtrip`: envelope + payloadHex encode to exactly datagramHex, and
///   datagramHex decodes back to envelope + payloadHex.
/// - `decodeLenient`: datagramHex decodes to envelope + payloadHex, but a
///   canonical re-encode differs (reserved flag bits, non-canonical TLV
///   presence) — decode-only.
/// - `encodeReject`: encoding envelope + payloadHex throws `error`;
///   `encoder` says which entry point ("payload" or "plaintextShard").
/// - `decodeReject`: decoding datagramHex throws `error`.
public struct EnvelopeVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var envelope: EnvelopeFields?
    public var encoder: Encoder?
    public var payloadHex: String?
    public var datagramHex: String?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeLenient
        case encodeReject
        case decodeReject
    }

    public enum Encoder: String, Codable, Sendable {
        case payload
        case plaintextShard
    }

    public init(
        name: String,
        description: String,
        kind: Kind,
        envelope: EnvelopeFields?,
        encoder: Encoder?,
        payloadHex: String?,
        datagramHex: String?,
        error: String?
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.envelope = envelope
        self.encoder = encoder
        self.payloadHex = payloadHex
        self.datagramHex = datagramHex
        self.error = error
    }
}

/// The 24-byte header fields plus TLVs, in vector-file form. Timestamp and
/// fec are hex strings because u64 does not survive JSON number precision.
public struct EnvelopeFields: Codable, Sendable {
    public var chan: UInt8
    public var seq: UInt16
    public var frame: UInt32
    public var timestampHex: String
    public var fecHex: String
    public var tlvs: [TlvField]?

    public init(from envelope: Envelope) {
        self.chan = envelope.channel.rawValue
        self.seq = envelope.seq.rawValue
        self.frame = envelope.frame.rawValue
        self.timestampHex = Hex.uint64String(envelope.timestamp)
        self.fecHex = Hex.uint64String(envelope.fec)
        let tlvs = envelope.extensions.map {
            TlvField(type: $0.type, valueHex: Hex.string($0.value))
        }
        self.tlvs = tlvs.isEmpty ? nil : tlvs
    }

    public func makeEnvelope() throws -> Envelope {
        guard
            let timestamp = Hex.uint64(timestampHex),
            let fec = Hex.uint64(fecHex)
        else {
            throw VectorFileError.malformedField("timestampHex/fecHex")
        }
        let extensions = try (tlvs ?? []).map { tlv -> WireExtension in
            guard let value = Hex.bytes(tlv.valueHex) else {
                throw VectorFileError.malformedField("tlv valueHex")
            }
            return try WireExtension(type: tlv.type, value: value)
        }
        return Envelope(
            channel: ChannelId(rawValue: chan),
            seq: ChannelSeq(rawValue: seq),
            frame: FrameNumber(rawValue: frame),
            timestamp: timestamp,
            fec: fec,
            extensions: extensions
        )
    }
}

public struct TlvField: Codable, Sendable {
    public var type: UInt8
    public var valueHex: String

    public init(type: UInt8, valueHex: String) {
        self.type = type
        self.valueHex = valueHex
    }
}

/// A serial-arithmetic expectation: `aBeforeB` is `ChannelSeq(a) <
/// ChannelSeq(b)`, `distance` is the signed serial distance a→b.
public struct SeqComparison: Codable, Sendable {
    public var a: UInt16
    public var b: UInt16
    public var aBeforeB: Bool
    public var distance: Int16

    public init(a: UInt16, b: UInt16, aBeforeB: Bool, distance: Int16) {
        self.a = a
        self.b = b
        self.aBeforeB = aBeforeB
        self.distance = distance
    }
}

public enum VectorFileError: Error, Equatable, Sendable {
    case malformedField(String)
}

/// Stable names for `WireError` cases, as they appear in vector files.
public func wireErrorName(_ error: WireError) -> String {
    switch error {
    case .truncatedEnvelope: return "truncatedEnvelope"
    case .truncatedExtensions: return "truncatedExtensions"
    case .tooManyExtensions: return "tooManyExtensions"
    case .extensionValueTooLong: return "extensionValueTooLong"
    case .shardOverBudget: return "shardOverBudget"
    case .payloadOverBudget: return "payloadOverBudget"
    case .datagramOverBudget: return "datagramOverBudget"
    }
}
