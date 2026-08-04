// The bulk-transfer engines (W10 / F-2 — design record
// docs/20260728-053300-lyte-bulk-channel.md §7): sans-IO state
// machines for both roles. One engine instance = one transfer (v1
// runs one at a time per direction; the ends' dispatcher answers a
// second concurrent offer with abort(busy) and queues locally —
// multiplexing is a v2 conversation the id-carrying vocabulary is
// already shaped for).
//
// Sans-IO, the deliberate shape: the engines have NO TIMERS —
// retransmission and liveness belong to the ARQ sublayer and the
// session layer, consent latency belongs to a human — and randomness
// enters the bulk layer only at BulkTransferId.mint (injected
// generator). Every disk read, disk write, and hash is an ACTION the
// engine requests and a verdict the shell reports back; the ends
// drive the engines with real IO later, the tests drive them in
// virtual time now.
//
// Credit discipline (design §4): receiver-driven, cumulative,
// chunk-denominated, session-scoped. The receiver grants
// `consumed + window` and refreshes when the grant has advanced by at
// least max(1, window/2) — plus always once more when possession
// completes, so the sender always learns the end arrived. The sender
// consumes credit at READ-REQUEST time, so both ends' memory is
// bounded by the same window. Enforcement lives receiver-side where
// the memory is: a chunk beyond granted credit is a violation — a
// hostile sender can waste its own credit, never the receiver's
// memory.
//
// Error doctrine: LOCAL API misuse throws (the shell called the
// engine wrong — a bug to surface in tests); REMOTE misbehavior
// yields a `.violated` action plus abort(protocolViolation) and a
// terminal state — never a trap, never a throw.

// MARK: - Possession

/// Chunk possession as the engines track it: a contiguous prefix plus
/// out-of-prefix extras. With in-order ARQ carriage the extras stay
/// empty in practice; they exist for holed resume states and
/// under-claimed maps (design §5). Normalized by construction — no
/// extra ever equals or precedes the prefix boundary.
public struct BulkPossession: Hashable, Sendable {
    public private(set) var contiguousCount: UInt64
    public private(set) var extras: Set<UInt64>

    public init(contiguousCount: UInt64 = 0, extras: Set<UInt64> = []) {
        self.contiguousCount = contiguousCount
        self.extras = extras.filter { $0 >= contiguousCount }
        normalize()
    }

    public static let empty = BulkPossession()

    private mutating func normalize() {
        while extras.contains(contiguousCount) {
            extras.remove(contiguousCount)
            contiguousCount += 1
        }
    }

    public func holds(_ index: UInt64) -> Bool {
        index < contiguousCount || extras.contains(index)
    }

    public mutating func add(_ index: UInt64) {
        guard !holds(index) else { return }
        if index == contiguousCount {
            contiguousCount += 1
            normalize()
        } else {
            extras.insert(index)
        }
    }

    /// Union with a peer-reported map (monotonic — possession only
    /// grows).
    public mutating func merge(_ map: BulkChunkMap) {
        if map.contiguousCount > contiguousCount {
            extras.formUnion(contiguousCount..<map.contiguousCount)
        }
        extras.formUnion(map.bitmapChunkIndices)
        extras = extras.filter { $0 >= contiguousCount }
        normalize()
    }

    public func isComplete(chunkCount: UInt64) -> Bool {
        contiguousCount >= chunkCount
    }

    public var heldChunkCount: UInt64 {
        contiguousCount + UInt64(extras.count)
    }

    /// The wire encoding, under-claiming past the bitmap window
    /// (always legal, design §5).
    public var map: BulkChunkMap {
        .describing(contiguousCount: contiguousCount, extras: extras)
    }

    /// The lowest not-held index at or past `cursor` and below
    /// `chunkCount`; nil when none.
    public func nextMissing(
        from cursor: UInt64, below chunkCount: UInt64
    ) -> UInt64? {
        var index = max(cursor, 0)
        if index < contiguousCount { index = contiguousCount }
        while index < chunkCount {
            if !extras.contains(index) { return index }
            index += 1
        }
        return nil
    }
}

