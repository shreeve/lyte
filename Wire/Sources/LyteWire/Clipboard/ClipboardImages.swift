// Clipboard image sync: image blobs ride as BULK-CHANNEL CARGO through
// the bulk engines, marked so file drops and clipboard images never
// confuse each other.
//
// ClipboardImageCargo (0x22), direction-neutral, rides chan 8's ARQ
// ordered stream immediately BEFORE its transfer's BulkOffer, so routing
// is race-free by carriage, not timing. The marker carries the MIME: only
// image/png is accepted; a foreign mime draws abort(declined), and a
// future format is a new mime string with no new wire bytes.
//
// Gated by keys 10 AND 12 (see CapabilityKey.clipboardImages); key 11
// (file-drop consent) is deliberately not part of the gate.
//
// One transfer at a time per direction PER LANE (file lane, clipboard
// lane); a second cargo while the clipboard lane is busy draws
// abort(busy). Receiver memory is bounded: the file lane by its
// disk-backed window, the clipboard lane by the 32 MiB ceiling.
//
// Sans-IO: no clocks, digests and hashers are injected, randomness only
// at id mint, and the blob lives in memory (no disk, no resume; a torn
// session drops the image and a re-copy re-syncs). A local copy is hashed
// only after the digest-free gates (empty → lane busy → ceiling) pass,
// and an incoming image feeds an incremental hasher chunk by chunk, so no
// single step hashes a whole 32 MiB blob.

import LyteCore

/// An incremental digest the embedding end supplies for incoming
/// images — SHA-256, whose digest the offer carries.
public protocol ClipboardImageHasher: Sendable {
    /// Feeds the next bytes of the blob, in blob order.
    mutating func absorb(_ bytes: ArraySlice<UInt8>)
    /// The digest of everything absorbed. Called once.
    mutating func finish() -> [UInt8]
}

extension Sha256: ClipboardImageHasher {
    public mutating func absorb(_ bytes: ArraySlice<UInt8>) {
        update(bytes)
    }

    public mutating func finish() -> [UInt8] {
        finalized()
    }
}

/// The clipboard-image layer's fixed numbers.
public enum ClipboardImageWire {
    /// The one cargo format. Lowercase canonical; comparison is
    /// case-insensitive (mime types compare that way).
    public static let pngMime = "image/png"
    /// Every mime this build can carry, lowercase. Formats append here
    /// (and at the leaves) with zero wire change.
    public static let acceptedMimes = [pngMime]
    /// The image ceiling: 32 MiB, the clipboard lane's receiver-memory
    /// bound (the blob assembles in memory). Over-ceiling LOCAL copies
    /// are suppressed and counted, never sent; over-ceiling OFFERS draw
    /// abort(declined).
    public static let maxImageByteCount = 33_554_432
    /// Chunk geometry for clipboard cargo: the bulk default (64 KiB).
    public static let chunkByteCount = UInt32(BulkWire.defaultChunkByteCount)
    /// The offer's name field for clipboard cargo — cosmetic (the
    /// cargo never lands in a drop directory), pinned for the vectors.
    public static let wireName = "clipboard.png"

    /// The sync-book key for an image: `0xFF ‖ sha256`. 0xFF is never
    /// valid UTF-8, so image keys cannot collide with text keys — one
    /// book serves both kinds (Clipboard.swift's byte-key APIs).
    public static func bookKey(sha256: [UInt8]) -> [UInt8] {
        [0xFF] + sha256
    }

    /// Case-insensitive membership in `acceptedMimes`.
    public static func accepts(mime: String) -> Bool {
        acceptedMimes.contains(mime.lowercased())
    }
}

// MARK: - The capability spine helpers (key 12)

extension Capabilities {
    /// True when this set carries `clipboardImages: true` (key 12) — see
    /// `declaresFlag(_:)`.
    public var clipboardImages: Bool {
        declaresFlag(CapabilityKey.clipboardImages)
    }

