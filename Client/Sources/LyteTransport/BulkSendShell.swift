// BulkSendShell: drives one bulk transfer for one session leg around
// LyteWire's sans-IO `BulkSendEngine`: `.emit` goes to the injected chan-8
// send, `.readChunk` to the injected chunk reader, and decoded chan-8
// messages come in through `ingest`. Resume is the coordinator's job.
//
// Engine access is lock-serialized; actions execute outside the lock (a
// synchronous reader re-enters `supplyChunk`, bounded by the credit window).

import Foundation
import LyteCore
import LyteWire
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// MARK: - Progress arithmetic

/// Bytes confirmed by the receiver's acks, never merely sent, vs total.
public struct BulkTransferProgress: Equatable, Sendable {
    public var totalByteCount: UInt64
    public var confirmedByteCount: UInt64

    public var fraction: Double {
        guard totalByteCount > 0 else { return 0 }
        return Double(confirmedByteCount) / Double(totalByteCount)
    }

    /// The exact byte count a possession map represents (the last chunk
    /// is the remainder).
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

/// One transfer's chunk source.
public protocol BulkChunkReading: Sendable {
    /// Reads exactly `byteCount` bytes at `offset`; the completion may
    /// fire on any thread or synchronously. Short reads are errors.
    func read(
        offset: UInt64, byteCount: Int,
        completion: @escaping @Sendable (Result<[UInt8], Error>) -> Void
    )
    /// The transfer ended (any way) — release the file handle.
    func close()
}

public enum BulkChunkReadError: Error, Equatable, Sendable {
    /// The file changed or vanished under the transfer.
    case shortRead(offset: UInt64, wanted: Int, got: Int)
}

/// One FileHandle; all IO on a shared serial utility queue.
public final class BulkFileChunkReader: BulkChunkReading, @unchecked Sendable {
    /// Shared: transfers run one at a time.
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
    /// The offer codec refuses empty blobs.
    case emptyFile
    case unreadable(String)
}

/// Builds a dropped file's offer: size and streaming SHA-256 up front (the
/// digest is the completion contract), wire name, and MIME hint. Blocking.
public enum BulkFilePreparer {
    /// Hash/size read granularity.
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

        // Size is counted as read so it matches the bytes hashed.
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

    /// The file name truncated to the wire bound on a character
    /// boundary; sanitization is the receiver's job.
    public static func wireName(for url: URL) -> String {
        var name = url.lastPathComponent
        if name.isEmpty { name = "file" }
        while name.utf8.count > BulkWire.maxNameByteCount {
            name.removeLast()
        }
        return name.isEmpty ? "file" : name
    }

    /// From the path extension; empty when unknown.
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

/// Fired from whatever thread drove the engine.
public enum BulkSendShellEvent: Sendable {
    /// Re-read `progress`/`state`.
    case progressChanged
    /// The receiver verified the digest.
    case completed
    /// Terminal failure; `byRemote` says whose abort it was.
    case aborted(BulkAbortReason, byRemote: Bool)
    /// A local read failed; abort(cancelled) already left for the peer.
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

    /// Emits the offer; throws on a second begin.
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

    /// Emits abort(cancelled) while in flight; terminal either way.
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
            // A chunk the engine refuses (the file changed size since the
            // offer) is a read failure too: the transfer cannot continue.
            self.lock.lock()
            let error: any Error
            do {
                let actions = try self.engine.supplyChunk(
                    index: index, data: result.get())
                self.lock.unlock()
                return self.perform(actions)
            } catch let failure {
                error = failure
            }
            // The wire has no read-failure reason: cancel, keeping the
            // local why.
            let terminal = self.engine.isTerminal
            let actions = terminal ? [] : self.engine.cancel()
            self.lock.unlock()
            if !terminal {
                // The why precedes the abort, so the coordinator reports
                // one failure, not a cancel.
                self.onEvent(.readFailed(String(describing: error)))
            }
            self.perform(actions)
        }
    }

    /// Also the teardown release: the transfer lives on in the
    /// coordinator's resume entry.
    func closeReader() {
        lock.lock()
        let alreadyClosed = readerClosed
        readerClosed = true
        lock.unlock()
        if !alreadyClosed { reader.close() }
    }
}