/// What a receiving end persists at teardown to make resume real: the
/// transfer's identity quadruple (plus the name, for the consent UI)
/// and its chunk possession. Wire re-derives everything else (design
/// §5: credit, ARQ state, and verification state deliberately do NOT
/// resume).
public struct BulkResumeState: Hashable, Sendable {
    public var transferId: UInt64
    public var totalByteCount: UInt64
    public var chunkByteCount: UInt32
    public var sha256: [UInt8]
    public var name: String
    public var possession: BulkPossession

    public init(
        transferId: UInt64,
        totalByteCount: UInt64,
        chunkByteCount: UInt32,
        sha256: [UInt8],
        name: String,
        possession: BulkPossession
    ) {
        self.transferId = transferId
        self.totalByteCount = totalByteCount
        self.chunkByteCount = chunkByteCount
        self.sha256 = sha256
        self.name = name
        self.possession = possession
    }

    /// True when `offer` names the same transfer: the WHOLE identity
    /// quadruple must match — any field differing means the file
    /// changed under the id, which draws abort(resumeMismatch).
    public func matches(_ offer: BulkOffer) -> Bool {
        transferId == offer.transferId
            && totalByteCount == offer.totalByteCount
            && chunkByteCount == offer.chunkByteCount
            && sha256 == offer.sha256
    }
}

/// Runtime knobs both engines share. Wire pins the defaults; the ends
/// may tune within the structural bounds.
public struct BulkTransferConfig: Hashable, Sendable {
    /// Receiver window: the ceiling on admitted-but-not-yet-stored
    /// chunks, which is exactly the receiver's un-persisted memory
    /// bound (16 × 64 KiB = 1 MiB at the defaults) and the sender's
    /// read-ahead bound alike. Clamped to ≥ 1 — a zero window could
    /// never move a byte.
    public var receiveWindowChunks: Int

    public init(receiveWindowChunks: Int = 16) {
        self.receiveWindowChunks = max(1, receiveWindowChunks)
    }
}

/// How a peer broke the state machine. Reported via `.violated`, then
/// the transfer aborts with `.protocolViolation`.
public enum BulkTransferViolation: Hashable, Sendable {
    /// A message that cannot occur in the current state (or belongs
    /// to the opposite role).
    case unexpectedMessage(type: UInt8)
    /// A message naming a transferId other than this engine's.
    case foreignTransfer(UInt64)
    /// A chunk index at or past chunkCount.
    case chunkOutOfRange(UInt64)
    /// A chunk already held this session (outside the resume
    /// under-claim tolerance).
    case duplicateChunk(UInt64)
    /// Chunk data whose size disagrees with the offer's geometry.
    case chunkByteCountMismatch(index: UInt64, byteCount: Int)
    /// More chunks than the granted credit — the backpressure
    /// contract broken.
    case creditExceeded
    /// A possession map claiming chunks at or past chunkCount.
    case possessionOverClaimed
}

// MARK: - The sender

/// Everything the sender's LOCAL API can refuse (shell bugs, loud).
public enum BulkSendError: Error, Equatable, Sendable {
    /// begin() called twice.
    case notIdle
    /// supplyChunk for an index no `.readChunk` action requested.
    case chunkNotRequested(UInt64)
    /// supplyChunk data whose size disagrees with the offer geometry.
    case wrongChunkByteCount(index: UInt64, expected: Int, actual: Int)
}

/// The sending role (the client in v1): offers, consumes credit,
/// turns shell reads into chunks, resumes from the receiver's map,
/// and waits for the receiver's digest verdict.
public struct BulkSendEngine: Sendable {
    public enum State: Hashable, Sendable {
        case idle
        /// Offer emitted, consent pending.
        case offering
        /// Accept received; chunks flowing under credit.
        case transferring
        /// The receiver holds every chunk; its digest verdict decides.
        case awaitingVerification
        case completed
        case aborted(BulkAbortReason, byRemote: Bool)
    }

