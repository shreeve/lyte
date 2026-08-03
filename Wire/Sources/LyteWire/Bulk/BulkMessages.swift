// The bulk-transfer vocabulary (W10 / F-2 — design record
// docs/20260728-053300-lyte-bulk-channel.md): the wire shapes of a
// chunked, resumable, backpressured blob transfer. Six messages, all
// riding CHANNEL 8's ARQ ordered stream (group 0) — never CTRL, so a
// file can never head-of-line-block a keystroke; never FEC'd, because
// bulk is the one traffic class where retransmit RTTs cost nothing
// (design §2's ARQ-vs-fountain ruling).
//
// The vocabulary is DIRECTION-NEUTRAL by design: every message speaks
// sender/receiver, never client/host. v1 gates the direction at the
// ends (client→host only, per H3 §0 owner decision 1), so a v2 flip
// costs zero wire bytes. Offer/chunk flow sender→receiver;
// accept/ack/complete flow receiver→sender; abort flows either way.
// Ordering within each direction is the ARQ stream's guarantee — a
// chunk can never overtake its offer, a complete can never overtake
// the final ack.
//
// CAPABILITY CARRIAGE — the W7 forward-compat spine, third verse:
// key 11 (CapabilityKey.bulkTransfer, bool) rides the declaration
// through `Capabilities.unknownEntries` as one canonical `0B F5` map
// entry and survives intersection only on mutual byte-equal
// declaration. ZERO frozen bytes move. Declaration is dialect, not
// consent: the standing per-host toggle lives in the end shells.
//
// Validation doctrine, the house rule: every message is exactly its
// layout — truncation, trailing bytes, and foreign type bytes reject
// with what they found; a zero transferId is the loud zero-fill bug;
// hostile bytes throw, never trap.

/// The bulk layer's fixed numbers (wire v1). Design record §4 owns
/// the justifications.
public enum BulkWire {
    /// Chunk-size floor: below 4 KiB the bookkeeping (chunk counts,
    /// maps) buys per-chunk overhead with no measurable win.
    public static let minChunkByteCount = 4_096
    /// Chunk-size ceiling: keeps one chunk message inside ARQ's
    /// 262,144 B message budget with 2× headroom and bounds the
    /// receiver's single-chunk staging buffer.
    public static let maxChunkByteCount = 131_072
    /// The sweet spot the ARQ geometry suggests: 60 segments per
    /// chunk, ~1,600 chunks per 100 MB, 0.026% header overhead.
    public static let defaultChunkByteCount = 65_536
    /// Offer name: 1…255 UTF-8 bytes (a nameless offer is
    /// unreviewable by a consent UI; sanitization is the receiving
    /// end's job, not the codec's).
    public static let maxNameByteCount = 255
    /// Offer MIME hint: 0…255 UTF-8 bytes — the hint is optional.
    public static let maxMimeHintByteCount = 255
    /// Chunk-map bitmap ceiling: 8,192 chunks describable past the
    /// first hole. A describability bound, not a size bound —
    /// under-claiming is always legal (design §5).
    public static let maxBitmapByteCount = 1_024
    /// A SHA-256 digest, the completion contract.
    public static let sha256ByteCount = 32
}

/// Transfer-id minting: u64, non-zero (zero is the loud zero-fill
/// bug), from INJECTED randomness per Wire doctrine — the one place
/// randomness enters the bulk layer. Minted once per blob and reused
/// verbatim on every re-offer, which is what makes resume matching
/// possible (design §5).
public enum BulkTransferId {
    public static func mint(
        using generator: inout some RandomNumberGenerator
    ) -> UInt64 {
        var id: UInt64 = generator.next()
        while id == 0 {
            id = generator.next()
        }
        return id
    }
}

// MARK: - The capability spine helpers (key 11)

extension Capabilities {
    /// The key-11 entry as it rides the wire: CBOR bool under
    /// unsigned key 11 (`0B F5` inside the map) — one canonical byte
    /// image is what makes the intersection's byte-equal rule an
    /// exact AND.
    private static var bulkTransferEntry: CborMapEntry {
        CborMapEntry(
            key: .unsigned(CapabilityKey.bulkTransfer),
            value: .bool(true)
        )
    }