    /// A copy of this set declaring `clipboardImages`.
    public func declaringClipboardImages() -> Capabilities {
        declaringFlag(CapabilityKey.clipboardImages)
    }

    /// The full image gate: keys 10 ∧ 12 both survived intersection.
    /// Key 11 (file-drop consent) is deliberately absent; an end with
    /// this gate true runs chan-8 bulk machinery for clipboard cargo
    /// regardless of key 11.
    public var clipboardImagesAgreed: Bool {
        clipboardText && clipboardImages
    }
}

// MARK: - The cargo-marker codec (0x22)

/// The clipboard-cargo marker (type 0x22), either direction: "the
/// transfer bearing this id is clipboard cargo of this MIME". Emitted
/// on chan 8's ordered stream immediately before its BulkOffer.
///
///   offset size field
///   0      1    type        0x22
///   1      8    transferId  u64, non-zero (the offer that follows
///                           reuses it verbatim)
///   9      1    mimeLen     1…255
///   10     …    mime        UTF-8; exactly its layout, trailing
///                           bytes reject
public struct ClipboardImageCargo: Hashable, Sendable, SliceDecodable {
    public var transferId: UInt64
    public var mime: String

    /// Refuses everything encode would have to refuse, so `encode`
    /// cannot fail — a value that cannot encode is a construction
    /// bug, not wire input.
    public init(transferId: UInt64, mime: String) throws {
        guard transferId != 0 else {
            throw ClipboardImageCargoError.zeroTransferId
        }
        let mimeBytes = mime.utf8.count
        guard mimeBytes >= 1 else {
            throw ClipboardImageCargoError.emptyMime
        }
        guard mimeBytes <= BulkWire.maxMimeHintByteCount else {
            throw ClipboardImageCargoError.mimeOverBudget(mimeBytes)
        }
        self.transferId = transferId
        self.mime = mime
    }

    public func encode() -> [UInt8] {
        var out = [UInt8]()
        let mimeBytes = Array(mime.utf8)
        out.reserveCapacity(10 + mimeBytes.count)
        out.append(CtrlMessageType.clipboardImageCargo)
        wireAppendLE(transferId, to: &out)
        out.append(UInt8(mimeBytes.count))
        out.append(contentsOf: mimeBytes)
        return out
    }

    public static func decode(
        _ payload: ArraySlice<UInt8>
    ) throws -> ClipboardImageCargo {
        guard let first = payload.first else {
            throw ClipboardImageCargoError.truncatedMessage
        }
        guard first == CtrlMessageType.clipboardImageCargo else {
            throw ClipboardImageCargoError.unexpectedType(first)
        }
        let base = payload.startIndex + 1
        guard payload.endIndex - base >= 9 else {
            throw ClipboardImageCargoError.truncatedMessage
        }
        let transferId: UInt64 = wireReadLE(payload, at: base)
        let mimeLen = Int(payload[base + 8])
        let mimeStart = base + 9
        guard mimeStart + mimeLen <= payload.endIndex else {
            throw ClipboardImageCargoError.truncatedMessage
        }
        guard mimeStart + mimeLen == payload.endIndex else {
            throw ClipboardImageCargoError.trailingBytes
        }
        let mimeSlice = payload[mimeStart..<mimeStart + mimeLen]
        guard let mime = String(validating: mimeSlice, as: UTF8.self) else {
            throw ClipboardImageCargoError.invalidUtf8
        }
        return try ClipboardImageCargo(transferId: transferId, mime: mime)
    }
}

/// Everything the cargo-marker codec can refuse. Hostile bytes throw,
/// never trap.
public enum ClipboardImageCargoError: Error, Hashable, Sendable {
    case truncatedMessage
    case unexpectedType(UInt8)
    case trailingBytes
    /// transferId 0 — always some layer's zero-fill bug.
    case zeroTransferId
    /// A mime-less marker is unroutable.
    case emptyMime
    /// A mime over 255 UTF-8 bytes (construction-side; the u8 length
    /// fixes the wire bound).
    case mimeOverBudget(Int)
    /// Mime bytes that are not valid UTF-8.
    case invalidUtf8
}

