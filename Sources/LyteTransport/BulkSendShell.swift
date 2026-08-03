// BulkSendShell (F-4): the client's driver for ONE bulk transfer —
// the shell around LyteWire's sans-IO `BulkSendEngine` (W10, design
// record docs/20260728-053300-lyte-bulk-channel.md §7/§9). The engine
// has no timers and no IO; this shell answers its actions:
//
//   `.emit`      → the injected send closure (the session core's
//                  chan-8 ARQ ordered stream — never CTRL, so a file
//                  cannot head-of-line-block a keystroke);
//   `.readChunk` → the injected chunk reader (production: a FileHandle
//                  on a serial utility queue — file IO never touches
//                  the main thread; tests: a payload-backed synchronous
//                  reader in virtual time), whose result comes back
//                  through `supplyChunk`;
//
// and feeds decoded chan-8 messages to `ingest`. One shell = one
// transfer = one session leg: on session teardown the shell is
// discarded with the ARQ state (resume is the COORDINATOR's job — it
// re-offers the same id into a fresh shell, per design §5).
//
// Threading: engine access is lock-serialized; actions execute OUTSIDE
// the lock (a synchronous test reader's completion re-enters
// `supplyChunk` legally). Reads the engine issues are credit-bounded
// (design §4), so the re-entry depth is bounded by the window.

import Foundation
import LyteCore
import LyteWire
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// MARK: - Progress arithmetic

/// Bytes-confirmed-vs-total, computed from the engine's view of the
/// RECEIVER's possession (its acks, merged monotonically) — never from
/// what this end merely sent. Pinned in virtual time (F-4 tests).
public struct BulkTransferProgress: Equatable, Sendable {
    public var totalByteCount: UInt64
    public var confirmedByteCount: UInt64

    public var fraction: Double {
        guard totalByteCount > 0 else { return 0 }
        return Double(confirmedByteCount) / Double(totalByteCount)
    }

    /// The exact byte count a possession map represents against an
    /// offer's geometry: full chunks are `chunkByteCount`, the LAST
    /// chunk is the remainder (never zero — the offer codec's rule).
    public static func confirmedByteCount(
        possession: BulkPossession, offer: BulkOffer
    ) -> UInt64 {
        var bytes: UInt64 = 0
        let chunk = UInt64(offer.chunkByteCount)
        let chunkCount = offer.chunkCount
        let contiguous = min(possession.contiguousCount, chunkCount)
        if contiguous > 0 {
            bytes = (contiguous - 1) * chunk
                + UInt64(offer.byteCount(ofChunk: contiguous - 1) ?? 0)
        }
        for extra in possession.extras where extra < chunkCount
            && extra >= contiguous {
            bytes += UInt64(offer.byteCount(ofChunk: extra) ?? 0)
        }
        return bytes
    }

    public static func measuring(
        possession: BulkPossession, offer: BulkOffer
    ) -> BulkTransferProgress {
        BulkTransferProgress(
            totalByteCount: offer.totalByteCount,
            confirmedByteCount: confirmedByteCount(
                possession: possession, offer: offer))
    }
}

// MARK: - The chunk-reading seam

/// One transfer's chunk source. Production is `BulkFileChunkReader`
/// (async, serial queue); tests inject a synchronous payload-backed
/// reader so the whole transfer runs in virtual time.
public protocol BulkChunkReading: Sendable {
    /// Reads exactly `byteCount` bytes at `offset`; the completion may
    /// fire on any thread (or synchronously). Short reads are errors —
    /// the offer promised those bytes.
    func read(
        offset: UInt64, byteCount: Int,
        completion: @escaping @Sendable (Result<[UInt8], Error>) -> Void
    )
    /// The transfer ended (any way) — release the file handle.
    func close()
}

public enum BulkChunkReadError: Error, Equatable, Sendable {
    /// The file ended before the offer's geometry said it would (it
    /// changed or vanished under the transfer).
    case shortRead(offset: UInt64, wanted: Int, got: Int)
}

/// The production reader: one FileHandle, all IO on a shared serial
/// utility queue — never the main thread, never the receive thread.
public final class BulkFileChunkReader: BulkChunkReading, @unchecked Sendable {
    /// One queue for all transfers: v1 runs one transfer at a time by
    /// design (§6), so contention is structural zero.
    private static let queue = DispatchQueue(
        label: "lyte.bulk.file-read", qos: .utility)

