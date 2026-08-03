// Clipboard image sync (P-1, clipboard v2 — the H3 F-6 sketch
// inherited whole by the H4 plan's wave 2; plan retired to git
// history): image blobs ride as BULK-CHANNEL CARGO — F-2's engines,
// verbatim — marked by one small message so the two kinds of cargo
// (file drops, clipboard images) never confuse each other.
//
// THE CARGO MARKER — ClipboardImageCargo (0x22), direction-neutral,
// riding chan 8's ARQ ordered stream immediately BEFORE its transfer's
// BulkOffer. The ordered stream is the whole trick: the marker can
// never arrive after its offer, so routing is race-free by carriage,
// not by timing. The marker carries the transfer's MIME (the v1 design
// doc's promised "lazy/on-demand transfer with MIME negotiation"
// arrives here as its eager v2 subset): v2 pins image/png; a foreign
// mime draws abort(declined) — typed, counted, never a trap — and a
// future format is a new mime string, zero new wire bytes.
//
// CAPABILITY CARRIAGE — the W7 forward-compat spine, fourth verse:
// key 12 (CapabilityKey.clipboardImages, bool) rides the declaration
// through `Capabilities.unknownEntries` as one canonical `0C F5` map
// entry and survives intersection only on mutual byte-equal
// declaration. ZERO frozen bytes move. Images move only when keys 10
// AND 12 both survived — the feature (clipboard) and the dialect
// (image cargo). Key 11 is deliberately NOT in the gate: F-2 pinned
// key 11's declaration as the STANDING FILE-DROP CONSENT, and the
// Off / Text only / Text + images tier (LYTE-PLAN §8) must not
// couple image sync to file consent — an images-tier end speaks the
// chan-8 bulk vocabulary for clipboard cargo whenever key 12 agreed,
// key 11 or no. Declaration follows the tier: a text-only HOST
// truthfully never declares key 12 (the --clipboard/key-10
// precedent — declaration follows the armed leaf).
//
// LANE DISCIPLINE — one transfer at a time per direction PER LANE
// (file lane, clipboard lane), each lane single-transfer by
// construction exactly as F-2 ruled; the marker's id-routing is the
// "multiplexing is a v2 conversation the id-carrying vocabulary is
// already shaped for" evolution the F-2 record named. A second cargo
// while the clipboard lane is busy draws abort(busy). Receiver memory
// stays bounded by construction: the file lane by its disk-backed
// window, the clipboard lane by the 32 MiB ceiling.
//
// SANS-IO, the house shape: the channel has no clocks and no hashing
// (the F-2 doctrine — the ENDS hash; digests arrive as injected
// closures), randomness only at id mint (injected generator), and the
// blob lives in memory (a clipboard image is ceiling-bounded cargo,
// not a file — no disk, no resume book; a torn session just drops the
// image and a re-copy re-syncs).

/// The clipboard-image layer's fixed numbers (wire v2 of the
/// clipboard feature; wire MAJOR unchanged).
public enum ClipboardImageWire {
    /// The one v2 cargo format. Lowercase canonical; comparison is
    /// case-insensitive (mime types compare that way).
    public static let pngMime = "image/png"
    /// Every mime this build can carry, lowercase. v2 pins PNG only;
    /// formats append here (and at the leaves) with zero wire change.
    public static let acceptedMimes = [pngMime]
    /// The v2 image ceiling: 32 MiB — comfortable for 4K screenshot
    /// PNGs, and the clipboard lane's receiver-memory bound (the blob
    /// assembles in memory by design). Over-ceiling LOCAL copies are
    /// suppressed and counted, never sent (the text-ceiling rule);
    /// over-ceiling OFFERS draw abort(declined).
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
    /// The key-12 entry as it rides the wire: CBOR bool under
    /// unsigned key 12 (`0C F5` inside the map) — one canonical byte
    /// image is what makes the intersection's byte-equal rule an
    /// exact AND.
    private static var clipboardImagesEntry: CborMapEntry {
        CborMapEntry(
            key: .unsigned(CapabilityKey.clipboardImages),
            value: .bool(true)
        )
    }