    /// True when this set (a declaration or an agreed intersection)
    /// carries `bulkTransfer: true`. On a v1 build the key lives in
    /// `unknownEntries` — which is exactly what makes it survive
    /// intersection only on mutual declaration. A `false` or
    /// wrongly-typed value reads as absent: absence and refusal are
    /// the same posture ("not supported"), per the spine's rule 3.
    public var bulkTransfer: Bool {
        unknownEntries.contains(Self.bulkTransferEntry)
    }

    /// A copy of this set declaring bulk-transfer support.
    /// Idempotent; the CBOR encoder owns canonical key order, so the
    /// entry may append here regardless of surrounding keys.
    public func declaringBulkTransfer() -> Capabilities {
        guard !bulkTransfer else { return self }
        var declared = self
        declared.unknownEntries.append(Self.bulkTransferEntry)
        return declared
    }
}

// MARK: - The chunk map

/// Chunk possession, compressed: chunks `0…contiguousCount−1` are
/// held, and bitmap bit n (byte n/8, bit n%8) set means chunk
/// `contiguousCount + 1 + n` is held — chunk `contiguousCount` itself
/// is NOT held by definition (else the count would advance; the ARQ
/// ACK-block convention). Canonical: the final bitmap byte is
/// non-zero. Shared by accept and ack; with in-order ARQ carriage the
/// bitmap rides empty in practice and exists for holed resume states
/// and future non-ordered carriages (design §5).
public struct BulkChunkMap: Hashable, Sendable {
    public var contiguousCount: UInt64
    public private(set) var bitmap: [UInt8]

    /// A hole-free prefix. Cannot fail.
    public init(contiguousCount: UInt64) {
        self.contiguousCount = contiguousCount
        self.bitmap = []
    }

    /// Refuses over-long and non-canonical bitmaps.
    public init(contiguousCount: UInt64, bitmap: [UInt8]) throws {
        guard bitmap.count <= BulkWire.maxBitmapByteCount else {
            throw BulkMessageError.bitmapOverBudget(bitmap.count)
        }
        if let last = bitmap.last {
            guard last != 0 else {
                throw BulkMessageError.nonCanonicalBitmap
            }
        }
        self.contiguousCount = contiguousCount
        self.bitmap = bitmap
    }

    public static let empty = BulkChunkMap(contiguousCount: 0)

    /// Builds the canonical map for a possession set given as
    /// contiguous prefix + extras, normalizing extras that extend the
    /// prefix and UNDER-CLAIMING whatever the bitmap window cannot
    /// describe (always legal — the sender re-sends some held chunks,
    /// the receiver tolerates them, the digest arbitrates; design
    /// §5). Cannot fail.
    public static func describing(
        contiguousCount: UInt64,
        extras: some Sequence<UInt64>
    ) -> BulkChunkMap {
        var contiguous = contiguousCount
        var pending = Set(extras.filter { $0 >= contiguousCount })
        while pending.contains(contiguous) {
            pending.remove(contiguous)
            contiguous += 1
        }
        var bytes = [UInt8](repeating: 0, count: BulkWire.maxBitmapByteCount)
        var highestBit = -1
        for index in pending {
            // index > contiguous here (== was drained above).
            let offset = index - contiguous - 1
            guard offset < UInt64(BulkWire.maxBitmapByteCount * 8) else {
                continue // under-claim past the window
            }
            let bit = Int(offset)
            bytes[bit / 8] |= 1 << (bit % 8)
            highestBit = max(highestBit, bit)
        }
        let bitmap = highestBit >= 0
            ? Array(bytes[0...(highestBit / 8)]) : []
        // Both inputs were validated by construction; the throwing
        // init cannot actually fail on them.
        return (try? BulkChunkMap(
            contiguousCount: contiguous, bitmap: bitmap
        )) ?? BulkChunkMap(contiguousCount: contiguous)
    }

    public func holds(_ index: UInt64) -> Bool {
        if index < contiguousCount { return true }
        guard index > contiguousCount else { return false }
        let offset = index - contiguousCount - 1
        guard offset < UInt64(bitmap.count * 8) else { return false }
        let bit = Int(offset)
        return bitmap[bit / 8] & (1 << (bit % 8)) != 0
    }

