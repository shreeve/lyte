import XCTest
import LyteClientTestKit
import Foundation
import LyteCore
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE GATE (F-4, the client half of drag-and-drop file transfer).
// Pinned behaviors:
//
//   • capability key 11 rides the W7 spine byte-equal to the host's
//     encoding (wireDefault + `0B F5`), survives intersection only on
//     mutual declaration, and the session core's DEFAULT config
//     declares it (dialect, not consent — the key-9/key-10 rule);
//   • the preparer turns a real temp file into its offer: streaming
//     SHA-256 equal to TestKit's reference digest, size counted as
//     read, name on the 255-byte wire bound (UTF-8 boundary), MIME
//     hint from the extension, empty files refused loudly;
//   • the shell drives BulkSendEngine in virtual time against a REAL
//     BulkReceiveEngine: happy path lands sha-exact with ascending
//     credit-gated reads, cancel mid-flight emits abort(cancelled)
//     and closes the reader, progress arithmetic is byte-exact
//     (remainder last chunk included);
//   • the coordinator's gates: offers ONLY when key 11 agreed
//     (.hostNotAccepting spoken, never silent), nothing without a
//     session (.notConnected);
//   • QUEUE POLICY (the documented F-4 ruling): multi-file drops
//     queue and send SERIALLY — one transfer at a time, v1's wire
//     shape; the × cancels the active transfer AND the queue;
//   • resume-on-reconnect: a session teardown mid-transfer keeps the
//     entry (id + prepared offer); the next attach re-offers the SAME
//     id, the accept's possession map resumes from the gap, only the
//     missing chunks are read/sent, and the finish is sha-exact;
//   • abort(resumeMismatch) draws the mandated recovery: ONE fresh-id
//     re-preparation, then the transfer completes under the new id;
//   • in vivo through the REAL session core against a scripted
//     key-11 host: chan 8 runs its OWN ArqEndpoint pair (never CTRL),
//     the offer leaves only after agreement, chunks reassemble
//     byte-exact host-side through real ARQ segmentation + Noise
//     sealing, and the rule-3 gate refuses bulk sends against a
//     no-key-11 host before a byte leaves.
//
// NOT here, deliberately: the live joint leg (real drag-and-drop
// Mac→host) waits on F-3's host end — the J-G3a-style joint gate.
// Drag/capture coexistence is structural (drag sessions ride
// NSDraggingDestination, never the NSEvent monitor mask CL-16's
// capture hit-tests) and is hand-verified at the joint gate.

final class BulkSendClientGateTests: XCTestCase {

    // MARK: Leg 1 — key 11 on the spine; the core default declares

    func testCapabilityKeyElevenOnTheSpineAndCoreDefaultDeclares() throws {
        let base = try Capabilities.wireDefault.encodeCbor()
        XCTAssertEqual(base.first, 0xA8)
        var expected = base
        expected[0] = 0xA9
        expected += [0x0B, 0xF5]
        let declared = Capabilities.wireDefault.declaringBulkTransfer()
        XCTAssertEqual(try declared.encodeCbor(), expected,
                       "key 11 = frozen wireDefault bytes + `0B F5`")

        XCTAssertTrue(declared.intersecting(declared).bulkTransfer)
        XCTAssertFalse(declared.intersecting(.wireDefault).bulkTransfer)
        XCTAssertFalse(
            Capabilities.wireDefault.intersecting(declared).bulkTransfer)

        // The session core's DEFAULT declaration carries key 11 beside
        // keys 9 and 10 — dialect, not consent: the HOST's standing
        // toggle decides whether IT declares, and the intersection
        // gates the client's offers.
        let defaults = LyteUdpSessionCoreConfig()
        XCTAssertTrue(defaults.capabilities.bulkTransfer)
        XCTAssertTrue(defaults.capabilities.clipboardText)
        XCTAssertTrue(defaults.capabilities.hostAudioRouting)
        print("F-4 gate (spine): declaration = frozen bytes + `0B F5`; "
            + "core default declares key 11")
    }

    // MARK: Leg 2 — the preparer against a real temp file

    func testPreparerBuildsOfferFromTempFile() throws {
        var rng = SplitMix64(seed: 0xF4_01)
        let payload = (0..<20_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("f4-prep-\(UUID().uuidString).txt")
        try Data(payload).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let offer = try BulkFilePreparer.prepare(
            url: url, transferId: 0xF4, chunkByteCount: 4_096)
        XCTAssertEqual(offer.transferId, 0xF4)
        XCTAssertEqual(offer.totalByteCount, 20_000)
        XCTAssertEqual(offer.chunkByteCount, 4_096)
        XCTAssertEqual(offer.chunkCount, 5)
        XCTAssertEqual(offer.byteCount(ofChunk: 4), 20_000 - 4 * 4_096,
                       "the last chunk is the remainder")
        XCTAssertEqual(offer.sha256, Sha256.digest(payload),
                       "streaming digest equals TestKit's reference")
        XCTAssertEqual(offer.name, url.lastPathComponent)
        XCTAssertEqual(offer.mimeHint, "text/plain")

        // Empty files refuse loudly — v1 does not transfer empty blobs.
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("f4-empty-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: empty.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertThrowsError(try BulkFilePreparer.prepare(
            url: empty, transferId: 1, chunkByteCount: 65_536)
        ) { error in
            XCTAssertEqual(error as? BulkPrepareError, .emptyFile)
        }

        // The name field's wire bound: truncated on a UTF-8 character
        // boundary, never empty, never over 255 bytes.
        let long = URL(fileURLWithPath:
            "/tmp/" + String(repeating: "é", count: 200) + ".txt")
        let name = BulkFilePreparer.wireName(for: long)
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        XCTAssertGreaterThan(name.utf8.count, 0)
        XCTAssertEqual(name, String(decoding: Array(name.utf8), as: UTF8.self),
                       "truncation kept a valid UTF-8 boundary")
        XCTAssertEqual(
            BulkFilePreparer.mimeHint(for: URL(fileURLWithPath: "/tmp/x")),
            "", "no extension — no hint")
        print("F-4 gate (preparer): sha/size/name/mime pinned from a "
            + "real temp file; empty refused")
    }