// MARK: - The channel (both ends embed one)

/// Why a local image copy did not become cargo (counted, never an
/// error).
public enum ClipboardImageSuppressReason: Hashable, Sendable {
    /// The OS reporting our own remote apply back — the sync book's
    /// boomerang stop.
    case loopEcho
    /// Identical to the last image we shared — the peer holds it.
    case duplicate
    /// Past the 32 MiB ceiling (byte count attached).
    case overBudget(Int)
    /// A zero-byte read — some leaf's bug, kept loud in the counter.
    case emptyImage
    /// The clipboard send lane already carries a transfer; clipboards
    /// sync latest-wins, so the superseded copy just drops.
    case sendBusy
}

/// Why incoming cargo was refused (the abort already rode out in the
/// same event batch).
public enum ClipboardImageRefuseReason: Hashable, Sendable {
    /// A mime this build cannot carry — abort(declined).
    case unsupportedMime(String)
    /// The offer's byte count is past the ceiling —
    /// abort(declined). Enforced against the OFFER, never trusted.
    case overBudget(UInt64)
    /// The clipboard receive lane already carries a transfer —
    /// abort(busy).
    case receiveBusy
    /// The caller's consent tier said no (`declineCargo`) —
    /// abort(declined).
    case consentDeclined
}

/// Everything the channel surfaces to its embedding session core.
/// `.send` is the one that moves bytes — chan 8's ordered stream;
/// the rest is evidence. Payload bytes appear ONLY in `.applyImage`,
/// never in logs.
public enum ClipboardImageEvent: Hashable, Sendable {
    /// Put these bytes on chan 8's ARQ ordered stream.
    case send([UInt8])
    /// A local copy left as cargo: marker + offer are in flight.
    case shareStarted(transferId: UInt64, byteCount: Int)
    /// The peer verified the digest — the image landed, sha-exact.
    case shareCompleted(transferId: UInt64, byteCount: Int)
    /// The share died; `byRemote` says whose abort it was (a remote
    /// declined/busy is routine weather — best-effort latest-wins).
    case shareAborted(reason: BulkAbortReason, byRemote: Bool)
    /// An admitted incoming transfer died before landing (remote
    /// cancel, sha mismatch…) — nothing was applied.
    case receiveAborted(reason: BulkAbortReason, byRemote: Bool)
    /// A local copy was judged and NOT shared.
    case suppressed(ClipboardImageSuppressReason)
    /// Incoming cargo was refused; the abort rode out in this batch.
    case refused(ClipboardImageRefuseReason)
    /// The finish line: a sha-verified image to apply to the OS
    /// clipboard. The book is already armed against the apply's echo.
    case applyImage(data: [UInt8], mime: String)
    /// The peer broke the bulk state machine (precedes its abort).
    case violated(BulkTransferViolation)
}

public struct ClipboardImageChannelCounters: Hashable, Sendable {
    public var sharesStarted = 0
    public var sharesCompleted = 0
    public var sharesAborted = 0
    public var sharesSuppressed = 0
    public var imagesApplied = 0
    public var receivesRefused = 0
    public var receivesAborted = 0

    public init() {}
}

/// The clipboard-image lane, sans-IO — one per session core, both
/// ends, driving the bulk engines with memory-backed cargo. The
/// embedding core owes it: the negotiation gate (keys 10 ∧ 12)
/// and the consent tier BEFORE calling in, hashing via the injected
/// closures, and the OS clipboard IO on `.applyImage`. The channel
/// owns: the marker handshake, the ceiling, mime policy, lane
/// occupancy, and the sync-book interplay (via the caller's book,
/// which serves text and images alike).
public struct ClipboardImageChannel: Sendable {
    public private(set) var counters = ClipboardImageChannelCounters()

