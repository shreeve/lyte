// BulkReceiveShell (F-3): the host's receiving end of file transfer —
// the shell that drives Wire's sans-IO BulkReceiveEngine with real
// disk verdicts (design record 20260728-053300 §7/§9). The engine
// owns every protocol decision (credit, possession, resume matching,
// violations); this shell answers its ACTIONS:
//
//   • `.offered`  → consent is the standing per-host toggle — the
//     shell existing IS the yes (lyte-host builds one only when
//     --accept-files armed it and declared key 11). What the shell
//     still judges is the DISK: an offer whose remainder exceeds free
//     space draws abort(storageFailure) — the truthful reason ("the
//     receiver's disk said no"), not declined.
//   • `.store`    → a durable write (pwrite + fsync) into the hidden
//     `.part` staging file at the chunk's exact offset, THEN
//     `chunkStored` — fsync-before-ack, so persisted possession never
//     claims a byte the disk could still lose.
//   • `.verify`   → a streaming SHA-256 of the staging file into
//     `verificationResult` — the sha-exact finish line.
//   • `.completed`→ fsync-then-rename promotion into the destination
//     directory under a SANITIZED, collision-numbered name (the
//     offer's name is untrusted input; kill -9 mid-transfer leaves
//     only the dotted staging file, never a partial in the drop dir).
//
// One transfer at a time (v1): a second concurrent offer draws
// abort(busy) from THIS dispatcher — the engine never sees it — and a
// terminal engine is re-armed fresh, seeded with the shell's resume
// book. The RECEIVING end owes persistence (design §5): `teardown()`
// writes the mid-flight BulkResumeState beside the staging file, and
// construction loads every persisted state back as the engine's
// resume book, so a torn session resumes sha-exact from the gap.
//
// Threading is the caller's concern (lyte-host drains session events
// into `ingest` off the session lock, the SessionWire clipboard
// pattern); file IO lives behind the BulkReceiveStore seam so the
// failure paths are testable without a failing disk.

import LyteWire

/// What the shell needs from the disk. One production conformance
/// (`BulkFileStore`, POSIX); tests wrap it to inject failures.
public protocol BulkReceiveStore: AnyObject {
    /// Absolute destination directory (for events and logs).
    var directoryPath: String { get }
    /// Open (creating if absent) the transfer's staging file. The
    /// staging file is dotted — invisible in the drop directory.
    func openStaging(transferId: UInt64) throws
    /// Write `data` at `byteOffset`, DURABLE on return (fsync — the
    /// fsync-before-ack rule; a false `chunkStored` would poison the
    /// persisted possession map).
    func writeChunkDurably(
        _ data: [UInt8], atByteOffset byteOffset: UInt64
    ) throws
    /// Streaming SHA-256 of the whole staging file.
    func stagingDigest() throws -> [UInt8]
    /// fsync, close, and atomically rename the staging file to `name`
    /// in the destination directory (plus a directory fsync, so the
    /// rename itself is durable).
    func promoteStaging(toName name: String) throws
    /// Remove the transfer's staging file (aborted transfers whose
    /// possession has no future).
    func removeStaging(transferId: UInt64)
    /// Close the staging descriptor without removing the file.
    func closeStaging()
    /// True when `name` already exists in the destination directory —
    /// the collision-numbering probe.
    func finalNameExists(_ name: String) -> Bool
    /// Free bytes on the destination filesystem; nil when the OS
    /// cannot say (the shell then accepts and lets writes speak).
    func freeDiskSpaceByteCount() -> UInt64?
    /// Every persisted resume state in the directory (startup).
    func loadResumeStates() -> [BulkResumeState]
    /// Persist one resume state beside its staging file (atomic:
    /// tmp + fsync + rename).
    func persistResumeState(_ state: BulkResumeState) throws
    /// Remove a transfer's persisted resume state.
    func removeResumeState(transferId: UInt64)
}