    public enum Action: Hashable, Sendable {
        /// Hand these bytes to the chan-8 ARQ ordered stream.
        case emit(BulkMessage)
        /// Read this chunk and call `supplyChunk(index:data:)`.
        case readChunk(index: UInt64)
        /// The receiver verified the digest — the transfer is done.
        case completed
        /// Terminal failure; `byRemote` says whose abort it was.
        case aborted(BulkAbortReason, byRemote: Bool)
        /// The peer broke the protocol (precedes the abort emission).
        case violated(BulkTransferViolation)
    }

    public let offer: BulkOffer
    public private(set) var state: State = .idle
    /// Chunks the receiver is known to hold (its reports, merged
    /// monotonically).
    public private(set) var remoteHeld: BulkPossession = .empty
    /// The session's dispatch budget, as last granted.
    public private(set) var creditTotal: UInt64 = 0
    /// Credit consumed: reads issued this session (issue-time
    /// consumption is what bounds sender-side memory by the window).
    public private(set) var issuedReadCount: UInt64 = 0

    private var outstandingReads: Set<UInt64> = []
    /// Indices issued or sent this session — never re-dispatched.
    private var issued: Set<UInt64> = []
    private var dispatchCursor: UInt64 = 0

    public init(offer: BulkOffer) {
        self.offer = offer
    }

    public var chunkCount: UInt64 { offer.chunkCount }

    /// Emits the offer. Idle only.
    public mutating func begin() throws -> [Action] {
        guard case .idle = state else {
            throw BulkSendError.notIdle
        }
        state = .offering
        return [.emit(.offer(offer))]
    }

    /// Feeds one receiver→sender message (already decoded by the
    /// chan-8 shell). Never throws — remote badness aborts, terminal
    /// states swallow.
    public mutating func ingest(_ message: BulkMessage) -> [Action] {
        if isTerminal { return [] }
        guard message.transferId == offer.transferId else {
            return violate(.foreignTransfer(message.transferId))
        }
        switch message {
        case .accept(let accept):
            return ingestAccept(accept)
        case .ack(let ack):
            return ingestAck(ack)
        case .complete:
            switch state {
            case .transferring, .awaitingVerification:
                state = .completed
                return [.completed]
            default:
                return violate(.unexpectedMessage(
                    type: CtrlMessageType.bulkComplete
                ))
            }
        case .abort(let abort):
            state = .aborted(abort.reason, byRemote: true)
            return [.aborted(abort.reason, byRemote: true)]
        case .offer:
            return violate(.unexpectedMessage(
                type: CtrlMessageType.bulkOffer
            ))
        case .chunk:
            return violate(.unexpectedMessage(
                type: CtrlMessageType.bulkChunk
            ))
        }
    }

    /// The shell's answer to a `.readChunk` action. Emits the chunk.
    /// Stale reads (the transfer moved past transferring while the
    /// read was in flight) are dropped silently.
    public mutating func supplyChunk(
        index: UInt64, data: [UInt8]
    ) throws -> [Action] {
        switch state {
        case .transferring:
            break
        case .awaitingVerification, .completed, .aborted:
            return []
        case .idle, .offering:
            throw BulkSendError.chunkNotRequested(index)
        }
        guard outstandingReads.contains(index) else {
            throw BulkSendError.chunkNotRequested(index)
        }
        guard let expected = offer.byteCount(ofChunk: index),
              data.count == expected
        else {
            throw BulkSendError.wrongChunkByteCount(
                index: index,
                expected: offer.byteCount(ofChunk: index) ?? 0,
                actual: data.count
            )
        }
        outstandingReads.remove(index)
        // The init cannot fail: id is non-zero, data is 1…chunk-size.
        guard let chunk = try? BulkChunk(
            transferId: offer.transferId, chunkIndex: index, data: data
        ) else {
            return []
        }
        return [.emit(.chunk(chunk))]
    }