    /// Test seam: the ceiling is a parameter so gates can exercise it
    /// without 32 MiB fixtures. Production uses the wire constant.
    public let imageByteCeiling: Int

    // Send lane.
    private var sendEngine: BulkSendEngine?
    private var sendBlob: [UInt8] = []
    private var sendBookKey: [UInt8] = []

    // Receive lane.
    private var pendingIntent: (transferId: UInt64, mime: String)?
    private var receiveEngine: BulkReceiveEngine?
    private var receiveMime = ""
    private var receiveBuffer: [UInt8] = []
    /// The incoming image's hasher and the chunks it has not absorbed
    /// yet because an earlier one is still missing; `absorbedChunks`
    /// counts the contiguous prefix already fed. Nil outside a transfer.
    private var receiveHasher: (any ClipboardImageHasher)?
    private var absorbedChunks: UInt64 = 0
    private var storedAhead: Set<UInt64> = []
    /// Ids whose cargo was refused — the following offer (already in
    /// flight on the ordered stream when the abort left) is claimed
    /// and swallowed rather than leaking to the file lane.
    private var refusedIds: Set<UInt64> = []

    public init(
        imageByteCeiling: Int = ClipboardImageWire.maxImageByteCount
    ) {
        self.imageByteCeiling = imageByteCeiling
    }

    /// True while the send lane carries a transfer.
    public var isSendActive: Bool {
        sendEngine.map { !$0.isTerminal } ?? false
    }

    /// True while the receive lane carries a transfer (a pending
    /// marker counts — its offer is already in flight).
    public var isReceiveActive: Bool {
        if pendingIntent != nil { return true }
        guard let engine = receiveEngine else { return false }
        return !engine.isTerminal
    }

    // MARK: The send lane

    /// The digest-free gates for a local copy, in order: empty → lane
    /// busy → ceiling. Returns the counted suppression when one refuses,
    /// or nil when only the digest-keyed sync book remains — so a shell
    /// can refuse an image without hashing it, and hash outside its lock.
    public mutating func refuseLocalImageBeforeDigest(
        byteCount: Int
    ) -> [ClipboardImageEvent]? {
        let reason: ClipboardImageSuppressReason
        if byteCount == 0 {
            reason = .emptyImage
        } else if isSendActive {
            reason = .sendBusy
        } else if byteCount > imageByteCeiling {
            reason = .overBudget(byteCount)
        } else {
            return nil
        }
        counters.sharesSuppressed += 1
        return [.suppressed(reason)]
    }

    /// One local image copy, already past the caller's negotiation
    /// and consent-tier gates. Gate order: empty → lane busy → ceiling,
    /// then `sha256` (the caller's digest of `data`, computed only when
    /// those gates pass), then the sync book.
    public mutating func shareLocalImage(
        _ data: [UInt8],
        sha256: () -> [UInt8],
        book: inout ClipboardSyncBook,
        rng: inout some RandomNumberGenerator
    ) -> [ClipboardImageEvent] {
        if let refused = refuseLocalImageBeforeDigest(byteCount: data.count) {
            return refused
        }
        let sha256 = sha256()
        // The in-flight share owns `sendBookKey` until it finishes; a
        // copy refused below must not overwrite it.
        let bookKey = ClipboardImageWire.bookKey(sha256: sha256)
        switch book.admitLocalChange(bytes: bookKey) {
        case .suppressEcho:
            counters.sharesSuppressed += 1
            return [.suppressed(.loopEcho)]
        case .suppressDuplicate:
            counters.sharesSuppressed += 1
            return [.suppressed(.duplicate)]
        case .share:
            break
        }
        let transferId = BulkTransferId.mint(using: &rng)
        guard
            let cargo = try? ClipboardImageCargo(
                transferId: transferId, mime: ClipboardImageWire.pngMime
            ),
            let offer = try? BulkOffer(
                transferId: transferId,
                totalByteCount: UInt64(data.count),
                chunkByteCount: ClipboardImageWire.chunkByteCount,
                sha256: sha256,
                name: ClipboardImageWire.wireName,
                mimeHint: ClipboardImageWire.pngMime
            )
        else {
            // Non-zero id, 1…ceiling bytes, 32-byte digest — the
            // inits cannot actually refuse; kept loud for tests.
            counters.sharesSuppressed += 1
            return [.suppressed(.emptyImage)]
        }
        sendBlob = data
        sendBookKey = bookKey
        var engine = BulkSendEngine(offer: offer)
        // begin() throws only on a re-begin; this engine is fresh.
        let beginActions = (try? engine.begin()) ?? []
        sendEngine = engine
        counters.sharesStarted += 1
        var events: [ClipboardImageEvent] = [
            // The marker FIRST, the offer behind it — same ordered
            // stream, so the receiver can never see them reversed.
            .send(cargo.encode()),
            .shareStarted(transferId: transferId, byteCount: data.count),
        ]
        events += pumpSend(beginActions, book: &book)
        return events
    }