    /// The chunk indices the bitmap marks held, past the prefix.
    public var bitmapChunkIndices: [UInt64] {
        var indices: [UInt64] = []
        for (byteOffset, byte) in bitmap.enumerated() {
            for bit in 0..<8 where byte & (1 << bit) != 0 {
                indices.append(
                    contiguousCount + 1 + UInt64(byteOffset * 8 + bit)
                )
            }
        }
        return indices
    }

    /// Total chunks this map claims held.
    public var heldChunkCount: UInt64 {
        contiguousCount
            + UInt64(bitmap.reduce(0) { $0 + $1.nonzeroBitCount })
    }

    var encodedByteCount: Int {
        8 + 2 + bitmap.count
    }

    func appendEncoding(to out: inout [UInt8]) {
        wireAppendLE(contiguousCount, to: &out)
        wireAppendLE(UInt16(bitmap.count), to: &out)
        out.append(contentsOf: bitmap)
    }
}

// MARK: - The message codecs

/// The sender's transfer offer (type 0x1C) — "I hold this blob; may I
/// send it?" Also the resume probe: re-offering a known transferId
/// with the identical (size, sha256, chunk geometry) resumes from the
/// receiver's persisted possession.
///
///   offset size field
///   0      1    type            0x1C
///   1      8    transferId      u64, non-zero, stable across sessions
///   9      8    totalByteCount  u64 ≥ 1 — NO ceiling by design
///   17     4    chunkByteCount  u32, 4,096…131,072
///   21     32   sha256          whole-blob digest
///   53     1    nameLen         1…255
///   54     …    name            UTF-8
///   …      1    mimeLen         0…255
///   …      …    mimeHint        UTF-8; exactly its layout, trailing
///                               bytes reject
public struct BulkOffer: Hashable, Sendable {
    public var transferId: UInt64
    public var totalByteCount: UInt64
    public var chunkByteCount: UInt32
    public var sha256: [UInt8]
    public var name: String
    public var mimeHint: String

    /// Refuses everything encode would have to refuse, so `encode`
    /// cannot fail — a value that cannot encode is a construction
    /// bug, not wire input.
    public init(
        transferId: UInt64,
        totalByteCount: UInt64,
        chunkByteCount: UInt32 = UInt32(BulkWire.defaultChunkByteCount),
        sha256: [UInt8],
        name: String,
        mimeHint: String = ""
    ) throws {
        guard transferId != 0 else {
            throw BulkMessageError.zeroTransferId
        }
        guard totalByteCount >= 1 else {
            throw BulkMessageError.emptyTransfer
        }
        guard (BulkWire.minChunkByteCount...BulkWire.maxChunkByteCount)
            .contains(Int(chunkByteCount))
        else {
            throw BulkMessageError.chunkSizeOutOfBounds(Int(chunkByteCount))
        }
        guard sha256.count == BulkWire.sha256ByteCount else {
            throw BulkMessageError.invalidSha256ByteCount(sha256.count)
        }
        let nameBytes = name.utf8.count
        guard nameBytes >= 1 else {
            throw BulkMessageError.emptyName
        }
        guard nameBytes <= BulkWire.maxNameByteCount else {
            throw BulkMessageError.nameOverBudget(nameBytes)
        }
        guard mimeHint.utf8.count <= BulkWire.maxMimeHintByteCount else {
            throw BulkMessageError.mimeHintOverBudget(mimeHint.utf8.count)
        }
        self.transferId = transferId
        self.totalByteCount = totalByteCount
        self.chunkByteCount = chunkByteCount
        self.sha256 = sha256
        self.name = name
        self.mimeHint = mimeHint
    }

    /// ceil(total / chunk): every chunk but the last is exactly
    /// chunkByteCount; the last carries the remainder, never empty.
    /// (Overflow-free form — totals near UInt64.max are legal, the
    /// no-ceiling claim is real.)
    public var chunkCount: UInt64 {
        (totalByteCount - 1) / UInt64(chunkByteCount) + 1
    }

    /// The exact byte count of one chunk; nil past the end.
    public func byteCount(ofChunk index: UInt64) -> Int? {
        guard index < chunkCount else { return nil }
        if index == chunkCount - 1 {
            let remainder = totalByteCount % UInt64(chunkByteCount)
            return remainder == 0 ? Int(chunkByteCount) : Int(remainder)
        }
        return Int(chunkByteCount)
    }