    /// A human cancelled. Emits abort(cancelled) when a transfer is
    /// in flight; terminal states swallow.
    public mutating func cancel() -> [Action] {
        if isTerminal { return [] }
        let wasIdle = (state == .idle)
        state = .aborted(.cancelled, byRemote: false)
        var actions: [Action] = []
        if !wasIdle, let abort = try? BulkAbort(
            transferId: offer.transferId, reason: .cancelled
        ) {
            actions.append(.emit(.abort(abort)))
        }
        actions.append(.aborted(.cancelled, byRemote: false))
        return actions
    }

    public var isTerminal: Bool {
        switch state {
        case .completed, .aborted: return true
        default: return false
        }
    }

    // MARK: internals

    private mutating func ingestAccept(_ accept: BulkAccept) -> [Action] {
        guard case .offering = state else {
            return violate(.unexpectedMessage(
                type: CtrlMessageType.bulkAccept
            ))
        }
        guard mapWithinBounds(accept.possession) else {
            return violate(.possessionOverClaimed)
        }
        remoteHeld.merge(accept.possession)
        creditTotal = accept.creditTotal
        if remoteHeld.isComplete(chunkCount: chunkCount) {
            state = .awaitingVerification
            return []
        }
        state = .transferring
        return issueReads()
    }

    private mutating func ingestAck(_ ack: BulkAck) -> [Action] {
        switch state {
        case .transferring, .awaitingVerification:
            break
        default:
            return violate(.unexpectedMessage(
                type: CtrlMessageType.bulkAck
            ))
        }
        guard mapWithinBounds(ack.possession) else {
            return violate(.possessionOverClaimed)
        }
        remoteHeld.merge(ack.possession)
        // Monotonic max — a stale (ARQ-ordered but policy-stale)
        // grant never claws credit back.
        creditTotal = max(creditTotal, ack.creditTotal)
        if remoteHeld.isComplete(chunkCount: chunkCount) {
            state = .awaitingVerification
            outstandingReads.removeAll()
            return []
        }
        guard case .transferring = state else { return [] }
        return issueReads()
    }

    /// Requests reads for the next missing chunks while credit
    /// allows. Credit is consumed here, at issue time.
    private mutating func issueReads() -> [Action] {
        var actions: [Action] = []
        while issuedReadCount < creditTotal {
            var cursor = dispatchCursor
            var candidate: UInt64?
            while let next = remoteHeld.nextMissing(
                from: cursor, below: chunkCount
            ) {
                if !issued.contains(next) {
                    candidate = next
                    break
                }
                cursor = next + 1
            }
            guard let index = candidate else { break }
            issued.insert(index)
            outstandingReads.insert(index)
            issuedReadCount += 1
            dispatchCursor = index + 1
            actions.append(.readChunk(index: index))
        }
        return actions
    }

    private func mapWithinBounds(_ map: BulkChunkMap) -> Bool {
        guard map.contiguousCount <= chunkCount else { return false }
        return map.bitmapChunkIndices.allSatisfy { $0 < chunkCount }
    }

    private mutating func violate(
        _ violation: BulkTransferViolation
    ) -> [Action] {
        state = .aborted(.protocolViolation, byRemote: false)
        var actions: [Action] = [.violated(violation)]
        if let abort = try? BulkAbort(
            transferId: offer.transferId, reason: .protocolViolation
        ) {
            actions.append(.emit(.abort(abort)))
        }
        actions.append(.aborted(.protocolViolation, byRemote: false))
        return actions
    }
}

// MARK: - The receiver

/// Everything the receiver's LOCAL API can refuse (shell bugs, loud).
public enum BulkReceiveError: Error, Equatable, Sendable {
    /// accept()/decline() with no offer pending.
    case noOfferPending
    /// chunkStored for an index no `.store` action requested.
    case storeNotPending(UInt64)
    /// verificationResult outside the verifying state.
    case notVerifying
}