    // MARK: The receive lane

    /// One decoded 0x22 marker, already past the caller's negotiation
    /// and consent-tier gates (a tier that excludes images answers
    /// abort(declined) at the CALLER — consent is the end's, mime and
    /// lane policy are the channel's).
    public mutating func ingestCargo(
        _ cargo: ClipboardImageCargo
    ) -> [ClipboardImageEvent] {
        guard ClipboardImageWire.accepts(mime: cargo.mime) else {
            counters.receivesRefused += 1
            return refusal(
                .unsupportedMime(cargo.mime),
                transferId: cargo.transferId, reason: .declined
            )
        }
        guard !isReceiveActive else {
            counters.receivesRefused += 1
            return refusal(
                .receiveBusy,
                transferId: cargo.transferId, reason: .busy
            )
        }
        pendingIntent = (cargo.transferId, cargo.mime)
        return []
    }

    /// The caller's tier says no images: the typed refusal for a
    /// marker that will never be admitted (the following offer is
    /// swallowed too). Counted at the caller's discretion via the
    /// returned event.
    public mutating func declineCargo(
        _ cargo: ClipboardImageCargo
    ) -> [ClipboardImageEvent] {
        counters.receivesRefused += 1
        return refusal(
            .consentDeclined,
            transferId: cargo.transferId, reason: .declined
        )
    }

    /// True when a decoded bulk message belongs to the clipboard lane
    /// (either half) — the routing question. Unclaimed messages are
    /// the file lane's.
    public func claims(_ message: BulkMessage) -> Bool {
        let id = message.transferId
        if let intent = pendingIntent, intent.transferId == id {
            return true
        }
        if refusedIds.contains(id) { return true }
        if let engine = receiveEngine, engine.offer?.transferId == id {
            return true
        }
        if let engine = sendEngine, engine.offer.transferId == id {
            return true
        }
        return false
    }

    /// One claimed bulk message into whichever lane owns it. An admitted
    /// incoming image feeds a hasher from `makeHasher` chunk by chunk as
    /// its prefix assembles, so verification never hashes the whole blob
    /// in one step.
    public mutating func ingest(
        _ message: BulkMessage,
        book: inout ClipboardSyncBook,
        hasher makeHasher: () -> any ClipboardImageHasher
    ) -> [ClipboardImageEvent] {
        let id = message.transferId
        if let engine = sendEngine, engine.offer.transferId == id {
            let actions = sendEngine!.ingest(message)
            return pumpSend(actions, book: &book)
        }
        if let intent = pendingIntent, intent.transferId == id {
            guard case .offer(let offer) = message else {
                // Ordered carriage makes anything between marker and
                // offer a peer bug — the typed violation answer.
                pendingIntent = nil
                rememberRefused(id)
                var events: [ClipboardImageEvent] = [
                    .violated(.unexpectedMessage(
                        type: message.encode().first ?? 0
                    )),
                ]
                if let abort = try? BulkAbort(
                    transferId: id, reason: .protocolViolation
                ) {
                    events.append(
                        .send(BulkMessage.abort(abort).encode())
                    )
                }
                return events
            }
            return admitOffer(offer, mime: intent.mime,
                              makeHasher: makeHasher, book: &book)
        }
        if receiveEngine?.offer?.transferId == id {
            let actions = receiveEngine!.ingest(message)
            return pumpReceive(actions, makeHasher: makeHasher, book: &book)
        }
        // A refused id's trailing messages (the offer racing our
        // abort) — swallowed, the lane already spoke. The offer is
        // the last thing a refused id can trail (chunks only flow
        // after an accept a refused transfer never got), so seeing
        // it retires the id.
        if refusedIds.contains(id) {
            if case .offer = message {
                refusedIds.remove(id)
            }
            return []
        }
        return []
    }