    public func encode() -> [UInt8] {
        var out = [UInt8]()
        let nameBytes = Array(name.utf8)
        let mimeBytes = Array(mimeHint.utf8)
        out.reserveCapacity(55 + nameBytes.count + mimeBytes.count)
        out.append(CtrlMessageType.bulkOffer)
        wireAppendLE(transferId, to: &out)
        wireAppendLE(totalByteCount, to: &out)
        wireAppendLE(chunkByteCount, to: &out)
        out.append(contentsOf: sha256)
        out.append(UInt8(nameBytes.count))
        out.append(contentsOf: nameBytes)
        out.append(UInt8(mimeBytes.count))
        out.append(contentsOf: mimeBytes)
        return out
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> BulkOffer {
        let base = try checkType(payload, type: CtrlMessageType.bulkOffer)
        guard payload.endIndex - base >= 53 else {
            throw BulkMessageError.truncatedMessage
        }
        let transferId: UInt64 = wireReadLE(payload, at: base)
        let totalByteCount: UInt64 = wireReadLE(payload, at: base + 8)
        let chunkByteCount: UInt32 = wireReadLE(payload, at: base + 16)
        let sha256 = Array(payload[(base + 20)..<(base + 52)])
        let nameLen = Int(payload[base + 52])
        var cursor = base + 53
        guard cursor + nameLen <= payload.endIndex else {
            throw BulkMessageError.truncatedMessage
        }
        let name = try decodeUtf8(payload[cursor..<cursor + nameLen])
        cursor += nameLen
        guard cursor < payload.endIndex else {
            throw BulkMessageError.truncatedMessage
        }
        let mimeLen = Int(payload[cursor])
        cursor += 1
        guard cursor + mimeLen <= payload.endIndex else {
            throw BulkMessageError.truncatedMessage
        }
        let mimeHint = try decodeUtf8(payload[cursor..<cursor + mimeLen])
        cursor += mimeLen
        guard cursor == payload.endIndex else {
            throw BulkMessageError.trailingBytes
        }
        return try BulkOffer(
            transferId: transferId,
            totalByteCount: totalByteCount,
            chunkByteCount: chunkByteCount,
            sha256: sha256,
            name: name,
            mimeHint: mimeHint
        )
    }

    public static func decode(_ payload: [UInt8]) throws -> BulkOffer {
        try decode(payload[...])
    }
}

/// The receiver's consent answer (type 0x1D): existing possession
/// (empty for a fresh transfer, the persisted map for a resume) plus
/// the opening credit. The accept IS the first ack plus consent.
///
///   offset size field
///   0      1    type             0x1D
///   1      8    transferId
///   9      8    creditTotal      chunks the sender may dispatch this
///                                session; 0 is legal (accept-but-hold)
///   17     8    contiguousCount  the chunk map
///   25     2    bitmapLen        0…1,024
///   27     …    bitmap
public struct BulkAccept: Hashable, Sendable {
    public var transferId: UInt64
    public var creditTotal: UInt64
    public var possession: BulkChunkMap

    public init(
        transferId: UInt64,
        creditTotal: UInt64,
        possession: BulkChunkMap = .empty
    ) throws {
        guard transferId != 0 else {
            throw BulkMessageError.zeroTransferId
        }
        self.transferId = transferId
        self.creditTotal = creditTotal
        self.possession = possession
    }

    public func encode() -> [UInt8] {
        encodeCreditAndMap(
            type: CtrlMessageType.bulkAccept,
            transferId: transferId,
            creditTotal: creditTotal,
            map: possession
        )
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> BulkAccept {
        let (id, credit, map) = try decodeCreditAndMap(
            payload, type: CtrlMessageType.bulkAccept
        )
        return try BulkAccept(
            transferId: id, creditTotal: credit, possession: map
        )
    }

    public static func decode(_ payload: [UInt8]) throws -> BulkAccept {
        try decode(payload[...])
    }
}

/// One chunk (type 0x1E), data the sole trailing field (the
/// RetryHandshake1 self-delimiting precedent — the ARQ message
/// boundary is the length). EXACT size against the offer's geometry
/// is the engine's check; the codec pins the structural bounds.
///
///   offset size field
///   0      1    type        0x1E
///   1      8    transferId
///   9      8    chunkIndex  u64
///   17     …    data        1…131,072 bytes
public struct BulkChunk: Hashable, Sendable {
    public var transferId: UInt64
    public var chunkIndex: UInt64
    public var data: [UInt8]