/// The receiving role (the host in v1): answers offers under the
/// end's consent verdict, issues credit as stores complete (the
/// backpressure), books possession, matches resume offers against the
/// persisted book, and renders the completion verdict digest-exact.
public struct BulkReceiveEngine: Sendable {
    public enum State: Hashable, Sendable {
        case awaitingOffer
        /// An offer surfaced; the shell owes accept() or decline().
        case offered
        case receiving
        /// Every chunk held; the shell owes verificationResult(...).
        case verifying
        case completed
        case aborted(BulkAbortReason, byRemote: Bool)
    }

    public enum Action: Hashable, Sendable {
        /// Consult consent and call accept() or decline().
        case offered(BulkOffer, resuming: Bool)
        /// Hand these bytes to the chan-8 ARQ ordered stream.
        case emit(BulkMessage)
        /// Persist this chunk, then call `chunkStored(index:)` (or
        /// `storageFailed()`).
        case store(index: UInt64, data: [UInt8])
        /// Digest the assembled blob and call
        /// `verificationResult(digest:)`.
        case verify
        case completed
        case aborted(BulkAbortReason, byRemote: Bool)
        case violated(BulkTransferViolation)
    }

    public let config: BulkTransferConfig
    public private(set) var state: State = .awaitingOffer
    public private(set) var offer: BulkOffer?
    public private(set) var possession: BulkPossession = .empty
    /// The session's grant, as last emitted (monotonic).
    public private(set) var grantedCreditTotal: UInt64 = 0

    /// Persisted unfinished transfers, by id — the resume book.
    private var resumeBook: [UInt64: BulkResumeState]
    /// Possession as of this session's start — the under-claim
    /// duplicate tolerance boundary (design §5).
    private var sessionStartPossession: BulkPossession = .empty
    /// Chunks stored or tolerated this session (credit consumption).
    private var consumedChunkCount: UInt64 = 0
    private var pendingStores: Set<UInt64> = []