    // MARK: Send-lane interior

    private mutating func pumpSend(
        _ actions: [BulkSendEngine.Action],
        book: inout ClipboardSyncBook
    ) -> [ClipboardImageEvent] {
        var events: [ClipboardImageEvent] = []
        var queue = actions
        while !queue.isEmpty {
            let action = queue.removeFirst()
            switch action {
            case .emit(let message):
                events.append(.send(message.encode()))
            case .readChunk(let index):
                // The blob is right here — answer synchronously.
                guard let engine = sendEngine,
                      let byteCount = engine.offer.byteCount(
                          ofChunk: index
                      ) else { break }
                let offset = Int(index)
                    * Int(engine.offer.chunkByteCount)
                let data = Array(sendBlob[offset..<offset + byteCount])
                let more = (try? sendEngine!.supplyChunk(
                    index: index, data: data
                )) ?? []
                queue.append(contentsOf: more)
            case .completed:
                counters.sharesCompleted += 1
                book.noteShared(bytes: sendBookKey)
                let engine = sendEngine
                events.append(.shareCompleted(
                    transferId: engine?.offer.transferId ?? 0,
                    byteCount: sendBlob.count
                ))
                sendBlob = []
            case .aborted(let reason, let byRemote):
                counters.sharesAborted += 1
                events.append(.shareAborted(
                    reason: reason, byRemote: byRemote
                ))
                sendBlob = []
            case .violated(let violation):
                events.append(.violated(violation))
            }
        }
        return events
    }

    // MARK: Receive-lane interior

    private mutating func admitOffer(
        _ offer: BulkOffer, mime: String,
        makeHasher: () -> any ClipboardImageHasher,
        book: inout ClipboardSyncBook
    ) -> [ClipboardImageEvent] {
        pendingIntent = nil
        // The ceiling is enforced against the OFFER, never trusted —
        // and checked BEFORE any buffer exists.
        guard offer.totalByteCount <= UInt64(imageByteCeiling) else {
            counters.receivesRefused += 1
            let events = refusal(
                .overBudget(offer.totalByteCount),
                transferId: offer.transferId, reason: .declined
            )
            // The offer IS here — nothing left to trail; retire now.
            refusedIds.remove(offer.transferId)
            return events
        }
        receiveMime = mime.lowercased()
        receiveBuffer = [UInt8](
            repeating: 0, count: Int(offer.totalByteCount)
        )
        absorbedChunks = 0
        storedAhead = []
        receiveHasher = makeHasher()
        var engine = BulkReceiveEngine()
        var actions = engine.ingest(.offer(offer))
        // The marker's admission WAS the consent verdict — the offer
        // auto-accepts (`.offered` is the only action this ingest can
        // produce for a fresh engine).
        if case .offered? = actions.first {
            actions = (try? engine.accept()) ?? []
        }
        receiveEngine = engine
        return pumpReceive(actions, makeHasher: makeHasher, book: &book)
    }