    // MARK: Leg 3 — progress arithmetic, byte-exact

    func testProgressArithmetic() throws {
        let offer = try BulkOffer(
            transferId: 7, totalByteCount: 10_000,
            chunkByteCount: 4_096,
            sha256: [UInt8](repeating: 0xAA, count: 32), name: "p")
        // Chunks: 4096, 4096, 1808.
        XCTAssertEqual(offer.chunkCount, 3)

        XCTAssertEqual(BulkTransferProgress.confirmedByteCount(
            possession: .empty, offer: offer), 0)
        XCTAssertEqual(BulkTransferProgress.confirmedByteCount(
            possession: BulkPossession(contiguousCount: 1), offer: offer),
            4_096)
        XCTAssertEqual(BulkTransferProgress.confirmedByteCount(
            possession: BulkPossession(contiguousCount: 1, extras: [2]),
            offer: offer), 4_096 + 1_808,
            "an out-of-prefix REMAINDER chunk counts its true size")
        XCTAssertEqual(BulkTransferProgress.confirmedByteCount(
            possession: BulkPossession(contiguousCount: 3), offer: offer),
            10_000)
        let done = BulkTransferProgress.measuring(
            possession: BulkPossession(contiguousCount: 3), offer: offer)
        XCTAssertEqual(done.fraction, 1.0)
        print("F-4 gate (progress): confirmed-bytes math pinned, "
            + "remainder chunk included")
    }

    // MARK: - The scripted far end (a REAL BulkReceiveEngine)

    /// The receiving role driven exactly like TestKit's harness:
    /// auto-consent, synchronous stores, honest digests of what was
    /// ACTUALLY stored.
    private final class ScriptedReceiver {
        var engine: BulkReceiveEngine
        var store: [UInt64: [UInt8]] = [:]
        /// receiver→sender messages awaiting delivery.
        var outbox: [BulkMessage] = []
        var offer: BulkOffer?
        var autoAccept = true

        init(window: Int, resumeBook: [BulkResumeState] = []) {
            engine = BulkReceiveEngine(
                config: BulkTransferConfig(receiveWindowChunks: window),
                resumeBook: resumeBook)
        }

        func absorb(_ bytes: [UInt8]) throws {
            try pump(engine.ingest(BulkMessage.decode(bytes)))
        }

        func pump(_ actions: [BulkReceiveEngine.Action]) throws {
            for action in actions {
                switch action {
                case .offered(let incoming, _):
                    offer = incoming
                    if autoAccept {
                        try pump(engine.accept())
                    } else {
                        try pump(engine.decline())
                    }
                case .emit(let message):
                    outbox.append(message)
                case .store(let index, let data):
                    store[index] = data
                    try pump(engine.chunkStored(index: index))
                case .verify:
                    try pump(engine.verificationResult(
                        digest: assembledDigest()))
                case .completed, .aborted, .violated:
                    break
                }
            }
        }

        func assembledDigest() -> [UInt8] {
            guard let offer else { return [] }
            var assembled: [UInt8] = []
            for index in 0..<offer.chunkCount {
                assembled += store[index] ?? []
            }
            return Sha256.digest(assembled)
        }
    }

    /// A synchronous payload-backed reader — the whole transfer runs
    /// in virtual time; reads and closes are recorded for the pins.
    private final class RecordingReader: BulkChunkReading, @unchecked Sendable {
        private let payload: [UInt8]
        private let lock = NSLock()
        private var recordedOffsets: [UInt64] = []
        private var closedFlag = false

        init(payload: [UInt8]) { self.payload = payload }

        var readOffsets: [UInt64] {
            lock.lock(); defer { lock.unlock() }
            return recordedOffsets
        }
        var closed: Bool {
            lock.lock(); defer { lock.unlock() }
            return closedFlag
        }

        func read(
            offset: UInt64, byteCount: Int,
            completion: @escaping @Sendable (Result<[UInt8], Error>) -> Void
        ) {
            lock.lock()
            recordedOffsets.append(offset)
            lock.unlock()
            let start = Int(offset)
            guard start + byteCount <= payload.count else {
                completion(.failure(BulkChunkReadError.shortRead(
                    offset: offset, wanted: byteCount,
                    got: max(0, payload.count - start))))
                return
            }
            completion(.success(Array(payload[start..<start + byteCount])))
        }

        func close() {
            lock.lock()
            closedFlag = true
            lock.unlock()
        }
    }

    /// Sender→receiver bytes in flight (the shell/coordinator's send
    /// closure appends; the pump drains).
    private final class WireBox: @unchecked Sendable {
        private let lock = NSLock()
        private var queued: [[UInt8]] = []
        private(set) var totalSent = 0

