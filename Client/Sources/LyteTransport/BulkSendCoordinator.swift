// BulkSendCoordinator: everything above one transfer — the dropped-file
// queue, the capability gate, and resume-on-reconnect. It outlives the
// wire session: an interrupted entry keeps its transfer id and prepared
// offer and re-offers the same id into the next session, so the receiver
// resumes from the gap (docs/decisions/20260728-053300-lyte-bulk-channel.md).
//
// Drops queue and send serially (the wire refuses concurrency with
// abort(busy)); cancel stops the active transfer and clears the queue.
// Offers go out only when key 11 was agreed. `onChange`/`onNotice` fire
// on whatever thread drove the mutation; UI owners hop to the main actor.

import Foundation
import LyteCore
import LyteWire

/// What became of one drop, for immediate UI feedback.
public enum BulkDropVerdict: Equatable, Sendable {
    case accepted(count: Int)
    /// Key 11 never survived intersection.
    case hostNotAccepting
    /// No session is attached (dropped between sessions).
    case notConnected
}

/// The pill's whole picture, re-read on every `onChange`.
public struct BulkSendSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Hashing/sizing the file for its offer.
        case preparing
        /// Offer sent; the host's consent verdict pending.
        case offering
        /// Chunks flowing under credit.
        case transferring
        /// Every chunk confirmed; the host's digest verdict pending.
        case verifying
        /// Mid-transfer when the session dropped — re-offers on the
        /// next attach.
        case awaitingReconnect
    }

    /// Nil when no transfer is active.
    public var activeName: String?
    public var phase: Phase?
    public var progress: BulkTransferProgress?
    /// Entries waiting behind the active one.
    public var queuedCount: Int = 0

    public var isIdle: Bool { activeName == nil && queuedCount == 0 }

    public static let idle = BulkSendSnapshot()
}

public final class BulkSendCoordinator: @unchecked Sendable {
    /// Prepares one file's offer (blocking; runs on the background
    /// executor).
    public typealias Preparer = @Sendable (
        _ url: URL, _ transferId: UInt64, _ chunkByteCount: UInt32
    ) throws -> BulkOffer
    public typealias ReaderFactory = @Sendable (URL) throws -> any BulkChunkReading

    private struct Entry {
        var url: URL
        var displayName: String
        /// Minted once and reused on every re-offer: the resume identity.
        var transferId: UInt64?
        /// Kept across teardown so the re-offer is byte-identical.
        var offer: BulkOffer?
        /// One fresh-id retry after abort(resumeMismatch).
        var resumeMismatchRetried = false
    }

    private let lock = NSLock()
    private let chunkByteCount: UInt32
    private let prepare: Preparer
    private let makeReader: ReaderFactory
    private let runInBackground: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let mintId: @Sendable () -> UInt64
    private let onChange: @Sendable () -> Void
    private let onNotice: @Sendable (String) -> Void

    /// The session's chan-8 send leg; nil between sessions.
    private var sessionSend: (@Sendable ([UInt8]) -> Void)?
    /// Key 11 in the agreed set.
    private var negotiated = false

    private var entries = Deque<Entry>()
    private var shell: BulkSendShell?
    /// Bumped per shell so a discarded shell's late events never touch
    /// the current head.
    private var shellGeneration: UInt64 = 0
    /// True while the head entry is being prepared (hash in flight).
    private var preparing = false
    /// True when the head entry's transfer was interrupted by a
    /// session teardown and waits for the next attach.
    private var awaitingReconnect = false
    /// A read failure already explained the abort that follows.
    private var readFailureNoticed = false

    public init(
        chunkByteCount: UInt32 = UInt32(BulkWire.defaultChunkByteCount),
        prepare: @escaping Preparer = {
            try BulkFilePreparer.prepare(
                url: $0, transferId: $1, chunkByteCount: $2)
        },
        makeReader: @escaping ReaderFactory = {
            try BulkFileChunkReader(url: $0)
        },
        runInBackground: @escaping @Sendable (
            @escaping @Sendable () -> Void
        ) -> Void = { work in
            DispatchQueue.global(qos: .utility).async(execute: work)
        },
        mintId: @escaping @Sendable () -> UInt64 = {
            var generator = SystemRandomNumberGenerator()
            return BulkTransferId.mint(using: &generator)
        },
        onChange: @escaping @Sendable () -> Void = {},
        onNotice: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.chunkByteCount = chunkByteCount
        self.prepare = prepare
        self.makeReader = makeReader
        self.runInBackground = runInBackground
        self.mintId = mintId
        self.onChange = onChange
        self.onNotice = onNotice
    }

    // MARK: Session attachment

