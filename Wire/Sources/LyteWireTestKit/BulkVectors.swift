// The bulk-transfer vector-file model and loader:
// `Wire/Vectors/bulk-v1.json` — the W10/F-2 bulk-channel sextet
// (0x1C–0x21), the key-11 capability spine, and the worked
// multi-session transfer traces. Same doctrine as the other loaders:
// TestKit may import Foundation, LyteWire may not. u64 fields ride as
// hex, the house JSON-precision rule.

import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/bulk-v1.json`.
public struct BulkVectorFile: Codable, Sendable {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var messageVectors: [BulkMessageVector]
    public var capabilityVectors: [BulkCapabilityVector]
    public var transferVectors: [BulkTransferVector]

    public static let expectedFormat = "lyte-wire-bulk-vectors"

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        messageVectors: [BulkMessageVector],
        capabilityVectors: [BulkCapabilityVector],
        transferVectors: [BulkTransferVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.messageVectors = messageVectors
        self.capabilityVectors = capabilityVectors
        self.transferVectors = transferVectors
    }

    public static func load(from path: String) throws -> BulkVectorFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(BulkVectorFile.self, from: data)
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

    public init(
        name: String,
        description: String,
        kind: Kind,
        codec: BulkCodec,
        messageHex: String? = nil,
        transferIdHex: String? = nil,
        totalByteCountHex: String? = nil,
        chunkByteCount: Int? = nil,
        sha256Hex: String? = nil,
        nameUtf8Hex: String? = nil,
        mimeUtf8Hex: String? = nil,
        creditTotalHex: String? = nil,
        contiguousCountHex: String? = nil,
        bitmapHex: String? = nil,
        chunkIndexHex: String? = nil,
        dataHex: String? = nil,
        reason: String? = nil,
        error: String? = nil
    ) {
        self.name = name
        self.description = description
        self.kind = kind
        self.codec = codec
        self.messageHex = messageHex
        self.transferIdHex = transferIdHex
        self.totalByteCountHex = totalByteCountHex
        self.chunkByteCount = chunkByteCount
        self.sha256Hex = sha256Hex
        self.nameUtf8Hex = nameUtf8Hex
        self.mimeUtf8Hex = mimeUtf8Hex
        self.creditTotalHex = creditTotalHex
        self.contiguousCountHex = contiguousCountHex
        self.bitmapHex = bitmapHex
        self.chunkIndexHex = chunkIndexHex
        self.dataHex = dataHex
        self.reason = reason
        self.error = error
    }
}

/// One key-11 capability-spine vector (the clipboard key-10 file's
/// shape): `messageHex` is a declaration's CBOR map; decode must
/// answer exactly `bulkTransfer` through the key-11 accessor and
/// re-encode byte-exactly.
public struct BulkCapabilityVector: Codable, Sendable {
    public var name: String
    public var description: String
    public var messageHex: String
    public var bulkTransfer: Bool

    public init(
        name: String,
        description: String,
        messageHex: String,
        bulkTransfer: Bool
    ) {
        self.name = name
        self.description = description
        self.messageHex = messageHex
        self.bulkTransfer = bulkTransfer
    }
}

/// A possession set as vector data (small counts — plain JSON ints
/// are safe here).
public struct BulkPossessionSpec: Codable, Sendable {
    public var contiguousCount: Int
    public var extraChunkIndices: [Int]

    public init(contiguousCount: Int, extraChunkIndices: [Int] = []) {
        self.contiguousCount = contiguousCount
        self.extraChunkIndices = extraChunkIndices
    }

    public var possession: BulkPossession {
        BulkPossession(
            contiguousCount: UInt64(contiguousCount),
            extras: Set(extraChunkIndices.map(UInt64.init))
        )
    }
}

/// One worked transfer, pinned self-consistent (the noise-transport
/// provenance discipline: no external oracle covers our composition;
/// the codecs beneath are anchored by hand in BulkCodecTests). The
/// payload is the counting-byte pattern `byte[i] = (payloadStart + i)
/// & 0xFF`, auditable by eye. Sessions replay through
/// `BulkTransferHarness` (TestKit) with auto-consent and synchronous
/// storage; each session's COMPLETE per-direction emission lists are
/// frozen byte-exact. `receiverIngestLimit` models the teardown: the
/// receiver ingests only the first N sender messages, then the
/// session dies and the next one resumes from the persisted state.
/// `initialPossession` seeds a pre-existing resume state (the holed-
/// map case a prefix-shaped live teardown cannot produce).
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

    public init(
        name: String,
        description: String,
        provenance: String,
        transferIdHex: String,
        totalByteCount: Int,
        chunkByteCount: Int,
        payloadStart: Int,
        sha256Hex: String,
        fileName: String,
        mimeHint: String,
        receiveWindowChunks: Int,
        initialPossession: BulkPossessionSpec? = nil,
        sessions: [BulkTransferSessionVector]
    ) {
        self.name = name
        self.description = description
        self.provenance = provenance
        self.transferIdHex = transferIdHex
        self.totalByteCount = totalByteCount
        self.chunkByteCount = chunkByteCount
        self.payloadStart = payloadStart
        self.sha256Hex = sha256Hex
        self.fileName = fileName
        self.mimeHint = mimeHint
        self.receiveWindowChunks = receiveWindowChunks
        self.initialPossession = initialPossession
        self.sessions = sessions
    }
}