/// What the shell's caller must know about. `.send` is the one that
/// moves bytes — the loop feeds it to `Session.sendBulk`; the rest is
/// evidence for logs and tests. Payload bytes never appear here.
public enum BulkReceiveShellEvent: Equatable, Sendable {
    /// Put this message on chan 8's ordered stream.
    case send(BulkMessage)
    /// Consent granted (the toggle stands); the accept is in flight.
    case offerAccepted(
        transferId: UInt64, name: String, byteCount: UInt64,
        resuming: Bool
    )
    /// v1 runs ONE transfer at a time — a second concurrent offer
    /// drew abort(busy) from the dispatcher, engine untouched.
    case offerRefusedBusy(transferId: UInt64)
    /// The offer's remainder exceeds free disk space —
    /// abort(storageFailure) follows in the same batch.
    case insufficientDiskSpace(neededByteCount: UInt64, freeByteCount: UInt64)
    /// The finish line: sha-verified, promoted, visible under `name`.
    case fileCompleted(name: String, path: String, byteCount: UInt64)
    /// Terminal failure; `byRemote` says whose abort it was.
    case transferAborted(reason: BulkAbortReason, byRemote: Bool)
    /// The disk said no (detail for the log; the wire answer is the
    /// abort in the same batch).
    case storageFailure(String)
    /// The peer broke the state machine (precedes the abort).
    case violated(BulkTransferViolation)
}

public struct BulkReceiveShellCounters: Equatable, Sendable {
    public var offersAccepted = 0
    public var offersRefusedBusy = 0
    public var spaceRefusals = 0
    public var chunksStored = 0
    public var bytesStored: UInt64 = 0
    public var filesCompleted = 0
    public var transfersAborted = 0
    public var storageFailures = 0
    public var resumeStatesLoaded = 0

    public init() {}
}

public final class BulkReceiveShell {
    public private(set) var counters = BulkReceiveShellCounters()

    private var engine: BulkReceiveEngine
    private let store: BulkReceiveStore
    private let config: BulkTransferConfig
    /// The shell's mirror of the on-disk resume book — what re-armed
    /// engines are seeded with.
    private var book: [BulkResumeState]

    public init(
        store: BulkReceiveStore,
        config: BulkTransferConfig = BulkTransferConfig()
    ) {
        self.store = store
        self.config = config
        self.book = store.loadResumeStates()
        self.counters.resumeStatesLoaded = book.count
        self.engine = BulkReceiveEngine(config: config, resumeBook: book)
    }

    /// The production shape: a POSIX store on `directoryPath`,
    /// created if missing. Throws when the directory cannot exist.
    public convenience init(
        directoryPath: String,
        config: BulkTransferConfig = BulkTransferConfig()
    ) throws {
        self.init(
            store: try BulkFileStore(directoryPath: directoryPath),
            config: config
        )
    }

    public var state: BulkReceiveEngine.State { engine.state }

    /// True while an offer/transfer is mid-flight — the busy gate.
    public var isTransferActive: Bool {
        switch engine.state {
        case .offered, .receiving, .verifying: return true
        case .awaitingOffer, .completed, .aborted: return false
        }
    }

    /// One decoded chan-8 message (the session's
    /// `.bulkMessageReceived`) into the engine, every resulting
    /// action answered synchronously. Never throws: remote badness is
    /// the engine's violation path, disk badness is the storage-
    /// failure path, and a second concurrent offer is answered
    /// abort(busy) right here (the v1 dispatcher rule — the engine is
    /// single-transfer by construction and never sees it).
    public func ingest(_ message: BulkMessage) -> [BulkReceiveShellEvent] {
        if case .offer(let incoming) = message, isTransferActive {
            counters.offersRefusedBusy += 1
            var events: [BulkReceiveShellEvent] = []
            if let abort = try? BulkAbort(
                transferId: incoming.transferId, reason: .busy
            ) {
                events.append(.send(.abort(abort)))
            }
            events.append(.offerRefusedBusy(transferId: incoming.transferId))
            return events
        }
        return pump(engine.ingest(message))
    }

    /// A human at the host cancelled (future control surface; wired
    /// for completeness — the engines mirror it).
    public func cancel() -> [BulkReceiveShellEvent] {
        pump(engine.cancel())
    }

    /// The session is going down: persist the mid-flight resume state
    /// beside its staging file (the receiving end's one resume
    /// obligation, design §5) and release the descriptor. Idempotent.
    public func teardown() {
        if let resume = engine.resumeState {
            try? store.persistResumeState(resume)
        }
        store.closeStaging()
    }

    // MARK: The action pump

    private func pump(
        _ actions: [BulkReceiveEngine.Action]
    ) -> [BulkReceiveShellEvent] {
        var events: [BulkReceiveShellEvent] = []
        for action in actions {
            switch action {
            case .emit(let message):
                events.append(.send(message))

            case .offered(let offer, let resuming):
                events += answerOffer(offer, resuming: resuming)

            case .store(let index, let data):
                events += storeChunk(index: index, data: data)

            case .verify:
                events += verifyStaging()

            case .completed:
                events += promoteCompleted()

            case .aborted(let reason, let byRemote):
                events += cleanUpAborted(reason: reason, byRemote: byRemote)

            case .violated(let violation):
                events.append(.violated(violation))
            }
        }
        return events
    }