    public init(
        transferId: UInt64, chunkIndex: UInt64, data: [UInt8]
    ) throws {
        guard transferId != 0 else {
            throw BulkMessageError.zeroTransferId
        }
        guard !data.isEmpty else {
            throw BulkMessageError.emptyChunkData
        }
        guard data.count <= BulkWire.maxChunkByteCount else {
            throw BulkMessageError.chunkDataOverBudget(data.count)
        }
        self.transferId = transferId
        self.chunkIndex = chunkIndex
        self.data = data
    }

    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(17 + data.count)
        out.append(CtrlMessageType.bulkChunk)
        wireAppendLE(transferId, to: &out)
        wireAppendLE(chunkIndex, to: &out)
        out.append(contentsOf: data)
        return out
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> BulkChunk {
        let base = try checkType(payload, type: CtrlMessageType.bulkChunk)
        guard payload.endIndex - base >= 16 else {
            throw BulkMessageError.truncatedMessage
        }
        let transferId: UInt64 = wireReadLE(payload, at: base)
        let chunkIndex: UInt64 = wireReadLE(payload, at: base + 8)
        let data = Array(payload[(base + 16)...])
        return try BulkChunk(
            transferId: transferId, chunkIndex: chunkIndex, data: data
        )
    }

    public static func decode(_ payload: [UInt8]) throws -> BulkChunk {
        try decode(payload[...])
    }
}

/// The receiver's possession + credit heartbeat (type 0x1F). Layout
/// identical to accept. `creditTotal` is monotonic within a session;
/// a stale (lower) value is ignored by the sender, never a violation
/// — acks are cumulative state, not deltas.
public struct BulkAck: Hashable, Sendable {
    public var transferId: UInt64
    public var creditTotal: UInt64
    public var possession: BulkChunkMap

    public init(
        transferId: UInt64,
        creditTotal: UInt64,
        possession: BulkChunkMap
    ) throws {
        guard transferId != 0 else {
            throw BulkMessageError.zeroTransferId
        }
        self.transferId = transferId
        self.creditTotal = creditTotal
        self.possession = possession
    }

    public func encode() -> [UInt8] {
        encodeCreditAndMap(
            type: CtrlMessageType.bulkAck,
            transferId: transferId,
            creditTotal: creditTotal,
            map: possession
        )
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> BulkAck {
        let (id, credit, map) = try decodeCreditAndMap(
            payload, type: CtrlMessageType.bulkAck
        )
        return try BulkAck(
            transferId: id, creditTotal: credit, possession: map
        )
    }

    public static func decode(_ payload: [UInt8]) throws -> BulkAck {
        try decode(payload[...])
    }
}

/// The success verdict (type 0x20), sent only after the receiver's
/// own digest of the assembled blob equals the offer's sha256.
/// Exactly `type ‖ transferId` — failure is never a
/// complete-with-status; it is an abort with a reason (one message,
/// one meaning; the lifecycle discipline).
public struct BulkComplete: Hashable, Sendable {
    public var transferId: UInt64

    public init(transferId: UInt64) throws {
        guard transferId != 0 else {
            throw BulkMessageError.zeroTransferId
        }
        self.transferId = transferId
    }

    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(9)
        out.append(CtrlMessageType.bulkComplete)
        wireAppendLE(transferId, to: &out)
        return out
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> BulkComplete {
        let base = try checkType(
            payload, type: CtrlMessageType.bulkComplete
        )
        guard payload.endIndex - base >= 8 else {
            throw BulkMessageError.truncatedMessage
        }
        guard payload.endIndex - base == 8 else {
            throw BulkMessageError.trailingBytes
        }
        return try BulkComplete(
            transferId: wireReadLE(payload, at: base)
        )
    }

