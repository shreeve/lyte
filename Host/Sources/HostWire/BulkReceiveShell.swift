// BulkReceiveShell: the host's receiving end of file transfer. It drives
// Wire's sans-IO BulkReceiveEngine (which owns every protocol decision)
// with real disk verdicts, answering its actions:
//
//   • `.offered`  → consent is the standing per-host toggle (the shell
//     exists only when --accept-files armed it). The shell judges the
//     DISK: an offer whose remainder exceeds free space draws
//     abort(storageFailure), not declined.
//   • `.store`    → a durable write (pwrite + fsync) into the hidden
//     staging file, THEN `chunkStored` — fsync-before-ack, so persisted
//     possession never claims a byte the disk could still lose.
//   • `.verify`   → a streaming SHA-256 of the staging file.
//   • `.completed`→ fsync-then-rename into the destination directory
//     under a sanitized, collision-numbered name; kill -9 mid-transfer
//     leaves only the dotted staging file.
//
// One transfer at a time: a second concurrent offer draws abort(busy)
// here, unseen by the engine, and a terminal engine is re-armed fresh
// with the shell's resume book. `teardown()` persists the mid-flight
// BulkResumeState beside the staging file and construction loads every
// persisted state back, so a torn session resumes sha-exact from the gap.
//
// Threading is the caller's concern; file IO lives behind the
// BulkReceiveStore seam so failure paths are testable.

import LyteWire

/// What the shell needs from the disk. One production conformance
/// (HostIO's `BulkFileStore`, POSIX); tests wrap it to inject failures.
public protocol BulkReceiveStore: AnyObject {
    /// Absolute destination directory (for events and logs).
    var directoryPath: String { get }
    /// Open (creating if absent) the transfer's staging file. The
    /// staging file is dotted — invisible in the drop directory.
    func openStaging(transferId: UInt64) throws
    /// Write `data` at `byteOffset`, DURABLE (fsynced) on return.
    func writeChunkDurably(
        _ data: [UInt8], atByteOffset byteOffset: UInt64
    ) throws
    /// Streaming SHA-256 of the whole staging file.
    func stagingDigest() throws -> [UInt8]
    /// fsync, close, and atomically rename the staging file to `name`
    /// in the destination directory (plus a directory fsync, so the
    /// rename itself is durable).
    func promoteStaging(toName name: String) throws
    func removeStaging(transferId: UInt64)
    /// Close the staging descriptor without removing the file.
    func closeStaging()
    /// True when `name` already exists in the destination directory.
    func finalNameExists(_ name: String) -> Bool
    /// Free bytes on the destination filesystem; nil when the OS
    /// cannot say (the shell then accepts and lets writes speak).
    func freeDiskSpaceByteCount() -> UInt64?
    func loadResumeStates() -> [BulkResumeState]
    /// Persist one resume state beside its staging file, atomically.
    func persistResumeState(_ state: BulkResumeState) throws
    func removeResumeState(transferId: UInt64)
}

/// `.send` moves bytes (the loop feeds it to `Session.sendBulk`); the
/// rest is evidence for logs and tests. Payload bytes never appear here.
public enum BulkReceiveShellEvent: Equatable, Sendable {
    /// Put this message on chan 8's ordered stream.
    case send(BulkMessage)
    /// Consent granted (the toggle stands); the accept is in flight.
    case offerAccepted(
        transferId: UInt64, name: String, byteCount: UInt64,
        resuming: Bool
    )
    /// A second concurrent offer drew abort(busy), engine untouched.
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

    public var state: BulkReceiveEngine.State { engine.state }

    /// True while an offer/transfer is mid-flight — the busy gate.
    public var isTransferActive: Bool {
        switch engine.state {
        case .offered, .receiving, .verifying: return true
        case .awaitingOffer, .completed, .aborted: return false
        }
    }

    /// One decoded chan-8 message into the engine, every resulting
    /// action answered synchronously. Never throws: remote badness is
    /// the engine's violation path, disk badness the storage-failure
    /// path, and a second concurrent offer is answered abort(busy) here.
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

    /// A human at the host cancelled.
    public func cancel() -> [BulkReceiveShellEvent] {
        pump(engine.cancel())
    }