    private let handle: FileHandle

    public init(url: URL) throws {
        self.handle = try FileHandle(forReadingFrom: url)
    }

    public func read(
        offset: UInt64, byteCount: Int,
        completion: @escaping @Sendable (Result<[UInt8], Error>) -> Void
    ) {
        let handle = handle
        Self.queue.async {
            do {
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: byteCount) ?? Data()
                guard data.count == byteCount else {
                    throw BulkChunkReadError.shortRead(
                        offset: offset, wanted: byteCount, got: data.count)
                }
                completion(.success(Array(data)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func close() {
        let handle = handle
        Self.queue.async { try? handle.close() }
    }
}

// MARK: - Offer preparation

public enum BulkPrepareError: Error, Equatable, Sendable {
    /// v1 does not transfer empty blobs (the offer codec's rule,
    /// surfaced before a byte of hashing is spent).
    case emptyFile
    case unreadable(String)
}

/// Builds the offer a dropped file rides under: size and streaming
/// SHA-256 computed up front (the digest IS the completion contract —
/// design §0), name from the URL's last component (truncated to the
/// 255-byte wire bound on a UTF-8 character boundary), MIME hint from
/// the path extension. Blocking — callers run it off the main thread
/// (the coordinator's background executor).
public enum BulkFilePreparer {
    /// Hash/size read granularity. 256 KiB keeps the syscall count low
    /// without staging a whole file.
    public static let readBlockByteCount = 262_144

    public static func prepare(
        url: URL, transferId: UInt64, chunkByteCount: UInt32
    ) throws -> BulkOffer {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw BulkPrepareError.unreadable(String(describing: error))
        }
        defer { try? handle.close() }

        // Size is counted as read, not asked of attributes — the bytes
        // hashed are exactly the bytes the offer promises.
        var hasher = Sha256()
        var totalByteCount: UInt64 = 0
        do {
            while let block = try handle.read(
                upToCount: readBlockByteCount
            ), !block.isEmpty {
                hasher.update(block)
                totalByteCount += UInt64(block.count)
            }
        } catch {
            throw BulkPrepareError.unreadable(String(describing: error))
        }
        guard totalByteCount >= 1 else { throw BulkPrepareError.emptyFile }

        return try BulkOffer(
            transferId: transferId,
            totalByteCount: totalByteCount,
            chunkByteCount: chunkByteCount,
            sha256: hasher.finalized(),
            name: wireName(for: url),
            mimeHint: mimeHint(for: url)
        )
    }

    /// The offer's name field: the file's display name, truncated to
    /// the 255-UTF-8-byte wire bound on a character boundary (the
    /// codec refuses more; sanitization beyond that is the RECEIVER
    /// end's job — design §3).
    public static func wireName(for url: URL) -> String {
        var name = url.lastPathComponent
        if name.isEmpty { name = "file" }
        while name.utf8.count > BulkWire.maxNameByteCount {
            name.removeLast()
        }
        return name.isEmpty ? "file" : name
    }

    /// The optional MIME hint, from the path extension via
    /// UniformTypeIdentifiers; empty when the system knows nothing.
    public static func mimeHint(for url: URL) -> String {
        #if canImport(UniformTypeIdentifiers)
        let ext = url.pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              let mime = type.preferredMIMEType,
              mime.utf8.count <= BulkWire.maxMimeHintByteCount
        else { return "" }
        return mime
        #else
        return ""
        #endif
    }
}

// MARK: - The shell

/// Everything one transfer's driving loop surfaces to its owner (the
/// coordinator). Fired from whatever thread drove the engine — the
/// receive thread (acks), the read queue (chunk supplies), or the
/// caller (begin/cancel).
public enum BulkSendShellEvent: Sendable {
    /// The receiver's possession advanced (or the transfer state
    /// moved) — re-read `progress`/`state`.
    case progressChanged
    /// The receiver verified the digest: the file LANDED, sha-exact.
    case completed
    /// Terminal failure; `byRemote` says whose abort it was.
    case aborted(BulkAbortReason, byRemote: Bool)
    /// A local read failed (the file changed or vanished under the
    /// transfer). An abort(cancelled) already left for the peer; this
    /// carries the local why.
    case readFailed(String)
    /// The peer broke the bulk state machine (precedes its abort).
    case violated(BulkTransferViolation)
}

public final class BulkSendShell: @unchecked Sendable {
    public let offer: BulkOffer

    private let lock = NSLock()
    private var engine: BulkSendEngine
    private let reader: any BulkChunkReading
    private let send: @Sendable ([UInt8]) -> Void
    private let onEvent: @Sendable (BulkSendShellEvent) -> Void
    private var readerClosed = false

    public init(
        offer: BulkOffer,
        reader: any BulkChunkReading,
        send: @escaping @Sendable ([UInt8]) -> Void,
        onEvent: @escaping @Sendable (BulkSendShellEvent) -> Void
    ) {
        self.offer = offer
        self.engine = BulkSendEngine(offer: offer)
        self.reader = reader
        self.send = send
        self.onEvent = onEvent
    }

    public var state: BulkSendEngine.State {
        lock.lock()
        defer { lock.unlock() }
        return engine.state
    }

    public var progress: BulkTransferProgress {
        lock.lock()
        defer { lock.unlock() }
        return .measuring(possession: engine.remoteHeld, offer: offer)
    }

    /// Emits the offer. Once per shell (the engine throws on a second
    /// begin — a coordinator bug, kept loud).
    public func begin() throws {
        lock.lock()
        let actions: [BulkSendEngine.Action]
        do {
            actions = try engine.begin()
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        perform(actions)
    }

    /// One decoded chan-8 message from the session (accept/ack/
    /// complete/abort — the engine treats anything else as the peer's
    /// violation). Never throws.
    public func ingest(_ message: BulkMessage) {
        lock.lock()
        let heldBefore = engine.remoteHeld.heldChunkCount
        let stateBefore = engine.state
        let actions = engine.ingest(message)
        let progressed = engine.remoteHeld.heldChunkCount != heldBefore
            || engine.state != stateBefore
        lock.unlock()
        if progressed {
            onEvent(.progressChanged)
        }
        perform(actions)
    }

    /// The human's ×: emits abort(cancelled) while in flight, terminal
    /// either way.
    public func cancel() {
        lock.lock()
        let actions = engine.cancel()
        lock.unlock()
        perform(actions)
    }

    // MARK: interior

    private func perform(_ actions: [BulkSendEngine.Action]) {
        for action in actions {
            switch action {
            case .emit(let message):
                send(message.encode())
            case .readChunk(let index):
                requestRead(index: index)
            case .completed:
                closeReader()
                onEvent(.completed)
            case .aborted(let reason, let byRemote):
                closeReader()
                onEvent(.aborted(reason, byRemote: byRemote))
            case .violated(let violation):
                onEvent(.violated(violation))
            }
        }
    }

    private func requestRead(index: UInt64) {
        let offset = index * UInt64(offer.chunkByteCount)
        let byteCount = offer.byteCount(ofChunk: index) ?? 0
        reader.read(offset: offset, byteCount: byteCount) {
            [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                self.lock.lock()
                let actions = (try? self.engine.supplyChunk(
                    index: index, data: data)) ?? []
                self.lock.unlock()
                self.perform(actions)
            case .failure(let error):
                // The wire has no sender-side read-failure reason; the
                // honest terminal is a cancel with the local why kept
                // loud (design §3's pinned reason space).
                self.lock.lock()
                let terminal = self.engine.isTerminal
                let actions = terminal ? [] : self.engine.cancel()
                self.lock.unlock()
                if !terminal {
                    // Surface the why FIRST, then the abort the cancel
                    // path emits (the coordinator maps this pair to
                    // one user-facing failure, not a cancel).
                    self.onEvent(.readFailed(String(describing: error)))
                }
                self.perform(actions)
            }
        }
    }

    private func closeReader() {
        lock.lock()
        let alreadyClosed = readerClosed
        readerClosed = true
        lock.unlock()
        if !alreadyClosed { reader.close() }
    }

    /// Session-teardown path (the coordinator's): release the file
    /// handle WITHOUT emitting an abort — there is nobody left to send
    /// one to, and the transfer itself lives on in the coordinator's
    /// resume entry.
    func closeReaderForTeardown() {
        closeReader()
    }
}