    public static func decode(_ payload: [UInt8]) throws -> BulkComplete {
        try decode(payload[...])
    }
}

/// Why a transfer died. The whole value space is pinned by
/// bulk-v1.json (the lifecycle discipline — a value added without a
/// vector-file discussion fails loudly). 0x00 rejects (the zero-fill
/// rule); unknown values reject.
public enum BulkAbortReason: UInt8, CaseIterable, Hashable, Sendable {
    /// Receiver consent says no (standing toggle off, user refused).
    case declined = 0x01
    /// A human cancelled — either end, any time.
    case cancelled = 0x02
    /// An offer reused a known transferId with a different
    /// size/sha/geometry: the file changed under the id. The sender's
    /// recovery is a fresh id, never a silent re-baseline.
    case resumeMismatch = 0x03
    /// The assembled blob's digest ≠ the offer's — the transfer
    /// failed at the finish line.
    case shaMismatch = 0x04
    /// The receiver's disk said no (full, write error).
    case storageFailure = 0x05
    /// A transfer is already active — v1 runs one at a time per
    /// direction; the ends queue, the wire refuses.
    case busy = 0x06
    /// The peer broke the state machine (out-of-range chunk, credit
    /// overrun, wrong-size chunk…).
    case protocolViolation = 0x07
}

/// Typed transfer abort (type 0x21), either direction. Exactly
/// `type ‖ transferId ‖ reason`.
public struct BulkAbort: Hashable, Sendable {
    public var transferId: UInt64
    public var reason: BulkAbortReason

    public init(transferId: UInt64, reason: BulkAbortReason) throws {
        guard transferId != 0 else {
            throw BulkMessageError.zeroTransferId
        }
        self.transferId = transferId
        self.reason = reason
    }

    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(10)
        out.append(CtrlMessageType.bulkAbort)
        wireAppendLE(transferId, to: &out)
        out.append(reason.rawValue)
        return out
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> BulkAbort {
        let base = try checkType(payload, type: CtrlMessageType.bulkAbort)
        guard payload.endIndex - base >= 9 else {
            throw BulkMessageError.truncatedMessage
        }
        guard payload.endIndex - base == 9 else {
            throw BulkMessageError.trailingBytes
        }
        let raw = payload[base + 8]
        guard let reason = BulkAbortReason(rawValue: raw) else {
            throw BulkMessageError.unknownAbortReason(raw)
        }
        return try BulkAbort(
            transferId: wireReadLE(payload, at: base), reason: reason
        )
    }

    public static func decode(_ payload: [UInt8]) throws -> BulkAbort {
        try decode(payload[...])
    }
}

/// One parsed bulk message — the dispatch the engines and the chan-8
/// shell share. `decode` routes on the type byte and rejects
/// everything outside the sextet.
public enum BulkMessage: Hashable, Sendable {
    case offer(BulkOffer)
    case accept(BulkAccept)
    case chunk(BulkChunk)
    case ack(BulkAck)
    case complete(BulkComplete)
    case abort(BulkAbort)

    public func encode() -> [UInt8] {
        switch self {
        case .offer(let m): return m.encode()
        case .accept(let m): return m.encode()
        case .chunk(let m): return m.encode()
        case .ack(let m): return m.encode()
        case .complete(let m): return m.encode()
        case .abort(let m): return m.encode()
        }
    }