    private func answerOffer(
        _ offer: BulkOffer, resuming: Bool
    ) -> [BulkReceiveShellEvent] {
        var events: [BulkReceiveShellEvent] = []
        // The disk-space judgment: refuse an offer the filesystem
        // cannot hold — abort(storageFailure), the truthful reason.
        // The remainder is exact (all chunks are chunkByteCount but
        // the last), so a resume is only charged for its gap.
        let needed = remainingByteCount(of: offer)
        if let free = store.freeDiskSpaceByteCount(), needed > free {
            counters.spaceRefusals += 1
            counters.storageFailures += 1
            events.append(.insufficientDiskSpace(
                neededByteCount: needed, freeByteCount: free
            ))
            events += pump(engine.storageFailed())
            return events
        }
        do {
            try store.openStaging(transferId: offer.transferId)
        } catch {
            events += failStorage("open staging: \(error)")
            return events
        }
        counters.offersAccepted += 1
        events.append(.offerAccepted(
            transferId: offer.transferId,
            name: offer.name,
            byteCount: offer.totalByteCount,
            resuming: resuming
        ))
        guard let actions = try? engine.accept() else {
            assertionFailure("accept refused with an offer pending")
            return events
        }
        events += pump(actions)
        return events
    }

    private func storeChunk(
        index: UInt64, data: [UInt8]
    ) -> [BulkReceiveShellEvent] {
        guard let offer = engine.offer else {
            assertionFailure("store action without an active offer")
            return []
        }
        let offset = index * UInt64(offer.chunkByteCount)
        do {
            try store.writeChunkDurably(data, atByteOffset: offset)
        } catch {
            return failStorage("chunk \(index): \(error)")
        }
        counters.chunksStored += 1
        counters.bytesStored &+= UInt64(data.count)
        guard let actions = try? engine.chunkStored(index: index) else {
            assertionFailure("chunkStored refused for a pending store")
            return []
        }
        return pump(actions)
    }

    private func verifyStaging() -> [BulkReceiveShellEvent] {
        let digest: [UInt8]
        do {
            digest = try store.stagingDigest()
        } catch {
            return failStorage("verify: \(error)")
        }
        guard let actions = try? engine.verificationResult(digest: digest)
        else {
            assertionFailure("verificationResult outside verifying")
            return []
        }
        return pump(actions)
    }

    private func promoteCompleted() -> [BulkReceiveShellEvent] {
        guard let offer = engine.offer else {
            assertionFailure("completed without an offer")
            return []
        }
        var events: [BulkReceiveShellEvent] = []
        // The offer's name is UNTRUSTED input: sanitize (path
        // separators, dotfiles, control bytes), then number around
        // whatever already owns the name.
        let finalName = BulkFileNaming.collisionFree(
            BulkFileNaming.sanitized(offer.name),
            exists: store.finalNameExists
        )
        do {
            try store.promoteStaging(toName: finalName)
            store.removeResumeState(transferId: offer.transferId)
            book.removeAll { $0.transferId == offer.transferId }
            counters.filesCompleted += 1
            events.append(.fileCompleted(
                name: finalName,
                path: store.directoryPath + "/" + finalName,
                byteCount: offer.totalByteCount
            ))
        } catch {
            // Verified and complete on the wire, but the promotion
            // failed — loud, staging kept (the bytes are sha-good).
            counters.storageFailures += 1
            events.append(.storageFailure("promote: \(error)"))
        }
        rearm()
        return events
    }

    private func cleanUpAborted(
        reason: BulkAbortReason, byRemote: Bool
    ) -> [BulkReceiveShellEvent] {
        counters.transfersAborted += 1
        let transferId = engine.offer?.transferId
        store.closeStaging()
        switch reason {
        case .storageFailure, .resumeMismatch:
            // The persisted possession is still honest for a future
            // re-offer of the same quadruple (disk-full clears, the
            // confused sender re-baselines with a fresh id) — keep
            // the staging file exactly when a resume book entry
            // vouches for it; a fresh transfer's orphan is removed.
            if let transferId,
               !book.contains(where: { $0.transferId == transferId }) {
                store.removeStaging(transferId: transferId)
            }
        default:
            // declined/cancelled/shaMismatch/busy/protocolViolation:
            // the partial has no future — no strays in the drop dir.
            if let transferId {
                store.removeStaging(transferId: transferId)
                store.removeResumeState(transferId: transferId)
                book.removeAll { $0.transferId == transferId }
            }
        }
        rearm()
        return [.transferAborted(reason: reason, byRemote: byRemote)]
    }