    /// True when this set (a declaration or an agreed intersection)
    /// carries `clipboardImages: true`. On a v1 build the key lives
    /// in `unknownEntries` — which is exactly what makes it survive
    /// intersection only on mutual declaration. A `false` or
    /// wrongly-typed value reads as absent: absence and refusal are
    /// the same posture ("not supported"), per the spine's rule 3.
    public var clipboardImages: Bool {
        unknownEntries.contains(Self.clipboardImagesEntry)
    }

    /// A copy of this set declaring clipboard-image support.
    /// Idempotent; the CBOR encoder owns canonical key order, so the
    /// entry may append here regardless of surrounding keys.
    public func declaringClipboardImages() -> Capabilities {
        guard !clipboardImages else { return self }
        var declared = self
        declared.unknownEntries.append(Self.clipboardImagesEntry)
        return declared
    }

    /// The full image gate: feature (10) ∧ dialect (12) — images
    /// move only when BOTH survived intersection. Key 11 (the
    /// standing file-drop consent, F-2 §6) is deliberately absent:
    /// the consent tier must not couple image sync to file consent.
    /// An end with this gate true runs chan-8 bulk machinery for
    /// clipboard cargo regardless of key 11.
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
public struct ClipboardImageCargo: Hashable, Sendable {
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
        let mime = String(decoding: mimeSlice, as: UTF8.self)
        guard mime.utf8.count == mimeSlice.count,
              mime.utf8.elementsEqual(mimeSlice) else {
            throw ClipboardImageCargoError.invalidUtf8
        }
        return try ClipboardImageCargo(transferId: transferId, mime: mime)
    }

    public static func decode(
        _ payload: [UInt8]
    ) throws -> ClipboardImageCargo {
        try decode(payload[...])
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
    /// A mime-less marker is unroutable — v2 requires the format.
    case emptyMime
    /// A mime over 255 UTF-8 bytes (construction-side; the u8 length
    /// fixes the wire bound).
    case mimeOverBudget(Int)
    /// Mime bytes that are not valid UTF-8 (detected by byte-exact
    /// re-encode, the CBOR text rule).
    case invalidUtf8
}

// MARK: - The channel (both ends embed one)

/// Why a local image copy did not become cargo (routine weather,
/// counted, never an error — the text-suppression rule).
public enum ClipboardImageSuppressReason: Hashable, Sendable {
    /// The OS reporting our own remote apply back — the sync book's
    /// boomerang stop.
    case loopEcho
    /// Identical to the last image we shared — the peer holds it.
    case duplicate
    /// Past the 32 MiB v2 ceiling (byte count attached).
    case overBudget(Int)
    /// A zero-byte read — some leaf's bug, kept loud in the counter.
    case emptyImage
    /// The clipboard send lane already carries a transfer — v2 syncs
    /// latest-wins clipboards, so the superseded copy just drops.
    case sendBusy
}

/// Why incoming cargo was refused (the abort already rode out in the
/// same event batch).
public enum ClipboardImageRefuseReason: Hashable, Sendable {
    /// A mime this build cannot carry — abort(declined).
    case unsupportedMime(String)
    /// The offer's byte count is past the v2 ceiling —
    /// abort(declined). Enforced against the OFFER, never trusted.
    case overBudget(UInt64)
    /// The clipboard receive lane already carries a transfer —
    /// abort(busy).
    case receiveBusy
}

/// Everything the channel surfaces to its embedding session core.
/// `.send` is the one that moves bytes — chan 8's ordered stream;
/// the rest is evidence. Payload bytes appear ONLY in `.applyImage`
/// (the landing) — never in logs, per the CL-15 rule.
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
/// ends, driving F-2's engines with memory-backed cargo. The
/// embedding core owes it: the negotiation gate (keys 10 ∧ 12)
/// and the consent tier BEFORE calling in, hashing via the injected
/// closures, and the OS clipboard IO on `.applyImage`. The channel
/// owns: the marker handshake, the ceiling, mime policy, lane
/// occupancy, and the sync-book interplay (via the caller's book —
/// ONE book serves text and images, Clipboard.swift's rule).
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