    public init(
        config: BulkTransferConfig = BulkTransferConfig(),
        resumeBook: [BulkResumeState] = []
    ) {
        self.config = config
        self.resumeBook = Dictionary(
            resumeBook.map { ($0.transferId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// What to persist at teardown to make resume real; nil unless a
    /// transfer is actually mid-flight.
    public var resumeState: BulkResumeState? {
        guard let offer else { return nil }
        switch state {
        case .receiving, .verifying:
            return BulkResumeState(
                transferId: offer.transferId,
                totalByteCount: offer.totalByteCount,
                chunkByteCount: offer.chunkByteCount,
                sha256: offer.sha256,
                name: offer.name,
                possession: possession
            )
        default:
            return nil
        }
    }

    public var isTerminal: Bool {
        switch state {
        case .completed, .aborted: return true
        default: return false
        }
    }

    /// Feeds one sender→receiver message (already decoded by the
    /// chan-8 shell). Never throws.
    public mutating func ingest(_ message: BulkMessage) -> [Action] {
        if isTerminal { return [] }
        switch message {
        case .offer(let offer):
            return ingestOffer(offer)
        case .chunk(let chunk):
            return ingestChunk(chunk)
        case .abort(let abort):
            guard matchesActive(abort.transferId) else {
                return violate(.foreignTransfer(abort.transferId))
            }
            state = .aborted(abort.reason, byRemote: true)
            return [.aborted(abort.reason, byRemote: true)]
        case .accept:
            return violate(.unexpectedMessage(
                type: CtrlMessageType.bulkAccept
            ))
        case .ack:
            return violate(.unexpectedMessage(
                type: CtrlMessageType.bulkAck
            ))
        case .complete:
            return violate(.unexpectedMessage(
                type: CtrlMessageType.bulkComplete
            ))
        }
    }

    /// Consent granted. Emits the accept (possession + opening
    /// credit); a resume whose possession is already complete skips
    /// straight to verification — the digest is cheap insurance
    /// exactly when a teardown interrupted the finish (design §5).
    public mutating func accept() throws -> [Action] {
        guard case .offered = state, let offer else {
            throw BulkReceiveError.noOfferPending
        }
        if possession.isComplete(chunkCount: offer.chunkCount) {
            grantedCreditTotal = 0
            state = .verifying
            guard let message = try? BulkAccept(
                transferId: offer.transferId,
                creditTotal: 0,
                possession: possession.map
            ) else { return [] }
            return [.emit(.accept(message)), .verify]
        }
        grantedCreditTotal = UInt64(config.receiveWindowChunks)
        state = .receiving
        guard let message = try? BulkAccept(
            transferId: offer.transferId,
            creditTotal: grantedCreditTotal,
            possession: possession.map
        ) else { return [] }
        return [.emit(.accept(message))]
    }

    /// Consent refused (toggle off, user said no).
    public mutating func decline() throws -> [Action] {
        guard case .offered = state, let offer else {
            throw BulkReceiveError.noOfferPending
        }
        state = .aborted(.declined, byRemote: false)
        var actions: [Action] = []
        if let abort = try? BulkAbort(
            transferId: offer.transferId, reason: .declined
        ) {
            actions.append(.emit(.abort(abort)))
        }
        actions.append(.aborted(.declined, byRemote: false))
        return actions
    }

    /// The shell durably stored a requested chunk. Advances
    /// possession and the credit clock; completion emits the final
    /// ack plus the verify request.
    public mutating func chunkStored(index: UInt64) throws -> [Action] {
        guard pendingStores.contains(index) else {
            throw BulkReceiveError.storeNotPending(index)
        }
        pendingStores.remove(index)
        possession.add(index)
        consumedChunkCount += 1
        return creditActions()
    }

    /// The shell's digest of the assembled blob. Match → complete;
    /// mismatch → abort(shaMismatch).
    public mutating func verificationResult(
        digest: [UInt8]
    ) throws -> [Action] {
        guard case .verifying = state, let offer else {
            throw BulkReceiveError.notVerifying
        }
        if digest == offer.sha256 {
            state = .completed
            resumeBook.removeValue(forKey: offer.transferId)
            guard let message = try? BulkComplete(
                transferId: offer.transferId
            ) else { return [.completed] }
            return [.emit(.complete(message)), .completed]
        }
        state = .aborted(.shaMismatch, byRemote: false)
        var actions: [Action] = []
        if let abort = try? BulkAbort(
            transferId: offer.transferId, reason: .shaMismatch
        ) {
            actions.append(.emit(.abort(abort)))
        }
        actions.append(.aborted(.shaMismatch, byRemote: false))
        return actions
    }

    /// The shell's disk said no (full, write error).
    public mutating func storageFailed() -> [Action] {
        switch state {
        case .receiving, .verifying, .offered:
            break
        default:
            return []
        }
        guard let offer else { return [] }
        state = .aborted(.storageFailure, byRemote: false)
        var actions: [Action] = []
        if let abort = try? BulkAbort(
            transferId: offer.transferId, reason: .storageFailure
        ) {
            actions.append(.emit(.abort(abort)))
        }
        actions.append(.aborted(.storageFailure, byRemote: false))
        return actions
    }

    /// A human cancelled.
    public mutating func cancel() -> [Action] {
        if isTerminal { return [] }
        let hadTransfer = (offer != nil && state != .awaitingOffer)
        state = .aborted(.cancelled, byRemote: false)
        var actions: [Action] = []
        if hadTransfer, let offer, let abort = try? BulkAbort(
            transferId: offer.transferId, reason: .cancelled
        ) {
            actions.append(.emit(.abort(abort)))
        }
        actions.append(.aborted(.cancelled, byRemote: false))
        return actions
    }

    // MARK: internals

    private func matchesActive(_ transferId: UInt64) -> Bool {
        offer.map { $0.transferId == transferId } ?? true
    }

    private mutating func ingestOffer(_ incoming: BulkOffer) -> [Action] {
        guard case .awaitingOffer = state else {
            return violate(.unexpectedMessage(
                type: CtrlMessageType.bulkOffer
            ))
        }
        if let persisted = resumeBook[incoming.transferId] {
            guard persisted.matches(incoming) else {
                // The file changed under the id — refuse loudly; the
                // sender's recovery is a fresh id.
                state = .aborted(.resumeMismatch, byRemote: false)
                var actions: [Action] = []
                if let abort = try? BulkAbort(
                    transferId: incoming.transferId,
                    reason: .resumeMismatch
                ) {
                    actions.append(.emit(.abort(abort)))
                }
                actions.append(
                    .aborted(.resumeMismatch, byRemote: false)
                )
                return actions
            }
            possession = persisted.possession
        } else {
            possession = .empty
        }
        sessionStartPossession = possession
        offer = incoming
        state = .offered
        return [.offered(incoming, resuming: possession != .empty)]
    }

    private mutating func ingestChunk(_ chunk: BulkChunk) -> [Action] {
        guard case .receiving = state, let offer else {
            return violate(.unexpectedMessage(
                type: CtrlMessageType.bulkChunk
            ))
        }
        guard chunk.transferId == offer.transferId else {
            return violate(.foreignTransfer(chunk.transferId))
        }
        let admissionDebt = consumedChunkCount + UInt64(pendingStores.count)
        guard admissionDebt < grantedCreditTotal else {
            return violate(.creditExceeded)
        }
        guard let expected = offer.byteCount(ofChunk: chunk.chunkIndex)
        else {
            return violate(.chunkOutOfRange(chunk.chunkIndex))
        }
        guard chunk.data.count == expected else {
            return violate(.chunkByteCountMismatch(
                index: chunk.chunkIndex, byteCount: chunk.data.count
            ))
        }
        if possession.holds(chunk.chunkIndex)
            || pendingStores.contains(chunk.chunkIndex) {
            // Held from the RESUME state = the under-claim tolerance
            // (design §5): the sender could not know. Held from this
            // session's own stores = a duplicate an honest exactly-
            // once sender cannot produce.
            guard sessionStartPossession.holds(chunk.chunkIndex),
                  !pendingStores.contains(chunk.chunkIndex)
            else {
                return violate(.duplicateChunk(chunk.chunkIndex))
            }
            consumedChunkCount += 1
            return creditActions()
        }
        pendingStores.insert(chunk.chunkIndex)
        return [.store(index: chunk.chunkIndex, data: chunk.data)]
    }

    /// The credit clock: grant = consumed + window, refreshed when it
    /// has advanced by ≥ max(1, window/2) — and always at completion,
    /// with the final (exact, hole-free) map, so the sender learns
    /// the end arrived.
    private mutating func creditActions() -> [Action] {
        guard let offer else { return [] }
        if possession.isComplete(chunkCount: offer.chunkCount) {
            state = .verifying
            grantedCreditTotal = max(
                grantedCreditTotal,
                consumedChunkCount
                    + UInt64(config.receiveWindowChunks)
            )
            guard let ack = try? BulkAck(
                transferId: offer.transferId,
                creditTotal: grantedCreditTotal,
                possession: possession.map
            ) else { return [.verify] }
            return [.emit(.ack(ack)), .verify]
        }
        let candidate = consumedChunkCount
            + UInt64(config.receiveWindowChunks)
        let step = UInt64(max(1, config.receiveWindowChunks / 2))
        guard candidate >= grantedCreditTotal + step else {
            return []
        }
        grantedCreditTotal = candidate
        guard let ack = try? BulkAck(
            transferId: offer.transferId,
            creditTotal: grantedCreditTotal,
            possession: possession.map
        ) else { return [] }
        return [.emit(.ack(ack))]
    }

    private mutating func violate(
        _ violation: BulkTransferViolation
    ) -> [Action] {
        let abortId = offer?.transferId
        state = .aborted(.protocolViolation, byRemote: false)
        var actions: [Action] = [.violated(violation)]
        if let abortId, let abort = try? BulkAbort(
            transferId: abortId, reason: .protocolViolation
        ) {
            actions.append(.emit(.abort(abort)))
        }
        actions.append(.aborted(.protocolViolation, byRemote: false))
        return actions
    }
}