    /// A disk refusal mid-transfer: persist the possession the engine
    /// still vouches for (its map excludes the failed chunk — the
    /// fsync audit dropping what it could not durably write, design
    /// §5), then let the engine abort with the truthful reason.
    private func failStorage(_ detail: String) -> [BulkReceiveShellEvent] {
        counters.storageFailures += 1
        var events: [BulkReceiveShellEvent] = [.storageFailure(detail)]
        if let snapshot = engine.resumeState {
            try? store.persistResumeState(snapshot)
            book.removeAll { $0.transferId == snapshot.transferId }
            book.append(snapshot)
        }
        events += pump(engine.storageFailed())
        return events
    }

    /// One engine instance = one transfer: a terminal engine is
    /// replaced by a fresh one seeded with the current resume book.
    private func rearm() {
        engine = BulkReceiveEngine(config: config, resumeBook: book)
    }

    /// Bytes still owed for `offer` given the engine's possession —
    /// exact, since every chunk but the last is exactly
    /// chunkByteCount.
    private func remainingByteCount(of offer: BulkOffer) -> UInt64 {
        let possession = engine.possession
        guard possession.heldChunkCount > 0, offer.chunkCount > 0 else {
            return offer.totalByteCount
        }
        let lastIndex = offer.chunkCount - 1
        let holdsLast = possession.holds(lastIndex)
        let fullChunksHeld = possession.heldChunkCount
            - (holdsLast ? 1 : 0)
        var held = fullChunksHeld * UInt64(offer.chunkByteCount)
        if holdsLast {
            held += UInt64(offer.byteCount(ofChunk: lastIndex) ?? 0)
        }
        return offer.totalByteCount > held
            ? offer.totalByteCount - held : 0
    }
}

// MARK: - Filename sanitization

/// The offer's name is hostile until proven boring (design §3: "sani-
/// tization is the receiver end's job — path separators, dotfiles").
/// Pure functions, pinned by a table in the gate tests.
public enum BulkFileNaming {
    /// The fallback when sanitization consumes the whole name.
    public static let fallbackName = "lyte-transfer"
    /// Sanitized-name byte ceiling: room under common 255-byte
    /// filesystem limits for the collision suffix and the staging
    /// machinery.
    public static let maxNameByteCount = 200

    /// Path separators dropped (only the final component survives),
    /// control bytes removed, leading dots stripped (no dotfiles —
    /// nothing lands invisible or overrides shell config), trailing
    /// dots/spaces trimmed, empty → the fallback, overlong truncated
    /// on a character boundary with the extension preserved.
    public static func sanitized(_ offered: String) -> String {
        var name = offered
        // Only the final path component: "../../etc/passwd" → "passwd",
        // and a trailing "…/.ssh" meets the dot-stripping below.
        if let separator = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: separator)...])
        }
        // Control bytes (NUL, escapes, DEL) have no place in a name.
        name = String(String.UnicodeScalarView(
            name.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        ))
        while let first = name.first, first == "." || first == " " {
            name.removeFirst()
        }
        while let last = name.last, last == "." || last == " " {
            name.removeLast()
        }
        if name.isEmpty { return fallbackName }
        if name.utf8.count > maxNameByteCount {
            let (stem, ext) = splitExtension(name)
            var kept = ext.utf8.count <= 16 ? ext : ""
            var truncated = ext.utf8.count <= 16 ? stem : name
            while truncated.utf8.count + kept.utf8.count > maxNameByteCount {
                if truncated.isEmpty {
                    kept = ""
                    truncated = String(name.prefix(1))
                    break
                }
                truncated.removeLast()
            }
            name = truncated + kept
            while let last = name.last, last == "." || last == " " {
                name.removeLast()
            }
            if name.isEmpty { return fallbackName }
        }
        return name
    }

    /// Numbers around whatever already owns the name:
    /// "photo.png" → "photo (1).png" → "photo (2).png"…
    public static func collisionFree(
        _ name: String, exists: (String) -> Bool
    ) -> String {
        guard exists(name) else { return name }
        let (stem, ext) = splitExtension(name)
        var counter = 1
        var candidate = "\(stem) (\(counter))\(ext)"
        while exists(candidate) && counter < 10_000 {
            counter += 1
            candidate = "\(stem) (\(counter))\(ext)"
        }
        return candidate
    }

    /// "archive.tar.gz" → ("archive.tar", ".gz"); a leading dot is
    /// never an extension (sanitized names cannot start with one
    /// anyway).
    static func splitExtension(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex
        else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }
}