    /// One local image copy, already past the caller's negotiation
    /// and consent-tier gates. `sha256` is the caller's digest of
    /// `data` (the ends hash — the F-2 doctrine). Gate order mirrors
    /// the text path: book → lane → ceiling.
    public mutating func shareLocalImage(
        _ data: [UInt8],
        sha256: [UInt8],
        book: inout ClipboardSyncBook,
        rng: inout some RandomNumberGenerator
    ) -> [ClipboardImageEvent] {
        guard !data.isEmpty else {
            counters.sharesSuppressed += 1
            return [.suppressed(.emptyImage)]
        }
        sendBookKey = ClipboardImageWire.bookKey(sha256: sha256)
        switch book.admitLocalChange(bytes: sendBookKey) {
        case .suppressEcho:
            counters.sharesSuppressed += 1
            return [.suppressed(.loopEcho)]
        case .suppressDuplicate:
            counters.sharesSuppressed += 1
            return [.suppressed(.duplicate)]
        case .share:
            break
        }
        guard !isSendActive else {
            counters.sharesSuppressed += 1
            return [.suppressed(.sendBusy)]
        }
        guard data.count <= imageByteCeiling else {
            counters.sharesSuppressed += 1
            return [.suppressed(.overBudget(data.count))]
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
            .unsupportedMime(cargo.mime),
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

    /// One claimed bulk message into whichever lane owns it. `sha256`
    /// digests the assembled blob at the receive lane's finish line
    /// (the ends hash).
    public mutating func ingest(
        _ message: BulkMessage,
        book: inout ClipboardSyncBook,
        sha256: ([UInt8]) -> [UInt8]
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
                refusedIds.insert(id)
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
            return admitOffer(offer, mime: intent.mime, sha256: sha256,
                              book: &book)
        }
        if receiveEngine?.offer?.transferId == id {
            let actions = receiveEngine!.ingest(message)
            return pumpReceive(actions, sha256: sha256, book: &book)
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
        sha256: ([UInt8]) -> [UInt8],
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
        var engine = BulkReceiveEngine()
        var actions = engine.ingest(.offer(offer))
        // The marker's admission WAS the consent verdict — the offer
        // auto-accepts (`.offered` is the only action this ingest can
        // produce for a fresh engine).
        if case .offered? = actions.first {
            actions = (try? engine.accept()) ?? []
        }
        receiveEngine = engine
        return pumpReceive(actions, sha256: sha256, book: &book)
    }

    private mutating func pumpReceive(
        _ actions: [BulkReceiveEngine.Action],
        sha256: ([UInt8]) -> [UInt8],
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
                let more = (try? receiveEngine!.chunkStored(
                    index: index
                )) ?? []
                queue.append(contentsOf: more)
            case .verify:
                let digest = sha256(receiveBuffer)
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
                receiveBuffer = []
            case .aborted(let reason, let byRemote):
                counters.receivesAborted += 1
                receiveBuffer = []
                events.append(.receiveAborted(
                    reason: reason, byRemote: byRemote
                ))
            case .violated(let violation):
                events.append(.violated(violation))
            }
        }
        return events
    }

    private mutating func refusal(
        _ why: ClipboardImageRefuseReason,
        transferId: UInt64, reason: BulkAbortReason
    ) -> [ClipboardImageEvent] {
        // The refused set is bounded: entries retire when their offer
        // trails through `ingest`, and a hostile flood of markers is
        // capped rather than remembered.
        if refusedIds.count > 32 { refusedIds.removeAll() }
        refusedIds.insert(transferId)
        var events: [ClipboardImageEvent] = [.refused(why)]
        if let abort = try? BulkAbort(
            transferId: transferId, reason: reason
        ) {
            events.append(.send(BulkMessage.abort(abort).encode()))
        }
        return events
    }
}