/// One session of a worked transfer: the complete emission lists,
/// both directions, in emission order.
public struct BulkTransferSessionVector: Codable, Sendable {
    /// nil = the receiver ingests everything (the session runs out).
    public var receiverIngestLimit: Int?
    public var senderMessagesHex: [String]
    public var receiverMessagesHex: [String]

    public init(
        receiverIngestLimit: Int? = nil,
        senderMessagesHex: [String],
        receiverMessagesHex: [String]
    ) {
        self.receiverIngestLimit = receiverIngestLimit
        self.senderMessagesHex = senderMessagesHex
        self.receiverMessagesHex = receiverMessagesHex
    }
}

/// Stable names for `BulkMessageError` cases, as they appear in
/// vectors.
public func bulkMessageErrorName(_ error: BulkMessageError) -> String {
    switch error {
    case .truncatedMessage: return "truncatedMessage"
    case .unexpectedType: return "unexpectedType"
    case .trailingBytes: return "trailingBytes"
    case .zeroTransferId: return "zeroTransferId"
    case .emptyTransfer: return "emptyTransfer"
    case .chunkSizeOutOfBounds: return "chunkSizeOutOfBounds"
    case .invalidSha256ByteCount: return "invalidSha256ByteCount"
    case .emptyName: return "emptyName"
    case .nameOverBudget: return "nameOverBudget"
    case .mimeHintOverBudget: return "mimeHintOverBudget"
    case .invalidUtf8: return "invalidUtf8"
    case .emptyChunkData: return "emptyChunkData"
    case .chunkDataOverBudget: return "chunkDataOverBudget"
    case .bitmapOverBudget: return "bitmapOverBudget"
    case .nonCanonicalBitmap: return "nonCanonicalBitmap"
    case .unknownAbortReason: return "unknownAbortReason"
    }
}

/// Stable names for `BulkAbortReason` cases.
public func bulkAbortReasonName(_ reason: BulkAbortReason) -> String {
    switch reason {
    case .declined: return "declined"
    case .cancelled: return "cancelled"
    case .resumeMismatch: return "resumeMismatch"
    case .shaMismatch: return "shaMismatch"
    case .storageFailure: return "storageFailure"
    case .busy: return "busy"
    case .protocolViolation: return "protocolViolation"
    }
}

public func bulkAbortReason(named name: String) -> BulkAbortReason? {
    BulkAbortReason.allCases.first { bulkAbortReasonName($0) == name }
}