    /// The session is going down: persist the mid-flight resume state
    /// and release the descriptor. Idempotent.
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
        // Refuse an offer the filesystem cannot hold; a resume is only
        // charged for its gap.
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
        switch promote(offer) {
        case .success(let finalName):
            store.removeResumeState(transferId: offer.transferId)
            book.removeAll { $0.transferId == offer.transferId }
            counters.filesCompleted += 1
            events.append(.fileCompleted(
                name: finalName,
                path: store.directoryPath + "/\(finalName)",
                byteCount: offer.totalByteCount
            ))
        case .failure(let failure):
            // Verified and complete on the wire, but the promotion
            // failed — loud, staging kept (the bytes are sha-good).
            counters.storageFailures += 1
            events.append(.storageFailure("promote: \(failure.detail)"))
        }
        rearm()
        return events
    }

    private struct PromotionFailure: Error {
        let detail: String
    }

    /// The offer's name is UNTRUSTED input: sanitized (path separators,
    /// dotfiles, control bytes), then numbered around whatever owns it.
    /// The store never replaces an existing file, so a name taken after
    /// the check (another writer, or one the client planted) fails the
    /// promotion and the next number is tried on the reopened staging
    /// file. Past the last number the promotion fails; it never lands
    /// on a taken name.
    private func promote(_ offer: BulkOffer) -> Result<String, PromotionFailure> {
        for candidate in BulkFileNaming.candidates(
            BulkFileNaming.sanitized(offer.name)
        ) where !store.finalNameExists(candidate) {
            do {
                try store.promoteStaging(toName: candidate)
                return .success(candidate)
            } catch {
                guard store.finalNameExists(candidate) else {
                    return .failure(PromotionFailure(detail: "\(error)"))
                }
            }
            do {
                try store.openStaging(transferId: offer.transferId)
            } catch {
                return .failure(PromotionFailure(detail: "reopen: \(error)"))
            }
        }
        return .failure(PromotionFailure(detail: "no free name"))
    }

    private func cleanUpAborted(
        reason: BulkAbortReason, byRemote: Bool
    ) -> [BulkReceiveShellEvent] {
        counters.transfersAborted += 1
        let transferId = engine.offer?.transferId
        store.closeStaging()
        switch reason {
        case .storageFailure, .resumeMismatch:
            // Persisted possession stays honest for a future re-offer:
            // keep the staging file exactly when a resume book entry
            // vouches for it; a fresh transfer's orphan is removed.
            if let transferId,
               !book.contains(where: { $0.transferId == transferId }) {
                store.removeStaging(transferId: transferId)
            }
        default:
            // The partial has no future — no strays in the drop dir.
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
    /// still vouches for (excluding the failed chunk), then let the
    /// engine abort with storageFailure.
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
    /// exact, since every chunk but the last is chunkByteCount.
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

/// The offer's name is hostile input; the receiver sanitizes it.
public enum BulkFileNaming {
    /// The fallback when sanitization consumes the whole name.
    public static let fallbackName = "lyte-transfer"
    /// Sanitized-name byte ceiling: room under common 255-byte
    /// filesystem limits for the collision suffix and the staging
    /// machinery.
    public static let maxNameByteCount = 200

    /// Path separators dropped (only the final component survives),
    /// control and format characters removed (C0, DEL, C1, the bidi
    /// overrides and isolates that let "invoice\u{202E}fdp.exe" display
    /// as "invoiceexe.pdf", line and paragraph separators), leading dots,
    /// spaces and combining marks stripped (no dotfiles — nothing lands
    /// invisible or overrides shell config), trailing dots/spaces
    /// trimmed, empty → the fallback, overlong truncated on a character
    /// boundary with the extension preserved (a stem truncated away
    /// becomes the fallback).
    ///
    /// Every test is per Unicode scalar, never per Character: "/" or "."
    /// followed by a combining mark is one Character that compares unequal
    /// to "/" or ".", yet its UTF-8 still carries the 0x2F or 0x2E byte
    /// the filesystem acts on.
    public static func sanitized(_ offered: String) -> String {
        var scalars = Array(offered.unicodeScalars)
        // Only the final path component: "../../etc/passwd" → "passwd",
        // and a trailing "…/.ssh" meets the dot-stripping below.
        if let separator = scalars.lastIndex(where: isPathSeparator) {
            scalars.removeSubrange(...separator)
        }
        scalars.removeAll(where: isHiddenControl)
        scalars.removeFirst(scalars.prefix(while: isLeadingJunk).count)
        var name = trimmingTrailingDotsAndSpaces(scalars)
        if name.isEmpty { return fallbackName }
        if name.utf8.count > maxNameByteCount {
            var (stem, ext) = splitExtension(name)
            if ext.utf8.count > 16 { (stem, ext) = (name, "") }
            while !stem.isEmpty,
                  stem.utf8.count + ext.utf8.count > maxNameByteCount {
                stem.removeLast()
            }
            // The stem's first Character survives unless truncation
            // consumed it whole; a bare extension would be a dotfile.
            stem = trimmingTrailingDotsAndSpaces(Array(stem.unicodeScalars))
            name = (stem.isEmpty ? fallbackName : stem) + ext
        }
        return name
    }

    private static func isPathSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "/" || scalar == "\\"
    }

    /// A dot, a space, or a mark left with nothing to combine with once
    /// the dots before it are gone.
    private static func isLeadingJunk(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "." || scalar == " " { return true }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private static func trimmingTrailingDotsAndSpaces(
        _ scalars: [Unicode.Scalar]
    ) -> String {
        var scalars = scalars
        while let last = scalars.last, last == "." || last == " " {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Scalars that have no place in a displayed file name: controls
    /// (C0, DEL, C1), bidi embeddings, overrides, isolates and marks, the
    /// line and paragraph separators, and the zero-width and invisible
    /// format characters (which could otherwise hide a leading dot).
    private static func isHiddenControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: return true
        case 0x061C, 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2064,
             0x2066...0x2069, 0xFEFF:
            return true
        default: return false
        }
    }

    /// The highest collision number tried before a promotion fails.
    public static let maxCollisionNumber = 9_999

    /// Every name a file may land under, in preference order: "photo.png",
    /// then "photo (1).png" … "photo (9999).png".
    public static func candidates(_ name: String) -> some Sequence<String> {
        let (stem, ext) = splitExtension(name)
        return (0...maxCollisionNumber).lazy.map {
            $0 == 0 ? name : "\(stem) (\($0))\(ext)"
        }
    }

    /// The first candidate `exists` does not claim; nil once every
    /// number is taken.
    public static func collisionFree(
        _ name: String, exists: (String) -> Bool
    ) -> String? {
        candidates(name).first { !exists($0) }
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
/// file, fixed-layout little-endian. A torn write decodes loud and the
/// loader skips it: losing this cache only costs re-received chunks.
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

/// Foundation-free strict UTF-8 decode (HostWire is sans-Foundation).
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
