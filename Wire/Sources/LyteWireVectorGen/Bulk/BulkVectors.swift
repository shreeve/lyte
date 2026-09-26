// The bulk-transfer vector-file model and loader: `Wire/Vectors/bulk-v1.json`
// (the bulk-channel messages 0x1C–0x21, the key-11 capability, and worked
// multi-session transfer traces). u64 fields ride as hex.

import LyteWire
import LyteWireTestKit

/// One vector file: `Wire/Vectors/bulk-v1.json`.
public struct BulkVectorFile: FrozenVectorFile {
    public var format = Self.expectedFormat
    public var formatVersion = 1
    public var wireVersion = 1
    public var messageVectors: [BulkMessageVector]
    public var capabilityVectors: [BulkCapabilityVector]
    public var transferVectors: [BulkTransferVector]

    public static let expectedFormat = "lyte-wire-bulk-vectors"
    public static let fileName = "bulk-v1.json"

    public var vectorNameGroups: [[String]] {
        [messageVectors.map(\.name), capabilityVectors.map(\.name), transferVectors.map(\.name)]
    }
}

/// One message-codec vector. `codec` names the codec under test;
/// kinds: `roundtrip` builds the typed value from the fields, encodes
/// to exactly `messageHex`, and decodes back field-exact;
/// `decodeReject` throws `error` decoding `messageHex`;
/// `encodeReject` throws `error` CONSTRUCTING the typed value from
/// the fields (bounds only the u8/u16 wire widths make inexpressible
/// as bytes: over-budget names/MIME hints, a wrong-width digest).
/// `error` names are `BulkMessageError` case names.
public struct BulkMessageVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var kind: Kind
    public var codec: BulkCodec
    /// Absent for encodeReject (nothing ever encodes).
    public var messageHex: String?
    public var transferIdHex: String?
    public var totalByteCountHex: String?
    public var chunkByteCount: Int?
    public var sha256Hex: String?
    public var nameUtf8Hex: String?
    public var mimeUtf8Hex: String?
    public var creditTotalHex: String?
    public var contiguousCountHex: String?
    public var bitmapHex: String?
    public var chunkIndexHex: String?
    public var dataHex: String?
    /// Abort roundtrips: the `BulkAbortReason` case name.
    public var reason: String?
    public var error: String?

    public enum Kind: String, Codable, Sendable {
        case roundtrip
        case decodeReject
        case encodeReject
    }

    public enum BulkCodec: String, Codable, Sendable {
        case offer
        case accept
        case chunk
        case ack
        case complete
        case abort
    }
}

/// One key-11 capability-spine vector: `messageHex` is a declaration's
/// CBOR map; decode must answer exactly `bulkTransfer` through the key-11
/// accessor and re-encode byte-exactly.
public struct BulkCapabilityVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var messageHex: String
    public var bulkTransfer: Bool
}

/// A possession set as vector data (small counts — plain JSON ints
/// are safe here).
public struct BulkPossessionSpec: Codable, Sendable {
    public var contiguousCount: Int
    public var extraChunkIndices: [Int] = []

    public var possession: BulkPossession {
        BulkPossession(
            contiguousCount: UInt64(contiguousCount),
            extras: Set(extraChunkIndices.map(UInt64.init))
        )
    }
}

/// One worked transfer, pinned self-consistent (the codecs beneath are
/// anchored by hand in BulkCodecTests). The payload is the counting-byte
/// pattern `byte[i] = (payloadStart + i) & 0xFF`. Sessions replay through
/// `BulkTransferHarness` with auto-consent and synchronous storage; each
/// session's complete per-direction emissions are frozen byte-exact.
/// `receiverIngestLimit` models a teardown after N sender messages, the
/// next session resuming from persisted state; `initialPossession` seeds
/// a pre-existing (possibly holed) resume state.
public struct BulkTransferVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var provenance: String
    public var transferIdHex: String
    public var totalByteCount: Int
    public var chunkByteCount: Int
    public var payloadStart: Int
    public var sha256Hex: String
    public var fileName: String
    public var mimeHint: String
    public var receiveWindowChunks: Int
    public var initialPossession: BulkPossessionSpec?
    public var sessions: [BulkTransferSessionVector]
}

/// One session of a worked transfer: the complete emission lists,
/// both directions, in emission order.
public struct BulkTransferSessionVector: Codable, Sendable {
    /// nil = the receiver ingests everything (the session runs out).
    public var receiverIngestLimit: Int?
    public var senderMessagesHex: [String]
    public var receiverMessagesHex: [String]
}

/// A `BulkAbortReason`'s name in vector files: its Swift case name.
public func bulkAbortReasonName(_ reason: BulkAbortReason) -> String {
    "\(reason)"
}

public func bulkAbortReason(named name: String) -> BulkAbortReason? {
    BulkAbortReason.allCases.first { bulkAbortReasonName($0) == name }
}