    private mutating func pumpReceive(
        _ actions: [BulkReceiveEngine.Action],
        makeHasher: () -> any ClipboardImageHasher,
        book: inout ClipboardSyncBook
    ) -> [ClipboardImageEvent] {
        var events: [ClipboardImageEvent] = []
        var queue = actions
        while !queue.isEmpty {
            let action = queue.removeFirst()
            switch action {
            case .emit(let message):
                events.append(.send(message.encode()))
            case .offered:
                // Handled at admission; unreachable thereafter.
                break
            case .store(let index, let data):
                guard let offer = receiveEngine?.offer else { break }
                let offset = Int(index) * Int(offer.chunkByteCount)
                receiveBuffer.replaceSubrange(
                    offset..<offset + data.count, with: data
                )
                absorbStoredPrefix(stored: index, offer: offer)
                let more = (try? receiveEngine!.chunkStored(
                    index: index
                )) ?? []
                queue.append(contentsOf: more)
            case .verify:
                let digest = finishReceiveDigest(makeHasher)
                let more = (try? receiveEngine!.verificationResult(
                    digest: digest
                )) ?? []
                queue.append(contentsOf: more)
            case .completed:
                counters.imagesApplied += 1
                guard let offer = receiveEngine?.offer else { break }
                book.noteRemoteApplied(
                    bytes: ClipboardImageWire.bookKey(
                        sha256: offer.sha256
                    )
                )
                events.append(.applyImage(
                    data: receiveBuffer, mime: receiveMime
                ))
                resetReceiveBuffer()
            case .aborted(let reason, let byRemote):
                counters.receivesAborted += 1
                resetReceiveBuffer()
                events.append(.receiveAborted(
                    reason: reason, byRemote: byRemote
                ))
            case .violated(let violation):
                events.append(.violated(violation))
            }
        }
        return events
    }

    /// Feeds the hasher every stored chunk that extends the contiguous
    /// prefix. Chunks normally arrive in order (one ordered stream), so
    /// each store absorbs exactly its own bytes.
    private mutating func absorbStoredPrefix(
        stored index: UInt64, offer: BulkOffer
    ) {
        guard receiveHasher != nil else { return }
        storedAhead.insert(index)
        while storedAhead.remove(absorbedChunks) != nil {
            guard let byteCount = offer.byteCount(ofChunk: absorbedChunks)
            else { break }
            let offset = Int(absorbedChunks) * Int(offer.chunkByteCount)
            receiveHasher!.absorb(
                receiveBuffer[offset..<offset + byteCount])
            absorbedChunks += 1
        }
    }

    /// The assembled image's digest: every chunk is stored by now, so
    /// the admitted hasher's prefix is the whole blob.
    private mutating func finishReceiveDigest(
        _ makeHasher: () -> any ClipboardImageHasher
    ) -> [UInt8] {
        if var hasher = receiveHasher {
            receiveHasher = nil
            return hasher.finish()
        }
        // Unreachable: admission always installs the hasher. Kept total
        // rather than trapping on a lane-state bug.
        var hasher = makeHasher()
        hasher.absorb(receiveBuffer[...])
        return hasher.finish()
    }

    private mutating func resetReceiveBuffer() {
        receiveBuffer = []
        receiveHasher = nil
        absorbedChunks = 0
        storedAhead = []
    }


    /// The refused set is bounded: entries retire when their offer
    /// trails through `ingest`, and a hostile flood of markers is capped
    /// rather than remembered.
    private mutating func rememberRefused(_ transferId: UInt64) {
        if refusedIds.count >= Self.maxRememberedRefusals {
            refusedIds.removeAll()
        }
        refusedIds.insert(transferId)
    }

    static let maxRememberedRefusals = 32

    private mutating func refusal(
        _ why: ClipboardImageRefuseReason,
        transferId: UInt64, reason: BulkAbortReason
    ) -> [ClipboardImageEvent] {
        rememberRefused(transferId)
        var events: [ClipboardImageEvent] = [.refused(why)]
        if let abort = try? BulkAbort(
            transferId: transferId, reason: reason
        ) {
            events.append(.send(BulkMessage.abort(abort).encode()))
        }
        return events
    }
}