// MARK: - Resume-state persistence format

/// `BulkResumeState` as bytes — the `.resume` file beside the staging
/// file. Fixed-layout little-endian in the house codec style; frozen
/// by roundtrip pins in the gate tests. A torn write decodes loud and
/// the loader treats it as weather (the state is our own cache — the
/// cost of losing it is re-receiving chunks, arbitrated by the digest
/// either way).
///
///   magic "LBR1" ‖ transferId u64 ‖ totalByteCount u64 ‖
///   chunkByteCount u32 ‖ sha256 32 B ‖ contiguousCount u64 ‖
///   extrasCount u32 ‖ extras u64[] (ascending) ‖ nameLen u16 ‖ name
public enum BulkResumeStateCodec {
    public static let magic: [UInt8] = [0x4C, 0x42, 0x52, 0x31] // LBR1

    public enum CodecError: Error, Equatable, Sendable {
        case truncated
        case badMagic
        case invalidName
        case trailingBytes
    }

    public static func encode(_ state: BulkResumeState) -> [UInt8] {
        var out = magic
        appendLE(state.transferId, to: &out)
        appendLE(state.totalByteCount, to: &out)
        appendLE(state.chunkByteCount, to: &out)
        out += state.sha256
        appendLE(state.possession.contiguousCount, to: &out)
        let extras = state.possession.extras.sorted()
        appendLE(UInt32(extras.count), to: &out)
        for extra in extras { appendLE(extra, to: &out) }
        let nameBytes = Array(state.name.utf8)
        appendLE(UInt16(nameBytes.count), to: &out)
        out += nameBytes
        return out
    }

    public static func decode(_ bytes: [UInt8]) throws -> BulkResumeState {
        var cursor = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard bytes.count - cursor >= count else {
                throw CodecError.truncated
            }
            defer { cursor += count }
            return bytes[cursor..<cursor + count]
        }
        guard Array(try take(4)) == magic else { throw CodecError.badMagic }
        let transferId: UInt64 = readLE(try take(8))
        let totalByteCount: UInt64 = readLE(try take(8))
        let chunkByteCount: UInt32 = readLE(try take(4))
        let sha256 = Array(try take(32))
        let contiguousCount: UInt64 = readLE(try take(8))
        let extrasCount: UInt32 = readLE(try take(4))
        var extras = Set<UInt64>()
        for _ in 0..<extrasCount {
            extras.insert(readLE(try take(8)))
        }
        let nameLen: UInt16 = readLE(try take(2))
        let nameBytes = Array(try take(Int(nameLen)))
        guard cursor == bytes.count else { throw CodecError.trailingBytes }
        guard let name = String(bytes: nameBytes, encoding: nil)
        else { throw CodecError.invalidName }
        return BulkResumeState(
            transferId: transferId,
            totalByteCount: totalByteCount,
            chunkByteCount: chunkByteCount,
            sha256: sha256,
            name: name,
            possession: BulkPossession(
                contiguousCount: contiguousCount, extras: extras
            )
        )
    }

    private static func appendLE<T: FixedWidthInteger>(
        _ value: T, to out: inout [UInt8]
    ) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
    }

    private static func readLE<T: FixedWidthInteger>(
        _ slice: ArraySlice<UInt8>
    ) -> T {
        var value: T = 0
        for (index, byte) in slice.enumerated() {
            value |= T(byte) << (8 * index)
        }
        return value
    }
}

/// Foundation-free strict UTF-8 decode (HostWire keeps Wire's
/// no-Foundation spirit; `String(bytes:encoding:)` is Foundation's).
private extension String {
    init?(bytes: [UInt8], encoding: Void?) {
        var text = ""
        text.reserveCapacity(bytes.count)
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        loop: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                text.unicodeScalars.append(scalar)
            case .emptyInput:
                break loop
            case .error:
                return nil
            }
        }
        self = text
    }
}