        var sendClosure: @Sendable ([UInt8]) -> Void {
            { [self] bytes in
                lock.lock()
                queued.append(bytes)
                totalSent += 1
                lock.unlock()
            }
        }

        func drain() -> [[UInt8]] {
            lock.lock(); defer { lock.unlock() }
            let out = queued
            queued.removeAll()
            return out
        }
    }

    /// Direct-pipe beats until both ends quiesce. `deliverLimit` caps
    /// how many sender messages the receiver ever SEES this session —
    /// the TestKit blackout model (in-order carriage means the
    /// receiver saw a prefix).
    private func settle(
        wire: WireBox,
        receiver: ScriptedReceiver,
        deliverLimit: Int? = nil,
        delivered: inout Int,
        toSender: (BulkMessage) -> Void
    ) throws {
        var progressed = true
        while progressed {
            progressed = false
            for bytes in wire.drain() {
                if let limit = deliverLimit, delivered >= limit {
                    continue   // lost to the blackout
                }
                delivered += 1
                try receiver.absorb(bytes)
                progressed = true
            }
            while !receiver.outbox.isEmpty {
                toSender(receiver.outbox.removeFirst())
                progressed = true
            }
        }
    }

    // MARK: Leg 4 — the shell's happy path, virtual time, sha-exact

    func testShellHappyPathLandsShaExact() throws {
        var rng = SplitMix64(seed: 0xF4_02)
        let payload = (0..<20_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let offer = try BulkOffer(
            transferId: 0xF4_02, totalByteCount: UInt64(payload.count),
            chunkByteCount: 4_096, sha256: Sha256.digest(payload),
            name: "happy.bin")
        let reader = RecordingReader(payload: payload)
        let wire = WireBox()
        let events = EventBox()
        let shell = BulkSendShell(
            offer: offer, reader: reader, send: wire.sendClosure,
            onEvent: { events.append($0) })

        let receiver = ScriptedReceiver(window: 4)
        try shell.begin()
        var delivered = 0
        try settle(wire: wire, receiver: receiver,
                   delivered: &delivered) { shell.ingest($0) }

        XCTAssertEqual(shell.state, .completed)
        XCTAssertTrue(events.contains { if case .completed = $0 { return true }; return false })
        XCTAssertEqual(receiver.assembledDigest(), offer.sha256,
                       "the file landed sha-exact")
        XCTAssertEqual(shell.progress.fraction, 1.0)
        XCTAssertEqual(shell.progress.confirmedByteCount, 20_000)
        // Reads were ascending and exactly one per chunk (credit-gated
        // dispatch never re-reads).
        XCTAssertEqual(reader.readOffsets,
                       (0..<5).map { UInt64($0) * 4_096 })
        XCTAssertTrue(reader.closed, "terminal releases the file handle")
        print("F-4 gate (shell): 5 chunks over a window-4 receiver — "
            + "completed, sha-exact, reads ascending, handle closed")
    }

    // MARK: Leg 5 — cancel mid-flight

    func testShellCancelMidFlightEmitsAbortAndCloses() throws {
        var rng = SplitMix64(seed: 0xF4_03)
        let payload = (0..<40_960).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let offer = try BulkOffer(
            transferId: 0xF4_03, totalByteCount: UInt64(payload.count),
            chunkByteCount: 4_096, sha256: Sha256.digest(payload),
            name: "cancel.bin")
        let reader = RecordingReader(payload: payload)
        let wire = WireBox()
        let shell = BulkSendShell(
            offer: offer, reader: reader, send: wire.sendClosure,
            onEvent: { _ in })

        // Window 2: the receiver holds most of the transfer back.
        let receiver = ScriptedReceiver(window: 2)
        try shell.begin()
        // Deliver the offer and the first chunk only, then the human
        // reaches for ×.
        var delivered = 0
        try settle(wire: wire, receiver: receiver, deliverLimit: 2,
                   delivered: &delivered) { shell.ingest($0) }
        XCTAssertEqual(shell.state, .transferring)
        XCTAssertLessThan(shell.progress.fraction, 1.0)

        shell.cancel()
        XCTAssertEqual(shell.state,
                       .aborted(.cancelled, byRemote: false))
        let last = try XCTUnwrap(wire.drain().last)
        guard case .abort(let abort) = try BulkMessage.decode(last) else {
            return XCTFail("the cancel must leave as abort on the wire")
        }
        XCTAssertEqual(abort.reason, .cancelled)
        XCTAssertEqual(abort.transferId, offer.transferId)
        XCTAssertTrue(reader.closed)
        print("F-4 gate (cancel): mid-flight × → abort(cancelled) on "
            + "the wire, terminal state, handle closed")
    }

    // MARK: - Coordinator harness (sync executor = virtual time)

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [BulkSendShellEvent] = []
        func append(_ event: BulkSendShellEvent) {
            lock.lock(); stored.append(event); lock.unlock()
        }
        func contains(_ predicate: (BulkSendShellEvent) -> Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return stored.contains(where: predicate)
        }
    }