    /// Attaches a session after capability agreement; pending work
    /// starts or resumes here.
    public func sessionReady(
        negotiated: Bool,
        send: @escaping @Sendable ([UInt8]) -> Void
    ) {
        lock.lock()
        self.sessionSend = send
        self.negotiated = negotiated
        self.awaitingReconnect = false
        var refusedNames: [String] = []
        if !negotiated, !entries.isEmpty {
            // Pending work can never move on this session: fail it.
            refusedNames = entries.map(\.displayName)
            entries.removeAll()
        }
        lock.unlock()
        for name in refusedNames {
            onNotice("\(name) not sent — the host isn't accepting files")
        }
        advance()
        onChange()
    }

    /// The active entry stays at the head with its id and offer intact
    /// for the next `sessionReady` to re-offer.
    public func sessionEnded() {
        lock.lock()
        sessionSend = nil
        negotiated = false
        preparing = false
        if let active = shell {
            shell = nil
            if !entries.isEmpty {
                awaitingReconnect = true
            }
            active.closeReaderForTeardown()
        }
        lock.unlock()
        onChange()
    }

    /// Drops everything, including a pending resume: a file dropped for
    /// one host must never follow the user to another.
    public func abandonAll() {
        lock.lock()
        let active = shell
        shell = nil
        entries.removeAll()
        preparing = false
        awaitingReconnect = false
        lock.unlock()
        active?.cancel()
        onChange()
    }

    // MARK: Drops

    /// The verdict is immediate; preparation is async.
    public func drop(urls: [URL]) -> BulkDropVerdict {
        guard !urls.isEmpty else { return .accepted(count: 0) }
        lock.lock()
        guard sessionSend != nil else {
            lock.unlock()
            return .notConnected
        }
        guard negotiated else {
            lock.unlock()
            return .hostNotAccepting
        }
        for url in urls {
            entries.append(Entry(
                url: url,
                displayName: BulkFilePreparer.wireName(for: url)))
        }
        lock.unlock()
        advance()
        onChange()
        return .accepted(count: urls.count)
    }

    /// Cancels the active transfer and clears the queue.
    public func cancelAll() {
        lock.lock()
        let active = shell
        shell = nil
        let hadWork = active != nil || !entries.isEmpty
        entries.removeAll()
        preparing = false
        awaitingReconnect = false
        lock.unlock()
        active?.cancel()
        if hadWork {
            onNotice("File transfer cancelled")
        }
        onChange()
    }

    // MARK: Inbound

    /// Messages for no active transfer are dropped.
    public func ingest(_ message: BulkMessage) {
        lock.lock()
        let active = shell
        lock.unlock()
        guard let active, message.transferId == active.offer.transferId
        else { return }
        active.ingest(message)
    }

    // MARK: Snapshot

