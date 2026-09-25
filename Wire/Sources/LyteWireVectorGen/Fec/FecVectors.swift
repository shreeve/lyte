// The FEC vector-file model and loader for Wire/Vectors/fec-v1.json. The
// RS parity bytes are wire contract, byte-identical across platforms.

import LyteWire
import LyteWireTestKit

/// One vector file: `Wire/Vectors/fec-v1.json`.
public struct FecVectorFile: FrozenVectorFile {
    /// Always "lyte-wire-fec-vectors".
    public var format = Self.expectedFormat
    public var formatVersion = 1
    public var wireVersion = 1
    /// fec-field codec vectors (the envelope's 8-byte field).
    public var fieldVectors: [FecFieldVector]
    /// The parity ladder pinned as data, boundary rows included;
    /// `parityShards` null = unprotectable (lookup throws).
    public var geometryRows: [FecGeometryRow]
    /// RS encode/recovery matrices: parity bytes and recovery outcomes.
    public var recoveryMatrices: [FecRecoveryMatrix]

    public static let expectedFormat = "lyte-wire-fec-vectors"
    public static let fileName = "fec-v1.json"

    public var vectorNameGroups: [[String]] {
        [fieldVectors.map(\.name), recoveryMatrices.map(\.name)]
    }
}

/// One fec-field vector. `rawHex` is the field's u64 value in hex (the
/// envelope's `fecHex` convention; the wire byte order is the envelope
/// codec's business). Kinds mirror envelope-v1.json:
/// - `roundtrip`: field encodes to exactly rawHex and rawHex decodes to
///   field.
/// - `decodeLenient`: rawHex decodes to field but a canonical re-encode
///   differs (non-zero reserved byte 7) — decode-only.
/// - `decodeReject`: decoding rawHex throws `error`.
public struct FecFieldVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var field: FecFieldFields?
    public var rawHex: String
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeLenient
        case decodeReject
    }
}

/// A decoded fec field in vector-file form. `scheme` "none" carries no
/// other fields; "reedSolomon" carries all four.
public struct FecFieldFields: Codable, Sendable {
    public var scheme: String
    public var shardIndex: UInt8?
    public var dataShards: Int?
    public var parityShards: Int?
    public var groupByteCount: Int?

    public init(from field: FecField) {
        switch field {
        case .none:
            self.scheme = "none"
        case .reedSolomon(let shardIndex, let geometry):
            self.scheme = "reedSolomon"
            self.shardIndex = shardIndex
            self.dataShards = geometry.dataShards
            self.parityShards = geometry.parityShards
            self.groupByteCount = geometry.groupByteCount
        }
    }

    public func makeField() throws -> FecField {
        switch scheme {
        case "none":
            return .none
        case "reedSolomon":
            guard
                let shardIndex, let dataShards, let parityShards,
                let groupByteCount
            else {
                throw VectorFileError.malformedField("reedSolomon fields")
            }
            let geometry = try FecGeometry(
                dataShards: dataShards,
                parityShards: parityShards,
                groupByteCount: groupByteCount
            )
            return .reedSolomon(shardIndex: shardIndex, geometry: geometry)
        default:
            throw VectorFileError.malformedField("scheme \(scheme)")
        }
    }
}

/// One parity-ladder expectation: `parityShards(forDataShards:regime:)`
/// returns `parityShards`, or throws when it is null.
public struct FecGeometryRow: Codable, Sendable {
    public var dataShards: Int
    public var regime: String
    public var parityShards: Int?

    public init(dataShards: Int, regime: FecRegime, parityShards: Int?) {
        self.dataShards = dataShards
        self.regime = regime.rawValue
        self.parityShards = parityShards
    }
}

/// One RS matrix: `shardsHex` are the k+m wire shards FecEncoder must
/// produce byte-exact from `groupHex`; decoding with `erasedIndices`
/// nil'd out must return `groupHex` byte-exact (`expect` "recovered")
/// or throw unrecoverableGroup (`expect` "unrecoverable").
public struct FecRecoveryMatrix: Codable, Sendable {
    public var name: String
    public var description: String
    public var dataShards: Int
    public var parityShards: Int
    public var groupByteCount: Int
    public var groupHex: String
    public var shardsHex: [String]
    public var erasedIndices: [Int]
    public var expect: Expect

    public enum Expect: String, Codable, Sendable {
        case recovered
        case unrecoverable
    }

    public init(
        name: String,
        description: String,
        geometry: FecGeometry,
        groupHex: String,
        shardsHex: [String],
        erasedIndices: [Int],
        expect: Expect
    ) {
        self.name = name
        self.description = description
        self.dataShards = geometry.dataShards
        self.parityShards = geometry.parityShards
        self.groupByteCount = geometry.groupByteCount
        self.groupHex = groupHex
        self.shardsHex = shardsHex
        self.erasedIndices = erasedIndices
        self.expect = expect
    }

    public func makeGeometry() throws -> FecGeometry {
        try FecGeometry(
            dataShards: dataShards,
            parityShards: parityShards,
            groupByteCount: groupByteCount
        )
    }
}