    private final class NoticeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ notice: String) {
            lock.lock(); stored.append(notice); lock.unlock()
        }
        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    private struct CoordinatorRig {
        let coordinator: BulkSendCoordinator
        let notices: NoticeBox
        let readers: ReaderBook
        let prepareCount: Counter
    }

    private final class ReaderBook: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [RecordingReader] = []
        func note(_ reader: RecordingReader) {
            lock.lock(); made.append(reader); lock.unlock()
        }
        var all: [RecordingReader] {
            lock.lock(); defer { lock.unlock() }
            return made
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64 = 0
        func next() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            stored += 1
            return stored
        }
        var value: UInt64 {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    /// A coordinator whose seams are all synchronous: the preparer
    /// authors offers from in-memory payloads (ids deterministic), the
    /// reader factory hands recording readers, the executor runs
    /// inline — the whole lifecycle is virtual-time.
    private func makeRig(
        payloads: [String: [UInt8]],
        chunkByteCount: UInt32 = 4_096
    ) -> CoordinatorRig {
        let notices = NoticeBox()
        let readers = ReaderBook()
        let prepareCount = Counter()
        let idMint = Counter()
        let coordinator = BulkSendCoordinator(
            chunkByteCount: chunkByteCount,
            prepare: { url, transferId, chunk in
                _ = prepareCount.next()
                guard let payload = payloads[url.lastPathComponent] else {
                    throw BulkPrepareError.unreadable("no such fixture")
                }
                return try BulkOffer(
                    transferId: transferId,
                    totalByteCount: UInt64(payload.count),
                    chunkByteCount: chunk,
                    sha256: Sha256.digest(payload),
                    name: url.lastPathComponent)
            },
            makeReader: { url in
                guard let payload = payloads[url.lastPathComponent] else {
                    throw BulkPrepareError.unreadable("no such fixture")
                }
                let reader = RecordingReader(payload: payload)
                readers.note(reader)
                return reader
            },
            runInBackground: { work in work() },
            mintId: { 0xF4_00_0000 + idMint.next() },
            onChange: {},
            onNotice: { notices.append($0) })
        return CoordinatorRig(
            coordinator: coordinator, notices: notices,
            readers: readers, prepareCount: prepareCount)
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/f4-fixtures/\(name)")
    }

    /// Coordinator-flavored settle: coordinator's sends → receiver;
    /// receiver's answers → coordinator.ingest.
    private func settle(
        wire: WireBox, receiver: ScriptedReceiver,
        coordinator: BulkSendCoordinator,
        deliverLimit: Int? = nil, delivered: inout Int
    ) throws {
        try settle(
            wire: wire, receiver: receiver,
            deliverLimit: deliverLimit, delivered: &delivered
        ) { coordinator.ingest($0) }
    }

    // MARK: Leg 6 — the offer gate (key 11) and the no-session gate

    func testCoordinatorGatesOffersOnCapabilityAndSession() throws {
        let rig = makeRig(payloads: ["a.bin": [1, 2, 3, 4]])
        let wire = WireBox()

        // No session at all: refused, nothing prepared.
        XCTAssertEqual(rig.coordinator.drop(urls: [url("a.bin")]),
                       .notConnected)
        XCTAssertEqual(rig.prepareCount.value, 0)

        // A session against a key-11-less host: the drop answers
        // loudly — the UI's "host isn't accepting files" — and no
        // offer is even authored, let alone sent.
        rig.coordinator.sessionReady(
            negotiated: false, send: wire.sendClosure)
        XCTAssertEqual(rig.coordinator.drop(urls: [url("a.bin")]),
                       .hostNotAccepting)
        XCTAssertEqual(rig.prepareCount.value, 0)
        XCTAssertEqual(wire.totalSent, 0)
        XCTAssertTrue(rig.coordinator.snapshot().isIdle)
        print("F-4 gate (offer gate): no key 11 → .hostNotAccepting, "
            + "zero bytes; no session → .notConnected")
    }

    // MARK: Leg 7 — queue policy: serial sends, × cancels everything

    func testCoordinatorQueuesSeriallyAndCancelClearsAll() throws {
        var rng = SplitMix64(seed: 0xF4_04)
        let a = (0..<9_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let b = (0..<5_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let c = (0..<4_096).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let rig = makeRig(payloads: ["a.bin": a, "b.bin": b, "c.bin": c])
        let wire = WireBox()
        rig.coordinator.sessionReady(
            negotiated: true, send: wire.sendClosure)

        // Three files, one drop: all accepted, exactly ONE offer
        // in flight (serial by policy).
        XCTAssertEqual(
            rig.coordinator.drop(
                urls: [url("a.bin"), url("b.bin"), url("c.bin")]),
            .accepted(count: 3))
        var snap = rig.coordinator.snapshot()
        XCTAssertEqual(snap.activeName, "a.bin")
        XCTAssertEqual(snap.phase, .offering)
        XCTAssertEqual(snap.queuedCount, 2)
        let inFlight = wire.drain()
        XCTAssertEqual(inFlight.count, 1, "one offer, nothing else")
        guard case .offer(let offerA) = try BulkMessage.decode(
            try XCTUnwrap(inFlight.first)) else {
            return XCTFail("the first word must be a.bin's offer")
        }
        XCTAssertEqual(offerA.name, "a.bin")

        // Complete a.bin: the receiver consents, chunks flow, and the
        // moment it completes b.bin's offer leaves — serial, no gap.
        let receiverA = ScriptedReceiver(window: 4)
        try receiverA.absorb(BulkMessage.offer(offerA).encode())
        var delivered = 0
        try settle(wire: wire, receiver: receiverA,
                   coordinator: rig.coordinator, delivered: &delivered)
        XCTAssertEqual(receiverA.assembledDigest(), offerA.sha256)
        XCTAssertTrue(rig.notices.all.contains("a.bin sent"))

        snap = rig.coordinator.snapshot()
        XCTAssertEqual(snap.activeName, "b.bin")
        XCTAssertEqual(snap.queuedCount, 1)

        // The × cancels the ACTIVE transfer and the queue both.
        rig.coordinator.cancelAll()
        let afterCancel = wire.drain()
        let aborts = try afterCancel.compactMap {
            bytes -> BulkAbort? in
            if case .abort(let abort) = try BulkMessage.decode(bytes) {
                return abort
            }
            return nil
        }
        XCTAssertEqual(aborts.map(\.reason), [.cancelled],
                       "exactly the active transfer aborts on the wire")
        XCTAssertTrue(rig.coordinator.snapshot().isIdle,
                      "the queue died with the cancel")
        XCTAssertTrue(rig.notices.all.contains("File transfer cancelled"))
        // c.bin never even prepared: 2 preparations total (a, b).
        XCTAssertEqual(rig.prepareCount.value, 2)
        print("F-4 gate (queue): 3-file drop → serial sends; × → "
            + "abort(cancelled) + queue cleared")
    }

    // MARK: Leg 8 — reconnect-resume: same id, only the gap re-sent

    func testCoordinatorResumesSameIdAfterSessionTeardown() throws {
        var rng = SplitMix64(seed: 0xF4_05)
        let payload = (0..<32_768).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let rig = makeRig(payloads: ["resume.bin": payload])

        // SESSION 1: the transfer starts; the receiver sees the offer
        // and the first two chunks, then the world goes dark.
        let wire1 = WireBox()
        rig.coordinator.sessionReady(
            negotiated: true, send: wire1.sendClosure)
        XCTAssertEqual(rig.coordinator.drop(urls: [url("resume.bin")]),
                       .accepted(count: 1))
        let receiver1 = ScriptedReceiver(window: 4)
        var delivered1 = 0
        try settle(wire: wire1, receiver: receiver1,
                   coordinator: rig.coordinator,
                   deliverLimit: 3, delivered: &delivered1)
        let firstOffer = try XCTUnwrap(receiver1.offer)
        XCTAssertEqual(receiver1.store.count, 2,
                       "the blackout let exactly two chunks land")

        // Teardown: the receiver persists its resume state (the ends'
        // obligation); the coordinator keeps the entry.
        let persisted = try XCTUnwrap(receiver1.engine.resumeState)
        XCTAssertEqual(persisted.possession.contiguousCount, 2)
        rig.coordinator.sessionEnded()
        var snap = rig.coordinator.snapshot()
        XCTAssertEqual(snap.phase, .awaitingReconnect)
        XCTAssertEqual(snap.activeName, "resume.bin")

        // SESSION 2: fresh wire, fresh engines — the SAME id re-offers
        // and the accept's possession map resumes from the gap.
        let wire2 = WireBox()
        rig.coordinator.sessionReady(
            negotiated: true, send: wire2.sendClosure)
        let reOffered = wire2.drain()
        XCTAssertEqual(reOffered.count, 1)
        guard case .offer(let secondOffer) = try BulkMessage.decode(
            try XCTUnwrap(reOffered.first)) else {
            return XCTFail("the reconnect's first word must be the re-offer")
        }
        XCTAssertEqual(secondOffer.transferId, firstOffer.transferId,
                       "the SAME transfer id — the resume identity")
        XCTAssertEqual(secondOffer.sha256, firstOffer.sha256)
        XCTAssertEqual(rig.prepareCount.value, 1,
                       "no re-hash — the prepared offer re-offers verbatim")

        let receiver2 = ScriptedReceiver(
            window: 4, resumeBook: [persisted])
        // Seed the persisted chunks into the second session's store —
        // exactly what F-3's host does with its tmp file.
        for index in 0..<persisted.possession.contiguousCount {
            receiver2.store[index] = Array(
                payload[Int(index) * 4_096..<(Int(index) + 1) * 4_096])
        }
        try receiver2.absorb(BulkMessage.offer(secondOffer).encode())
        var delivered2 = 0
        try settle(wire: wire2, receiver: receiver2,
                   coordinator: rig.coordinator, delivered: &delivered2)

        XCTAssertEqual(receiver2.assembledDigest(), secondOffer.sha256,
                       "resumed transfer finishes sha-exact")
        // Only the GAP was read and sent in session 2: chunks 2…7.
        let reader2 = try XCTUnwrap(rig.readers.all.last)
        XCTAssertEqual(reader2.readOffsets.map { $0 / 4_096 }.sorted(),
                       [2, 3, 4, 5, 6, 7],
                       "nothing the receiver already held was re-read")
        XCTAssertTrue(rig.notices.all.contains("resume.bin sent"))
        XCTAssertTrue(rig.coordinator.snapshot().isIdle)
        print("F-4 gate (resume): teardown after 2 chunks → same-id "
            + "re-offer, only chunks 2…7 re-sent, sha-exact finish")
    }

    // MARK: Leg 9 — abort(resumeMismatch) draws ONE fresh-id retry

    func testCoordinatorRetriesFreshIdOnResumeMismatch() throws {
        var rng = SplitMix64(seed: 0xF4_06)
        let payload = (0..<8_192).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let rig = makeRig(payloads: ["changed.bin": payload])
        let wire = WireBox()
        rig.coordinator.sessionReady(
            negotiated: true, send: wire.sendClosure)
        XCTAssertEqual(rig.coordinator.drop(urls: [url("changed.bin")]),
                       .accepted(count: 1))
        let first = wire.drain()
        guard case .offer(let offer1) = try BulkMessage.decode(
            try XCTUnwrap(first.first)) else {
            return XCTFail("expected the first offer")
        }

        // A receiver that knows this id under a DIFFERENT digest (the
        // file changed under the id in its host-side history): the
        // offer draws abort(resumeMismatch).
        let poisonedBook = BulkResumeState(
            transferId: offer1.transferId,
            totalByteCount: offer1.totalByteCount,
            chunkByteCount: offer1.chunkByteCount,
            sha256: [UInt8](repeating: 0xEE, count: 32),
            name: offer1.name,
            possession: BulkPossession(contiguousCount: 1))
        let receiver1 = ScriptedReceiver(
            window: 4, resumeBook: [poisonedBook])
        try receiver1.absorb(BulkMessage.offer(offer1).encode())
        let answer = try XCTUnwrap(receiver1.outbox.first)
        guard case .abort(let mismatch) = answer,
              mismatch.reason == .resumeMismatch else {
            return XCTFail("the poisoned book must answer resumeMismatch")
        }
        // Delivering the abort makes the coordinator re-prepare under
        // a FRESH id — the mandated recovery, exactly once.
        rig.coordinator.ingest(answer)
        let retried = wire.drain()
        guard case .offer(let offer2) = try BulkMessage.decode(
            try XCTUnwrap(retried.first)) else {
            return XCTFail("expected the fresh-id re-offer")
        }
        XCTAssertNotEqual(offer2.transferId, offer1.transferId)
        XCTAssertEqual(rig.prepareCount.value, 2, "one re-hash, exactly")

        // The fresh transfer completes against a clean receiver.
        let receiver2 = ScriptedReceiver(window: 4)
        try receiver2.absorb(BulkMessage.offer(offer2).encode())
        var delivered = 0
        try settle(wire: wire, receiver: receiver2,
                   coordinator: rig.coordinator, delivered: &delivered)
        XCTAssertEqual(receiver2.assembledDigest(), offer2.sha256)
        XCTAssertTrue(rig.coordinator.snapshot().isIdle)
        print("F-4 gate (mismatch): abort(resumeMismatch) → one fresh-id "
            + "re-preparation → sha-exact completion")
    }

    // MARK: - The scripted key-11 host (the ClipboardHostStandIn shape)

    /// A bulk-capable host stand-in: Noise responder, capability
    /// negotiator, and TWO host-clock ArqEndpoints — CTRL for the
    /// declaration, chan 8 for bulk carriage. Decoded chan-8 messages
    /// are recorded verbatim; bulk answers are scripted by the test.
    /// No video/beacons.
    private final class BulkHostStandIn: NoiseHandshakeIO {
        let staticKeys = NoiseKeyPair.generate()
        let connectionId: ConnectionId
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var bulkSeq: UInt16 = 0
        var ctrlArq: ArqEndpoint<HostClock>
        var bulkArq: ArqEndpoint<HostClock>
        var negotiator: CapabilityNegotiator
        private var handshakeOutbox: [[UInt8]] = []

        // Evidence.
        var agreed: Capabilities?
        var bulkReceived: [BulkMessage] = []
        var bulkDatagramCount = 0
        var ctrlReliableTypes: [UInt8] = []

        init(localCapabilities: Capabilities) {
            var rng = SplitMix64(seed: 0xF4_11)
            connectionId = ConnectionId.random(using: &rng)
            var config = ArqConfig()
            config.maxDatagramPayloadByteCount =
                WireBudget.maxConnectionIdTaggedPlaintextByteCount
            ctrlArq = ArqEndpoint(channel: .ctrl, config: config)
            bulkArq = ArqEndpoint(channel: .bulkTransfer, config: config)
            negotiator = CapabilityNegotiator(
                role: .host, local: localCapabilities)
        }

        // NoiseHandshakeIO — answered in-process.

        func sendToHost(_ datagram: [UInt8]) throws {
            guard let (envelope, payload) = try? Envelope.decode(datagram[...]),
                  envelope.channel == .ctrl,
                  payload.first == CtrlMessageType.noiseHandshake1
            else { return }
            var responder = try NoiseSession(
                role: .responder, staticKeys: staticKeys)
            _ = try responder.readMessage1(payload.dropFirst())
            let message2 = try responder.writeMessage2()
            transport = try responder.makeTransport()
            try ctrlArq.send(
                message: try negotiator.start().encode(),
                now: HostTimestamp(microseconds: 0)
            )
            let carriage = Envelope(
                channel: .ctrl,
                seq: ChannelSeq(rawValue: ctrlSeq),
                frame: FrameNumber(rawValue: 0),
                timestamp: 0,
                fec: 0,
                extensions: [connectionId.wireExtension]
            )
            ctrlSeq &+= 1
            handshakeOutbox.append(try carriage.encode(
                payload: [CtrlMessageType.noiseHandshake2] + message2))
        }

        func receiveDatagram(timeoutMilliseconds: Int) throws -> [UInt8]? {
            handshakeOutbox.isEmpty ? nil : handshakeOutbox.removeFirst()
        }

        private func sealed(
            channel: ChannelId, body: [UInt8], hostMicros: UInt64
        ) throws -> [UInt8] {
            let seq: UInt16
            if channel == .bulkTransfer {
                seq = bulkSeq; bulkSeq &+= 1
            } else {
                seq = ctrlSeq; ctrlSeq &+= 1
            }
            let envelope = Envelope(
                channel: channel,
                seq: ChannelSeq(rawValue: seq),
                frame: FrameNumber(rawValue: 0),
                timestamp: hostMicros,
                fec: 0,
                extensions: [connectionId.wireExtension]
            )
            let header = try envelope.encode(payload: [])
            let payload = try transport!.seal(
                plaintext: body[...], aad: header[...], envelope: envelope
            )
            return try envelope.encode(payload: payload)
        }

        /// One client datagram: unseal → the CHANNEL's ARQ → record.
        func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            let (envelope, payload) = try Envelope.decode(bytes)
            let aad = bytes[bytes.startIndex..<payload.startIndex]
            let plaintext: [UInt8]
            do {
                plaintext = try transport!.unseal(
                    wirePayload: payload, aad: aad, envelope: envelope
                )
            } catch NoiseError.replayedSequence, NoiseError.staleSequence {
                return
            }
            guard plaintext.first == CtrlMessageType.arqSegment
                    || plaintext.first == CtrlMessageType.arqAck
            else { return dispatchCtrlPlain(plaintext) }
            switch envelope.channel {
            case .bulkTransfer:
                bulkDatagramCount += 1
                for event in bulkArq.ingest(
                    payload: plaintext,
                    now: HostTimestamp(microseconds: nowMicros)
                ) {
                    if case .message(_, let message) = event {
                        bulkReceived.append(try BulkMessage.decode(message))
                    }
                }
            case .ctrl:
                for event in ctrlArq.ingest(
                    payload: plaintext,
                    now: HostTimestamp(microseconds: nowMicros)
                ) {
                    if case .message(_, let message) = event {
                        ctrlReliableTypes.append(message.first ?? 0)
                        dispatchCtrlPlain(message)
                    }
                }
            default:
                break
            }
        }

        private func dispatchCtrlPlain(_ message: [UInt8]) {
            guard message.first == CtrlMessageType.capabilityDeclaration,
                  let declaration =
                    try? CapabilityDeclaration.decode(message)
            else { return }
            if case .agreed(let intersection) =
                try? negotiator.receive(declaration) {
                agreed = intersection
            }
        }

        /// A scripted host answer onto chan 8's ordered stream —
        /// genuine accepts AND the hostile/malformed legs.
        func injectBulk(_ message: [UInt8], nowMicros: UInt64) throws {
            try bulkArq.send(
                message: message,
                now: HostTimestamp(microseconds: nowMicros))
        }

        /// One host beat: due ARQ output from BOTH endpoints, each
        /// sealed on its own channel.
        func advance(nowMicros: UInt64) throws -> [[UInt8]] {
            guard transport != nil else { return [] }
            var out: [[UInt8]] = []
            let (ctrlPayloads, _) = ctrlArq.poll(
                now: HostTimestamp(microseconds: nowMicros))
            for body in ctrlPayloads {
                out.append(try sealed(
                    channel: .ctrl, body: body, hostMicros: nowMicros))
            }
            let (bulkPayloads, _) = bulkArq.poll(
                now: HostTimestamp(microseconds: nowMicros))
            for body in bulkPayloads {
                out.append(try sealed(
                    channel: .bulkTransfer, body: body,
                    hostMicros: nowMicros))
            }
            return out
        }
    }

    // MARK: - The client harness (the ClipboardClientGateTests shape)

    /// The REAL production core minus the socket, on a virtual clock,
    /// piped directly to the stand-in.
    private final class Harness: @unchecked Sendable {
        let host: BulkHostStandIn
        let crypto: NoiseTransportCrypto
        let demux: ReceiveDemux
        var core: LyteUdpSessionCore!
        private var outbound: [[UInt8]] = []
        private var forwarded = 0
        let clock = VirtualClock()

        var events: [LyteUdpSessionEvent] = []

        init(host: BulkHostStandIn) throws {
            self.host = host
            let crypto = try NoiseTransportCrypto(
                hostAddress: "10.0.0.249", hostPort: 41_141,
                hostStaticPublicKey: host.staticKeys.publicKey,
                staticKeys: NoiseKeyPair.generate(),
                attempts: 3, attemptTimeoutMilliseconds: 200)
            try crypto.performHandshake(io: host)
            self.crypto = crypto
            self.demux = ReceiveDemux(crypto: crypto)
            let clock = self.clock
            let sender = TransportSender(crypto: crypto, transmit: {
                [weak self] datagram in
                self?.outbound.append(datagram)
                return true
            })
            self.core = LyteUdpSessionCore(
                demux: demux,
                sender: sender,
                config: LyteUdpSessionCoreConfig(),
                now: { ClientTimestamp(microseconds: clock.value) },
                videoSink: HeadlessVideoSink(),
                onEvent: { [weak self] event in
                    self?.events.append(event)
                })
        }

        func absorb(_ bytes: [UInt8], tMicros: UInt64) {
            let outcome = demux.ingest(
                datagram: bytes[...], arrivalMicroseconds: tMicros)
            if case .accepted = outcome {
                core.handleDatagram(outcome, arrivalMicroseconds: tMicros)
            }
        }

        /// Direct-pipe beats 2 ms apart until both ends quiesce.
        func settle(t: inout UInt64) throws {
            var idle = 0
            while idle < 3 {
                t += 2_000
                clock.value = t
                let before = (forwarded, host.bulkReceived.count,
                              events.count)
                core.tick(now: ClientTimestamp(microseconds: t))
                while forwarded < outbound.count {
                    try host.absorb(outbound[forwarded], nowMicros: t)
                    forwarded += 1
                }
                for datagram in try host.advance(nowMicros: t) {
                    absorb(datagram, tMicros: t)
                }
                core.tick(now: ClientTimestamp(microseconds: t))
                while forwarded < outbound.count {
                    try host.absorb(outbound[forwarded], nowMicros: t)
                    forwarded += 1
                }
                idle = (forwarded, host.bulkReceived.count,
                        events.count) == before ? idle + 1 : 0
            }
        }

        var bulkEvents: [BulkMessage] {
            events.compactMap {
                if case .bulkMessageReceived(let message) = $0 {
                    return message
                }
                return nil
            }
        }
    }

    private final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64 = 1_000
        var value: UInt64 {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    // MARK: Leg 10 — in vivo: chan 8 through the real core

    func testGateInVivoBulkRidesChanEightThroughRealArqAndNoise() throws {
        let host = BulkHostStandIn(
            localCapabilities: .wireDefault.declaringBulkTransfer())
        let harness = try Harness(host: host)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(host.agreed?.bulkTransfer, true,
                       "the host must see key 11 in the client's 0x0F")
        XCTAssertTrue(harness.core.bulkTransferNegotiated)

        // The offer rides chan 8 — never the CTRL stream.
        let offer = try BulkOffer(
            transferId: 0xF4F4,
            totalByteCount: 65_536,
            sha256: [UInt8](repeating: 0xAB, count: 32),
            name: "drop.bin",
            mimeHint: "application/octet-stream")
        try harness.core.sendBulkMessage(
            offer.encode(), now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(host.bulkReceived, [.offer(offer)],
                       "the offer reassembles byte-exact off chan 8")
        XCTAssertGreaterThan(host.bulkDatagramCount, 0)
        XCTAssertFalse(
            host.ctrlReliableTypes.contains(CtrlMessageType.bulkOffer),
            "chan 8 has its OWN ArqEndpoint pair — bulk never rides CTRL")

        // A full 65,536-byte chunk crosses real ARQ segmentation +
        // Noise sealing and lands byte-exact.
        var rng = SplitMix64(seed: 0xF4_10)
        let big = (0..<65_536).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let chunk = try BulkChunk(
            transferId: 0xF4F4, chunkIndex: 0, data: big)
        try harness.core.sendBulkMessage(
            chunk.encode(), now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(host.bulkReceived.last, .chunk(chunk),
                       "65,553 B reassembled byte-exact off the stream")

        // The host's chan-8 answer surfaces as ONE decoded event.
        let accept = try BulkAccept(transferId: 0xF4F4, creditTotal: 4)
        try host.injectBulk(
            BulkMessage.accept(accept).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.bulkEvents, [.accept(accept)])

        // Bytes the codecs refuse drop loud, never surface.
        try host.injectBulk([0xFF, 0x00, 0x01], nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.bulkEvents.count, 1)

        let counters = harness.core.snapshotCounters()
        XCTAssertEqual(counters.bulkMessagesSent, 2)
        XCTAssertEqual(counters.bulkMessagesReceived, 1)
        XCTAssertEqual(counters.bulkDropsLoud, 1)
        print("F-4 gate (in vivo): offer + 64 KiB chunk byte-exact on "
            + "chan 8's own ARQ; accept surfaces; malformed drops loud")
    }

    // MARK: Leg 11 — in vivo: the rule-3 gate against a no-key-11 host

    func testGateInVivoRefusesBulkAgainstNoKeyElevenHost() throws {
        let host = BulkHostStandIn(localCapabilities: .wireDefault)
        let harness = try Harness(host: host)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(host.agreed?.bulkTransfer, false)
        XCTAssertFalse(harness.core.bulkTransferNegotiated)

        // Refused BEFORE a byte leaves.
        let offer = try BulkOffer(
            transferId: 1, totalByteCount: 1,
            sha256: [UInt8](repeating: 0, count: 32), name: "x")
        XCTAssertThrowsError(try harness.core.sendBulkMessage(
            offer.encode(), now: ClientTimestamp(microseconds: t))
        ) { error in
            XCTAssertEqual(
                error as? BulkChannelError, .notNegotiated)
        }
        try harness.settle(t: &t)
        XCTAssertEqual(host.bulkDatagramCount, 0,
                       "no chan-8 datagram may exist on this session")
        XCTAssertEqual(host.bulkReceived, [])

        // A hostile chan-8 message from the no-key-11 host: dropped
        // loud, no event — the rule-3 mirror.
        let hostile = try BulkAccept(transferId: 7, creditTotal: 1)
        try host.injectBulk(
            BulkMessage.accept(hostile).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.bulkEvents, [])
        let counters = harness.core.snapshotCounters()
        XCTAssertEqual(counters.bulkMessagesSent, 0)
        XCTAssertEqual(counters.bulkDropsLoud, 1)
        print("F-4 gate (rule 3, in vivo): offer refused pre-wire against "
            + "a no-key-11 host; a hostile chan-8 answer drops loud")
    }
}