    public func snapshot() -> BulkSendSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var snap = BulkSendSnapshot()
        guard let head = entries.first else { return snap }
        if awaitingReconnect {
            snap.activeName = head.displayName
            snap.phase = .awaitingReconnect
            if let offer = head.offer {
                snap.progress = BulkTransferProgress(
                    totalByteCount: offer.totalByteCount,
                    confirmedByteCount: 0)
            }
            snap.queuedCount = max(0, entries.count - 1)
            return snap
        }
        if preparing {
            snap.activeName = head.displayName
            snap.phase = .preparing
            snap.queuedCount = max(0, entries.count - 1)
            return snap
        }
        guard let shell else {
            // Pending with no session.
            snap.activeName = head.displayName
            snap.phase = .awaitingReconnect
            snap.queuedCount = max(0, entries.count - 1)
            return snap
        }
        snap.activeName = head.displayName
        snap.progress = shell.progress
        snap.queuedCount = max(0, entries.count - 1)
        switch shell.state {
        case .idle, .offering:
            snap.phase = .offering
        case .transferring:
            snap.phase = .transferring
        case .awaitingVerification:
            snap.phase = .verifying
        case .completed, .aborted:
            snap.phase = nil
        }
        return snap
    }

    // MARK: Interior

    /// Starts or resumes the head entry when nothing is driving. Never
    /// called with the lock held: the injected executor may be synchronous.
    private func advance() {
        while true {
            lock.lock()
            guard shell == nil, !preparing, negotiated,
                  let send = sessionSend,
                  let head = entries.first
            else {
                lock.unlock()
                return
            }

            if let offer = head.offer {
                // Re-offer the same id: the resume match.
                let failedName = beginShellLocked(
                    entry: head, offer: offer, send: send)
                lock.unlock()
                guard let (name, error) = failedName else { return }
                onNotice("\(name) not sent — \(Self.describe(error))")
                onChange()
                continue   // the reader refused: try the next entry
            }

            preparing = true
            let url = head.url
            let transferId = head.transferId ?? mintId()
            entries[0].transferId = transferId
            lock.unlock()

            let chunkByteCount = chunkByteCount
            let prepare = prepare
            runInBackground { [weak self] in
                guard let self else { return }
                let prepared: Result<BulkOffer, Error> = Result {
                    try prepare(url, transferId, chunkByteCount)
                }
                self.finishPreparation(
                    transferId: transferId, prepared: prepared)
            }
            return
        }
    }

    private func finishPreparation(
        transferId: UInt64, prepared: Result<BulkOffer, Error>
    ) {
        lock.lock()
        preparing = false
        guard let current = entries.first,
              current.transferId == transferId
        else {
            // Cancelled/abandoned while hashing.
            lock.unlock()
            onChange()
            return
        }
        switch prepared {
        case .success(let offer):
            entries[0].offer = offer
            if !negotiated || sessionSend == nil {
                // The session died mid-hash.
                awaitingReconnect = true
                lock.unlock()
                onChange()
                return
            }
            lock.unlock()
            advance()
            onChange()
        case .failure(let error):
            let name = current.displayName
            entries.removeFirst()
            lock.unlock()
            onNotice("\(name) not sent — \(Self.describe(error))")
            advance()
            onChange()
        }
    }

    /// Caller holds the lock. Returns (name, error) when the reader
    /// refused to open; the entry is then already popped.
    private func beginShellLocked(
        entry: Entry, offer: BulkOffer,
        send: @escaping @Sendable ([UInt8]) -> Void
    ) -> (String, Error)? {
        let reader: any BulkChunkReading
        do {
            reader = try makeReader(entry.url)
        } catch {
            entries.removeFirst()
            return (entry.displayName, error)
        }
        readFailureNoticed = false
        shellGeneration += 1
        let generation = shellGeneration
        let name = entry.displayName
        let built = BulkSendShell(
            offer: offer,
            reader: reader,
            send: send,
            onEvent: { [weak self] event in
                self?.shellEvent(event, name: name, generation: generation)
            })
        shell = built
        // begin() throws only on a re-begin, and never re-enters our lock.
        try? built.begin()
        return nil
    }

    private func shellEvent(
        _ event: BulkSendShellEvent, name: String, generation: UInt64
    ) {
        // Discarded shells may still land late events; each locked
        // section re-checks the generation.
        switch event {
        case .progressChanged:
            lock.lock()
            let current = shell != nil && generation == shellGeneration
            lock.unlock()
            if current { onChange() }

        case .completed:
            lock.lock()
            guard shell != nil, generation == shellGeneration else {
                lock.unlock()
                return
            }
            shell = nil
            if !entries.isEmpty { entries.removeFirst() }
            lock.unlock()
            onNotice("\(name) sent")
            advance()
            onChange()

        case .readFailed(let why):
            lock.lock()
            guard shell != nil, generation == shellGeneration else {
                lock.unlock()
                return
            }
            readFailureNoticed = true
            lock.unlock()
            onNotice("\(name) not sent — read failed: \(why)")

        case .violated:
            // The abort that follows carries the user-facing verdict.
            break

        case .aborted(let reason, let byRemote):
            lock.lock()
            guard shell != nil, generation == shellGeneration else {
                lock.unlock()
                return
            }
            shell = nil
            var notice: String?
            if reason == .resumeMismatch, !entries.isEmpty,
               !entries[0].resumeMismatchRetried {
                // The file changed: retry once with a fresh id and hash.
                entries[0].transferId = nil
                entries[0].offer = nil
                entries[0].resumeMismatchRetried = true
                notice = "\(name) changed since the transfer began — restarting"
            } else {
                if !entries.isEmpty { entries.removeFirst() }
                let suppressed = readFailureNoticed
                readFailureNoticed = false
                if !suppressed {
                    switch (reason, byRemote) {
                    case (.cancelled, false):
                        // Local cancel: cancelAll already spoke.
                        notice = nil
                    case (.declined, _):
                        notice = "\(name) declined by the host"
                    case (.cancelled, true):
                        notice = "\(name) cancelled by the host"
                    case (.busy, _):
                        notice = "\(name) not sent — the host is busy with another transfer"
                    case (.shaMismatch, _):
                        notice = "\(name) failed verification — the file changed while sending"
                    case (.storageFailure, _):
                        notice = "\(name) not sent — the host couldn't store it"
                    default:
                        notice = "\(name) not sent — transfer aborted (\(reason))"
                    }
                }
            }
            lock.unlock()
            if let notice { onNotice(notice) }
            advance()
            onChange()
        }
    }

    private static func describe(_ error: Error) -> String {
        if case BulkPrepareError.emptyFile = error {
            return "the file is empty"
        }
        return String(describing: error)
    }
}