    public var transferId: UInt64 {
        switch self {
        case .offer(let m): return m.transferId
        case .accept(let m): return m.transferId
        case .chunk(let m): return m.transferId
        case .ack(let m): return m.transferId
        case .complete(let m): return m.transferId
        case .abort(let m): return m.transferId
        }
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> BulkMessage {
        guard let type = payload.first else {
            throw BulkMessageError.truncatedMessage
        }
        switch type {
        case CtrlMessageType.bulkOffer:
            return .offer(try BulkOffer.decode(payload))
        case CtrlMessageType.bulkAccept:
            return .accept(try BulkAccept.decode(payload))
        case CtrlMessageType.bulkChunk:
            return .chunk(try BulkChunk.decode(payload))
        case CtrlMessageType.bulkAck:
            return .ack(try BulkAck.decode(payload))
        case CtrlMessageType.bulkComplete:
            return .complete(try BulkComplete.decode(payload))
        case CtrlMessageType.bulkAbort:
            return .abort(try BulkAbort.decode(payload))
        default:
            throw BulkMessageError.unexpectedType(type)
        }
    }

    public static func decode(_ payload: [UInt8]) throws -> BulkMessage {
        try decode(payload[...])
    }
}

/// Everything the bulk codecs can refuse. Hostile bytes throw, never
/// trap.
public enum BulkMessageError: Error, Hashable, Sendable {
    /// A header or field runs past the payload's end (or the payload
    /// is empty — no type byte to dispatch on).
    case truncatedMessage
    /// A type byte that is not the expected message (or, for
    /// `BulkMessage.decode`, outside the 0x1C–0x21 sextet).
    case unexpectedType(UInt8)
    /// Bytes past the message's exact layout.
    case trailingBytes
    /// transferId 0 — always some layer's zero-fill bug.
    case zeroTransferId
    /// totalByteCount 0 — v1 does not transfer empty blobs.
    case emptyTransfer
    /// chunkByteCount outside [4,096, 131,072].
    case chunkSizeOutOfBounds(Int)
    /// A digest field that is not exactly 32 bytes (construction-side;
    /// the wire layout fixes the width).
    case invalidSha256ByteCount(Int)
    /// nameLen 0 — a nameless offer is unreviewable.
    case emptyName
    /// A name over 255 UTF-8 bytes (construction-side; the u8 length
    /// fixes the wire bound).
    case nameOverBudget(Int)
    /// A MIME hint over 255 UTF-8 bytes (construction-side).
    case mimeHintOverBudget(Int)
    /// Name or MIME bytes that are not valid UTF-8 (detected by
    /// byte-exact re-encode, the CBOR text rule).
    case invalidUtf8
    /// A chunk with no data — some layer's fill bug, kept loud.
    case emptyChunkData
    /// Chunk data over the 131,072 B ceiling.
    case chunkDataOverBudget(Int)
    /// A chunk-map bitmap over the 1,024 B ceiling.
    case bitmapOverBudget(Int)
    /// A bitmap whose final byte is zero: the bitmap is sized by its
    /// highest set bit, so a zero tail means the sender miscounted.
    case nonCanonicalBitmap
    /// An abort reason outside the pinned space (0x00 included — the
    /// zero-fill rule).
    case unknownAbortReason(UInt8)
}

// MARK: - Shared layout helpers

/// Checks the type byte and returns the index of the first body byte.
private func checkType(
    _ payload: ArraySlice<UInt8>, type: UInt8
) throws -> Int {
    guard let first = payload.first else {
        throw BulkMessageError.truncatedMessage
    }
    guard first == type else {
        throw BulkMessageError.unexpectedType(first)
    }
    return payload.startIndex + 1
}

private func decodeUtf8(_ bytes: ArraySlice<UInt8>) throws -> String {
    let text = String(decoding: bytes, as: UTF8.self)
    guard text.utf8.count == bytes.count,
          text.utf8.elementsEqual(bytes) else {
        throw BulkMessageError.invalidUtf8
    }
    return text
}

/// Accept and ack share the `type ‖ id ‖ credit ‖ map` layout.
private func encodeCreditAndMap(
    type: UInt8, transferId: UInt64, creditTotal: UInt64,
    map: BulkChunkMap
) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(17 + map.encodedByteCount)
    out.append(type)
    wireAppendLE(transferId, to: &out)
    wireAppendLE(creditTotal, to: &out)
    map.appendEncoding(to: &out)
    return out
}

private func decodeCreditAndMap(
    _ payload: ArraySlice<UInt8>, type: UInt8
) throws -> (UInt64, UInt64, BulkChunkMap) {
    let base = try checkType(payload, type: type)
    guard payload.endIndex - base >= 26 else {
        throw BulkMessageError.truncatedMessage
    }
    let transferId: UInt64 = wireReadLE(payload, at: base)
    let creditTotal: UInt64 = wireReadLE(payload, at: base + 8)
    let contiguousCount: UInt64 = wireReadLE(payload, at: base + 16)
    let bitmapLen = Int(wireReadLE(payload, at: base + 24) as UInt16)
    guard bitmapLen <= BulkWire.maxBitmapByteCount else {
        throw BulkMessageError.bitmapOverBudget(bitmapLen)
    }
    let bitmapStart = base + 26
    guard bitmapStart + bitmapLen <= payload.endIndex else {
        throw BulkMessageError.truncatedMessage
    }
    guard bitmapStart + bitmapLen == payload.endIndex else {
        throw BulkMessageError.trailingBytes
    }
    let map = try BulkChunkMap(
        contiguousCount: contiguousCount,
        bitmap: Array(payload[bitmapStart..<bitmapStart + bitmapLen])
    )
    return (transferId, creditTotal, map)
}
