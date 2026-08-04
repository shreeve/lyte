import XCTest
import Foundation
import HostCore
import HostWire
import LyteCore
import LyteWire
import LyteWireTestKit

// THE GATE (F-3, the host receiving end of file transfer). Pinned
// behaviors:
//
//   • the shell drives Wire's BulkReceiveEngine against a REAL
//     directory: chunks pwrite+fsync into a dotted `.part` staging
//     file, completion is sha-verified then promoted by
//     fsync-then-rename — byte-exact on disk, zero strays;
//   • teardown persists BulkResumeState beside the staging file and a
//     fresh shell resumes from the gap, sha-exact, re-receiving only
//     the missing chunks;
//   • the offer's name is UNTRUSTED: path separators, dotfiles,
//     control bytes, overlong names all neutralize (the table), and
//     collisions number around the incumbent;
//   • one transfer at a time (v1): a second concurrent offer draws
//     abort(busy) from the dispatcher without disturbing the live
//     transfer;
//   • storage failure paths: a refusing disk aborts loud with the
//     honest reason, PERSISTS the fsync'd possession, and the next
//     session resumes it; an offer past free space refuses up front;
//   • capability key 11 rides the W7 spine (`0B F5`, mutual-only) and
//     the rule-3 gate holds in vivo: a toggle-off host declares no
//     key, drops chan-8 traffic loud, and refuses sendBulk;
//   • the full drop works END TO END through a real Session pair:
//     offer → accept → chunks → ack → verify → complete over chan 8's
//     own sealed ARQ stream, and the file lands byte-exact.

final class BulkReceiveGateTests: XCTestCase {

    private static let rateBPS = 20_000_000

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_164,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    // MARK: Fixtures

    private func makeTempDir() throws -> String {
        let path = NSTemporaryDirectory() + "lyte-bulk-gate-"
            + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: path)
        }
        return path
    }

    private func makePayload(count: Int, seed: UInt64) -> [UInt8] {
        var rng = SplitMix64(seed: seed)
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        while bytes.count < count {
            var word = rng.next()
            for _ in 0..<8 where bytes.count < count {
                bytes.append(UInt8(truncatingIfNeeded: word))
                word >>= 8
            }
        }
        return bytes
    }

    private func makeOffer(
        id: UInt64, payload: [UInt8], name: String,
        chunkByteCount: UInt32 = 4_096
    ) throws -> BulkOffer {
        try BulkOffer(
            transferId: id,
            totalByteCount: UInt64(payload.count),
            chunkByteCount: chunkByteCount,
            sha256: Sha256.digest(payload),
            name: name
        )
    }

    private func fileBytes(_ path: String) throws -> [UInt8] {
        Array(try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// Visible entries only — the stray audit ignores nothing, the
    /// staging machinery is deliberately dotted so it never shows.
    private func visibleEntries(_ dir: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    private func allEntries(_ dir: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
    }

    // MARK: The scripted sender (the F-4 client end, in miniature)

    /// A BulkSendEngine wrapper answering every `.readChunk` from the
    /// payload synchronously — the TestKit harness's sender half,
    /// shaped for driving a SHELL rather than a bare engine.
    private final class ScriptedSender {
        private(set) var engine: BulkSendEngine
        let payload: [UInt8]
        private(set) var completed = false
        private(set) var aborts: [BulkAbortReason] = []

        init(offer: BulkOffer, payload: [UInt8]) {
            self.engine = BulkSendEngine(offer: offer)
            self.payload = payload
        }

        func begin() throws -> [BulkMessage] {
            try outputs(engine.begin())
        }

        func ingest(_ message: BulkMessage) throws -> [BulkMessage] {
            try outputs(engine.ingest(message))
        }

        private func outputs(
            _ actions: [BulkSendEngine.Action]
        ) throws -> [BulkMessage] {
            var out: [BulkMessage] = []
            for action in actions {
                switch action {
                case .emit(let message):
                    out.append(message)
                case .readChunk(let index):
                    let offer = engine.offer
                    let size = offer.byteCount(ofChunk: index)!
                    let start = Int(index) * Int(offer.chunkByteCount)
                    out += try outputs(engine.supplyChunk(
                        index: index,
                        data: Array(payload[start..<start + size])
                    ))
                case .completed:
                    completed = true
                case .aborted(let reason, _):
                    aborts.append(reason)
                case .violated:
                    XCTFail("sender violated: \(action)")
                }
            }
            return out
        }
    }

    /// Drives sender ↔ shell to quiescence. `shellIngestLimit` models
    /// a teardown blackout: with in-order carriage the shell saw a
    /// prefix of the sender's emissions, so undelivered messages are
    /// simply lost (the TestKit harness's receiverIngestLimit shape).
    @discardableResult
    private func run(
        shell: BulkReceiveShell, sender: ScriptedSender,
        shellIngestLimit: Int? = nil
    ) throws -> [BulkReceiveShellEvent] {
        var events: [BulkReceiveShellEvent] = []
        var toShell = try sender.begin()
        var delivered = 0
        while !toShell.isEmpty {
            let message = toShell.removeFirst()
            if let limit = shellIngestLimit, delivered >= limit {
                continue // torn wire — in flight, never arrived
            }
            delivered += 1
            for event in shell.ingest(message) {
                events.append(event)
                if case .send(let reply) = event {
                    toShell += try sender.ingest(reply)
                }
            }
        }
        return events
    }

    // MARK: Leg 1 — the happy path lands byte-exact in a real directory

    func testGateHappyPathLandsByteExactNoStrays() throws {
        let root = try makeTempDir()
        // The drop dir does not exist yet — the shell must create it
        // (the --accept-files=DIR contract).
        let dir = root + "/drops/nested"
        let shell = try BulkReceiveShell(directoryPath: dir)
        let payload = makePayload(count: 10_000, seed: 0xF00D)
        let offer = try makeOffer(
            id: 0xAB, payload: payload, name: "report.pdf"
        )
        let sender = ScriptedSender(offer: offer, payload: payload)

        let events = try run(shell: shell, sender: sender)

        XCTAssertTrue(sender.completed, "the sender must see 0x20")
        XCTAssertTrue(events.contains(.offerAccepted(
            transferId: 0xAB, name: "report.pdf",
            byteCount: 10_000, resuming: false
        )))
        XCTAssertTrue(events.contains(.fileCompleted(
            name: "report.pdf", path: dir + "/report.pdf",
            byteCount: 10_000
        )))
        XCTAssertEqual(try fileBytes(dir + "/report.pdf"), payload,
                       "the landed file must be byte-exact")
        XCTAssertEqual(try allEntries(dir), ["report.pdf"],
                       "no staging or resume strays after completion")
        XCTAssertEqual(shell.counters.chunksStored, 3)
        XCTAssertEqual(shell.counters.bytesStored, 10_000)
        XCTAssertEqual(shell.counters.filesCompleted, 1)
        XCTAssertEqual(shell.counters.transfersAborted, 0)
        XCTAssertEqual(shell.state, .awaitingOffer,
                       "a completed shell re-arms for the next offer")

        print("F-3 gate (happy path): 10,000 B → 3 chunks → sha-verified "
            + "→ fsync-then-rename, byte-exact, zero strays")
    }

    // MARK: Leg 2 — teardown, resume, completes byte-exact

    func testGateTeardownResumeCompletesByteExact() throws {
        let dir = try makeTempDir()
        let payload = makePayload(count: 50_000, seed: 0xBEEF) // 13 chunks
        let offer = try makeOffer(
            id: 0xCAFE, payload: payload, name: "video.mp4"
        )

        // Session 1: the offer plus five chunks arrive, then the
        // session tears down mid-flight.
        let shell1 = try BulkReceiveShell(directoryPath: dir)
        let sender1 = ScriptedSender(offer: offer, payload: payload)
        try run(shell: shell1, sender: sender1, shellIngestLimit: 6)
        XCTAssertFalse(sender1.completed)
        XCTAssertEqual(shell1.state, .receiving)
        XCTAssertEqual(shell1.counters.chunksStored, 5)
        shell1.teardown()
        XCTAssertEqual(
            try allEntries(dir).filter { $0.hasSuffix(".resume") }.count,
            1, "teardown must persist the resume state beside the .part"
        )

        // Session 2: a fresh shell loads the book; the re-offer (same
        // identity quadruple) resumes — only the gap re-travels.
        let shell2 = try BulkReceiveShell(directoryPath: dir)
        XCTAssertEqual(shell2.counters.resumeStatesLoaded, 1)
        let sender2 = ScriptedSender(offer: offer, payload: payload)
        let events = try run(shell: shell2, sender: sender2)

        XCTAssertTrue(sender2.completed)
        XCTAssertTrue(events.contains(.offerAccepted(
            transferId: 0xCAFE, name: "video.mp4",
            byteCount: 50_000, resuming: true
        )), "the matched re-offer must surface as a resume")
        XCTAssertEqual(shell2.counters.chunksStored, 8,
                       "only the 8 missing chunks re-travel, never the 5 held")
        XCTAssertEqual(try fileBytes(dir + "/video.mp4"), payload,
                       "the resumed file must be byte-exact")
        XCTAssertEqual(try allEntries(dir), ["video.mp4"],
                       "the resume file and staging file both clean up")

        print("F-3 gate (resume): teardown at 5/13 chunks → persisted "
            + "state → fresh shell resumes the 8-chunk gap → byte-exact")
    }

    // MARK: Leg 3 — the filename sanitization table

    func testGateFilenameSanitizationTable() {
        let table: [(offered: String, expected: String)] = [
            // Path separators: only the final component survives.
            ("../../etc/passwd", "passwd"),
            ("..\\..\\windows\\evil.exe", "evil.exe"),
            ("/etc/shadow", "shadow"),
            // Dotfiles neutralize — nothing lands invisible.
            (".bashrc", "bashrc"),
            ("...sneaky", "sneaky"),
            ("../.ssh", "ssh"),
            // Control bytes vanish; interior spaces survive.
            ("evil\u{0000}name.txt", "evilname.txt"),
            ("bell\u{07}~\u{7F}.png", "bell~.png"),
            (" padded name.txt ", "padded name.txt"),
            // Trailing dots trim (Windows-hostile, dedupe-hostile).
            ("archive.tar.gz...", "archive.tar.gz"),
            // Nothing left → the fallback.
            ("/", BulkFileNaming.fallbackName),
            ("....", BulkFileNaming.fallbackName),
            ("", BulkFileNaming.fallbackName),
            ("\u{01}\u{02}", BulkFileNaming.fallbackName),
            // The boring case rides through untouched.
            ("photo.png", "photo.png"),
            ("фото с дачи.jpeg", "фото с дачи.jpeg"),
        ]
        for (offered, expected) in table {
            XCTAssertEqual(BulkFileNaming.sanitized(offered), expected,
                           "sanitized(\(offered.debugDescription))")
        }

        // Overlong truncates on the byte budget, keeping the extension.
        let long = String(repeating: "a", count: 300) + ".txt"
        let cut = BulkFileNaming.sanitized(long)
        XCTAssertEqual(cut.utf8.count, BulkFileNaming.maxNameByteCount)
        XCTAssertTrue(cut.hasSuffix(".txt"))
        // Multi-byte names truncate on CHARACTER boundaries.
        let cyrillic = BulkFileNaming.sanitized(
            String(repeating: "ж", count: 300) + ".bin"
        )
        XCTAssertLessThanOrEqual(
            cyrillic.utf8.count, BulkFileNaming.maxNameByteCount
        )
        XCTAssertTrue(cyrillic.hasSuffix(".bin"))

        // Collisions number around every incumbent.
        let taken: Set<String> = ["photo.png", "photo (1).png", "plain"]
        XCTAssertEqual(
            BulkFileNaming.collisionFree("photo.png") { taken.contains($0) },
            "photo (2).png"
        )
        XCTAssertEqual(
            BulkFileNaming.collisionFree("plain") { taken.contains($0) },
            "plain (1)"
        )
        XCTAssertEqual(
            BulkFileNaming.collisionFree("free.txt") { taken.contains($0) },
            "free.txt"
        )

        print("F-3 gate (names): \(table.count)-row hostile-name table "
            + "pinned; truncation byte-budgeted, collisions numbered")
    }

    // MARK: Leg 4 — the resume codec: pinned bytes, hostile decode

    func testGateResumeCodecPinsBytesAndRefusesHostileInput() throws {
        // The minimal state, hand-built byte for byte (LBR1 layout).
        let small = BulkResumeState(
            transferId: 1, totalByteCount: 2, chunkByteCount: 4_096,
            sha256: [UInt8](repeating: 0x11, count: 32),
            name: "a",
            possession: BulkPossession(contiguousCount: 1)
        )
        var expected: [UInt8] = [0x4C, 0x42, 0x52, 0x31] // "LBR1"
        expected += [0x01, 0, 0, 0, 0, 0, 0, 0]          // transferId
        expected += [0x02, 0, 0, 0, 0, 0, 0, 0]          // totalByteCount
        expected += [0x00, 0x10, 0, 0]                   // chunkByteCount
        expected += [UInt8](repeating: 0x11, count: 32)  // sha256
        expected += [0x01, 0, 0, 0, 0, 0, 0, 0]          // contiguousCount
        expected += [0, 0, 0, 0]                         // extrasCount
        expected += [0x01, 0]                            // nameLen
        expected += [0x61]                               // "a"
        XCTAssertEqual(BulkResumeStateCodec.encode(small), expected)
        XCTAssertEqual(try BulkResumeStateCodec.decode(expected), small)

        // A holed, unicode-named state roundtrips exactly.
        let holed = BulkResumeState(
            transferId: 0xDEAD_BEEF_CAFE_F00D,
            totalByteCount: 1_000_000, chunkByteCount: 65_536,
            sha256: Array(0..<32),
            name: "фото.png",
            possession: BulkPossession(
                contiguousCount: 3, extras: [7, 5, 11]
            )
        )
        XCTAssertEqual(
            try BulkResumeStateCodec.decode(
                BulkResumeStateCodec.encode(holed)
            ), holed
        )

        // Hostile bytes reject with what they found, never trap.
        XCTAssertThrowsError(try BulkResumeStateCodec.decode([]))
        XCTAssertThrowsError(
            try BulkResumeStateCodec.decode([0x4C, 0x42, 0x52])
        )
        var wrongMagic = expected
        wrongMagic[3] = 0x32 // "LBR2"
        XCTAssertThrowsError(try BulkResumeStateCodec.decode(wrongMagic)) {
            XCTAssertEqual(
                $0 as? BulkResumeStateCodec.CodecError, .badMagic
            )
        }
        XCTAssertThrowsError(
            try BulkResumeStateCodec.decode(Array(expected.dropLast()))
        ) {
            XCTAssertEqual(
                $0 as? BulkResumeStateCodec.CodecError, .truncated
            )
        }
        XCTAssertThrowsError(
            try BulkResumeStateCodec.decode(expected + [0x00])
        ) {
            XCTAssertEqual(
                $0 as? BulkResumeStateCodec.CodecError, .trailingBytes
            )
        }

        print("F-3 gate (codec): LBR1 resume record pinned byte-exact; "
            + "truncation/magic/trailing all reject loud")
    }

    // MARK: Leg 5 — the shared streaming digest survives shell chunking

    func testGateSharedSha256SurvivesFileStoreChunkBoundaries() {
        let payload = makePayload(count: 200_001, seed: 0x5A5A)
        let reference = Sha256.digest(payload)
        for splits in [[1, 62, 63, 64, 65, 200_001], [131_072, 200_001]] {
            var stream = Sha256()
            var cursor = 0
            for edge in splits {
                stream.update(payload[cursor..<min(edge, payload.count)])
                cursor = min(edge, payload.count)
            }
            XCTAssertEqual(stream.finalized(), reference)
        }

        print("F-3 gate (digest): shared SHA-256 streaming splits "
            + "match its one-shot result on 200,001 B")
    }

    // MARK: Leg 6 — abort(busy): one transfer at a time, undisturbed

    func testGateSecondConcurrentOfferDrawsBusyFirstCompletes() throws {
        let dir = try makeTempDir()
        let payload = makePayload(count: 50_000, seed: 0x0DD) // 13 chunks
        let offer = try makeOffer(
            id: 0xA1, payload: payload, name: "first.bin"
        )
        let shell = try BulkReceiveShell(directoryPath: dir)
        let sender = ScriptedSender(offer: offer, payload: payload)
        // Mid-flight: offer + 5 chunks delivered, 8 still owed.
        try run(shell: shell, sender: sender, shellIngestLimit: 6)
        XCTAssertTrue(shell.isTransferActive)

        // A second offer while busy: abort(busy) from the dispatcher,
        // the engine never sees it, the live transfer is untouched.
        let second = try makeOffer(
            id: 0xB2, payload: [0x00], name: "second.bin"
        )
        let refusal = shell.ingest(.offer(second))
        XCTAssertEqual(refusal, [
            .send(.abort(try BulkAbort(transferId: 0xB2, reason: .busy))),
            .offerRefusedBusy(transferId: 0xB2),
        ])
        XCTAssertEqual(shell.counters.offersRefusedBusy, 1)
        XCTAssertTrue(shell.isTransferActive,
                      "the refusal must not disturb the live transfer")

        // The first transfer's remaining chunks land as if nothing
        // happened — completion byte-exact.
        var completions = 0
        for index in 5..<13 as Range<UInt64> {
            let size = offer.byteCount(ofChunk: index)!
            let start = Int(index) * 4_096
            let chunk = try BulkChunk(
                transferId: 0xA1, chunkIndex: index,
                data: Array(payload[start..<start + size])
            )
            for event in shell.ingest(.chunk(chunk)) {
                if case .fileCompleted = event { completions += 1 }
            }
        }
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(try fileBytes(dir + "/first.bin"), payload)
        XCTAssertEqual(try visibleEntries(dir), ["first.bin"],
                       "second.bin must never exist in any form")

        print("F-3 gate (busy): concurrent offer → abort(busy) from the "
            + "dispatcher; the live transfer completes byte-exact")
    }

    // MARK: Leg 7 — storage failures: honest aborts, possession kept

    /// A real BulkFileStore with sabotage dials: a write budget and a
    /// lying free-space gauge.
    private final class SabotagedStore: BulkReceiveStore {
        let inner: BulkFileStore
        var writesAllowed: Int?
        var fakeFreeBytes: UInt64?
        private(set) var writes = 0

        init(directoryPath: String) throws {
            inner = try BulkFileStore(directoryPath: directoryPath)
        }

        var directoryPath: String { inner.directoryPath }
        func openStaging(transferId: UInt64) throws {
            try inner.openStaging(transferId: transferId)
        }
        func writeChunkDurably(
            _ data: [UInt8], atByteOffset byteOffset: UInt64
        ) throws {
            if let allowed = writesAllowed, writes >= allowed {
                throw BulkStoreError.writeFailed("sabotage: disk said no")
            }
            writes += 1
            try inner.writeChunkDurably(data, atByteOffset: byteOffset)
        }
        func stagingDigest() throws -> [UInt8] {
            try inner.stagingDigest()
        }
        func promoteStaging(toName name: String) throws {
            try inner.promoteStaging(toName: name)
        }
        func removeStaging(transferId: UInt64) {
            inner.removeStaging(transferId: transferId)
        }
        func closeStaging() { inner.closeStaging() }
        func finalNameExists(_ name: String) -> Bool {
            inner.finalNameExists(name)
        }
        func freeDiskSpaceByteCount() -> UInt64? {
            fakeFreeBytes ?? inner.freeDiskSpaceByteCount()
        }
        func loadResumeStates() -> [BulkResumeState] {
            inner.loadResumeStates()
        }
        func persistResumeState(_ state: BulkResumeState) throws {
            try inner.persistResumeState(state)
        }
        func removeResumeState(transferId: UInt64) {
            inner.removeResumeState(transferId: transferId)
        }
    }

    func testGateOfferPastFreeSpaceRefusesUpFront() throws {
        let dir = try makeTempDir()
        let store = try SabotagedStore(directoryPath: dir)
        store.fakeFreeBytes = 1_024 // a nearly-full disk
        let shell = BulkReceiveShell(store: store)
        let payload = makePayload(count: 10_000, seed: 0xD15C)
        let offer = try makeOffer(
            id: 0xC3, payload: payload, name: "too-big.iso"
        )
        let sender = ScriptedSender(offer: offer, payload: payload)
        let events = try run(shell: shell, sender: sender)

        XCTAssertTrue(events.contains(.insufficientDiskSpace(
            neededByteCount: 10_000, freeByteCount: 1_024
        )))
        XCTAssertEqual(sender.aborts, [.storageFailure],
                       "the sender must hear the honest reason")
        XCTAssertFalse(sender.completed)
        XCTAssertEqual(shell.counters.spaceRefusals, 1)
        XCTAssertEqual(shell.counters.chunksStored, 0)
        XCTAssertEqual(try allEntries(dir), [], "nothing may touch disk")

        print("F-3 gate (space): a 10,000 B offer against 1,024 B free "
            + "→ abort(storageFailure) before a byte lands")
    }

    func testGateMidTransferWriteFailurePersistsPossessionThenResumes()
        throws
    {
        let dir = try makeTempDir()
        let store = try SabotagedStore(directoryPath: dir)
        store.writesAllowed = 3 // chunks 0–2 land durably; 3 refuses
        let shell = BulkReceiveShell(store: store)
        let payload = makePayload(count: 50_000, seed: 0xFA11) // 13 chunks
        let offer = try makeOffer(
            id: 0xD4, payload: payload, name: "resilient.dat"
        )
        let sender = ScriptedSender(offer: offer, payload: payload)
        let events = try run(shell: shell, sender: sender)

        XCTAssertTrue(events.contains { event in
            if case .storageFailure = event { return true }
            return false
        })
        XCTAssertEqual(sender.aborts, [.storageFailure])
        XCTAssertEqual(shell.counters.storageFailures, 1)
        XCTAssertEqual(shell.state, .awaitingOffer, "re-armed after abort")
        XCTAssertEqual(
            try allEntries(dir).filter { $0.hasSuffix(".resume") }.count,
            1, "the fsync'd possession must persist through the failure"
        )
        XCTAssertEqual(
            try allEntries(dir).filter { $0.hasSuffix(".part") }.count,
            1, "the staging bytes have a future — kept for the resume"
        )

        // The disk recovers; a fresh shell resumes the 3 held chunks
        // and completes byte-exact.
        let shell2 = try BulkReceiveShell(directoryPath: dir)
        XCTAssertEqual(shell2.counters.resumeStatesLoaded, 1)
        let sender2 = ScriptedSender(offer: offer, payload: payload)
        try run(shell: shell2, sender: sender2)
        XCTAssertTrue(sender2.completed)
        XCTAssertEqual(shell2.counters.chunksStored, 10,
                       "only the 10 chunks past the failure re-travel")
        XCTAssertEqual(try fileBytes(dir + "/resilient.dat"), payload)
        XCTAssertEqual(try allEntries(dir), ["resilient.dat"])

        print("F-3 gate (write failure): disk refuses at chunk 3 → "
            + "abort(storageFailure) + possession persisted → recovered "
            + "disk resumes 10 chunks → byte-exact")
    }

    // MARK: Leg 8 — key 11 on the spine, mutual-only intersection

    func testCapabilityKeyElevenRidesTheSpineAndIntersectsMutualOnly()
        throws
    {
        let base = try Capabilities.wireDefault.encodeCbor()
        XCTAssertEqual(base.first, 0xA8)
        var expected = base
        expected[0] = 0xA9
        expected += [0x0B, 0xF5]
        let declared = Capabilities.wireDefault.declaringBulkTransfer()
        XCTAssertEqual(try declared.encodeCbor(), expected)

        XCTAssertTrue(declared.intersecting(declared).bulkTransfer)
        XCTAssertFalse(declared.intersecting(.wireDefault).bulkTransfer)
        XCTAssertFalse(
            Capabilities.wireDefault.intersecting(declared).bulkTransfer
        )
        print("F-3 gate (spine): declaration = local bytes + `0B F5`, "
            + "mutual-only survival")
    }

    // MARK: The negotiated loopback client (the ClipboardGateTests
    // shape, grown a bulk channel)

    private struct BulkClient {
        var noise: NoiseSession
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var bulkSeq: UInt16 = 0
        var arq = ArqEndpoint<ClientClock>(channel: .ctrl)
        var bulkArq = ArqEndpoint<ClientClock>(channel: .bulkTransfer)
        let staticKeys: NoiseKeyPair

        var received: [[UInt8]] = []
        var receivedBulk: [BulkMessage] = []

        init(hostStaticPublicKey: [UInt8]) throws {
            staticKeys = NoiseKeyPair.generate()
            noise = try NoiseSession(
                role: .initiator,
                staticKeys: staticKeys,
                remoteStaticPublicKey: hostStaticPublicKey
            )
        }

        mutating func message1Datagram(
            clientMicros: UInt64
        ) throws -> [UInt8] {
            let message1 = try noise.writeMessage1()
            return try datagram(
                channel: .ctrl,
                body: [CtrlMessageType.noiseHandshake1] + message1,
                sealed: false, clientMicros: clientMicros
            )
        }

        mutating func datagram(
            channel: ChannelId, body: [UInt8], sealed: Bool,
            clientMicros: UInt64
        ) throws -> [UInt8] {
            let seq: ChannelSeq
            switch channel {
            case .bulkTransfer:
                seq = ChannelSeq(rawValue: bulkSeq)
                bulkSeq &+= 1
            default:
                seq = ChannelSeq(rawValue: ctrlSeq)
                ctrlSeq &+= 1
            }
            let envelope = Envelope(
                channel: channel, seq: seq,
                frame: FrameNumber(rawValue: 0),
                timestamp: clientMicros, fec: 0
            )
            guard sealed else { return try envelope.encode(payload: body) }
            let header = try envelope.encode(payload: [])
            let payload = try transport!.seal(
                plaintext: body[...], aad: header[...], envelope: envelope
            )
            return try envelope.encode(payload: payload)
        }

        mutating func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            let (envelope, payload) = try Envelope.decode(bytes)
            if transport == nil {
                XCTAssertEqual(envelope.channel, .ctrl)
                XCTAssertEqual(
                    payload.first, CtrlMessageType.noiseHandshake2
                )
                _ = try noise.readMessage2(payload.dropFirst())
                transport = try noise.makeTransport()
                return
            }
            guard envelope.channel == .ctrl
                || envelope.channel == .bulkTransfer
            else { return }
            let aad = bytes[bytes.startIndex..<payload.startIndex]
            let plaintext: [UInt8]
            do {
                plaintext = try transport!.unseal(
                    wirePayload: payload, aad: aad, envelope: envelope
                )
            } catch NoiseError.replayedSequence, NoiseError.staleSequence {
                return // network duplicate; routine
            }
            if envelope.channel == .bulkTransfer {
                for event in bulkArq.ingest(
                    payload: plaintext,
                    now: ClientTimestamp(microseconds: nowMicros)
                ) {
                    if case .message(_, let bytes) = event {
                        receivedBulk.append(try BulkMessage.decode(bytes))
                    }
                }
                return
            }
            switch plaintext.first {
            case CtrlMessageType.arqSegment, CtrlMessageType.arqAck:
                for event in arq.ingest(
                    payload: plaintext,
                    now: ClientTimestamp(microseconds: nowMicros)
                ) {
                    if case .message(_, let bytes) = event {
                        received.append(bytes)
                    }
                }
            default:
                break // beacons etc. — not this gate's business
            }
        }

        mutating func sendBulk(
            _ message: BulkMessage, nowMicros: UInt64
        ) throws {
            try bulkArq.send(
                message: message.encode(),
                now: ClientTimestamp(microseconds: nowMicros)
            )
        }

        mutating func takeBulk() -> [BulkMessage] {
            defer { receivedBulk.removeAll() }
            return receivedBulk
        }

        mutating func pollOut(nowMicros: UInt64) throws -> [[UInt8]] {
            var out: [[UInt8]] = []
            let now = ClientTimestamp(microseconds: nowMicros)
            let (ctrlPayloads, _) = arq.poll(now: now)
            for payload in ctrlPayloads {
                out.append(try datagram(
                    channel: .ctrl, body: payload, sealed: true,
                    clientMicros: nowMicros
                ))
            }
            let (bulkPayloads, _) = bulkArq.poll(now: now)
            for payload in bulkPayloads {
                out.append(try datagram(
                    channel: .bulkTransfer, body: payload, sealed: true,
                    clientMicros: nowMicros
                ))
            }
            return out
        }
    }

    private final class DatagramBox {
        var datagrams: [VideoChannelDatagram] = []
    }

    private func establish(
        hostCapabilities: Capabilities,
        clientCapabilities: Capabilities
    ) throws -> (session: Session, client: BulkClient, box: DatagramBox) {
        let hostStatic = NoiseKeyPair.generate()
        let box = DatagramBox()
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62,
                capabilities: hostCapabilities
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0xB0B),
            send: { box.datagrams.append($0) }
        )
        var client = try BulkClient(
            hostStaticPublicKey: hostStatic.publicKey)
        _ = session.receive(
            try client.message1Datagram(clientMicros: 500),
            from: Self.tupleA, now: 0, hostMicroseconds: 0
        )
        XCTAssertEqual(session.phase, .established)
        session.pump(now: 0)
        var negotiator = CapabilityNegotiator(
            role: .client, local: clientCapabilities
        )
        try client.arq.send(
            message: try XCTUnwrap(negotiator.start()).encode(),
            now: ClientTimestamp(microseconds: 1_000)
        )
        return (session, client, box)
    }

    /// Exchange passes 2 ms apart until both ends quiesce.
    private func settle(
        _ session: Session, _ client: inout BulkClient,
        _ box: DatagramBox, forwarded: inout Int, t: inout UInt64,
        onEvent: (SessionEvent) -> Void = { _ in }
    ) throws {
        var idle = 0
        while idle < 3 {
            t += 2_000
            let before = (
                forwarded, client.received.count,
                client.receivedBulk.count
            )
            var events = session.advance(now: t * 1_000, hostMicroseconds: t)
            session.pump(now: t * 1_000)
            while forwarded < box.datagrams.count {
                try client.absorb(box.datagrams[forwarded].bytes, nowMicros: t)
                forwarded += 1
            }
            for datagram in try client.pollOut(nowMicros: t) {
                events += session.receive(
                    datagram, from: Self.tupleA,
                    now: t * 1_000, hostMicroseconds: t
                )
                session.pump(now: t * 1_000)
                while forwarded < box.datagrams.count {
                    try client.absorb(
                        box.datagrams[forwarded].bytes, nowMicros: t
                    )
                    forwarded += 1
                }
            }
            for event in events { onEvent(event) }
            idle = (
                forwarded, client.received.count,
                client.receivedBulk.count
            ) == before ? idle + 1 : 0
        }
    }

    // MARK: Leg 9 — the rule-3 gate: toggle off, chan 8 refused loud

    func testGateToggleOffDropsChanEightLoudAndRefusesSendBulk() throws {
        // The toggle-off host: key 11 never declared (exactly what
        // lyte-host does without --accept-files).
        let (session, clientValue, box) = try establish(
            hostCapabilities: .wireDefault,
            clientCapabilities: .wireDefault.declaringBulkTransfer()
        )
        var client = clientValue
        var forwarded = 0
        var t: UInt64 = 1_000

        var agreed: Capabilities?
        try settle(session, &client, box, forwarded: &forwarded, t: &t) {
            if case .capabilitiesAgreed(let set) = $0 { agreed = set }
        }
        XCTAssertEqual(agreed?.bulkTransfer, false,
                       "one-sided key 11 must not survive intersection")
        XCTAssertFalse(session.agreedBulkTransfer)

        // The client offers anyway (hostile or confused): every chan-8
        // datagram drops loud, no bulk event ever surfaces.
        let payload = makePayload(count: 5_000, seed: 0xBAD)
        try client.sendBulk(
            .offer(try makeOffer(
                id: 0xE5, payload: payload, name: "sneaky.bin"
            )),
            nowMicros: t
        )
        var refusals = 0
        var surfaced = 0
        try settle(session, &client, box, forwarded: &forwarded, t: &t) {
            if case .dropped(.bulkNotNegotiated) = $0 { refusals += 1 }
            if case .bulkMessageReceived = $0 { surfaced += 1 }
        }
        XCTAssertGreaterThanOrEqual(refusals, 1)
        XCTAssertEqual(surfaced, 0)
        XCTAssertEqual(session.counters.bulkMessagesReceived, 0)

        // And the host's own mouth is gated the same way.
        XCTAssertThrowsError(try session.sendBulk(
            [CtrlMessageType.bulkComplete], now: t * 1_000,
            hostMicroseconds: t
        )) {
            XCTAssertEqual($0 as? SessionError, .bulkNotNegotiated)
        }

        print("F-3 gate (rule 3): toggle-off host — key 11 absent, "
            + "chan 8 dropped loud (\(refusals)×), sendBulk refused")
    }

    // MARK: Leg 10 — the full drop, in vivo: Session + shell + disk

    func testGateFullFileDropThroughRealSessionPair() throws {
        let dir = try makeTempDir()
        let (session, clientValue, box) = try establish(
            hostCapabilities: .wireDefault.declaringBulkTransfer(),
            clientCapabilities: .wireDefault.declaringBulkTransfer()
        )
        var client = clientValue
        var forwarded = 0
        var t: UInt64 = 1_000
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        XCTAssertTrue(session.agreedBulkTransfer)

        let shell = try BulkReceiveShell(directoryPath: dir)
        let payload = makePayload(count: 9_000, seed: 0xE2E) // 3 chunks
        let offer = try makeOffer(
            id: 0xF6, payload: payload, name: "dropped.dat"
        )
        let sender = ScriptedSender(offer: offer, payload: payload)
        for message in try sender.begin() {
            try client.sendBulk(message, nowMicros: t)
        }

        // The lyte-host loop in miniature: surfaced chan-8 messages →
        // the shell (disk verdicts) → replies back through sendBulk;
        // the client's deliveries → the sender engine → chan 8.
        var completedNames: [String] = []
        var rounds = 0
        while !sender.completed && rounds < 20 {
            rounds += 1
            var surfaced: [BulkMessage] = []
            try settle(session, &client, box, forwarded: &forwarded, t: &t) {
                if case .bulkMessageReceived(let message) = $0 {
                    surfaced.append(message)
                }
            }
            for message in surfaced {
                for event in shell.ingest(message) {
                    if case .send(let reply) = event {
                        try session.sendBulk(
                            reply.encode(), now: t * 1_000,
                            hostMicroseconds: t
                        )
                    }
                    if case .fileCompleted(let name, _, _) = event {
                        completedNames.append(name)
                    }
                }
            }
            for message in client.takeBulk() {
                for out in try sender.ingest(message) {
                    try client.sendBulk(out, nowMicros: t)
                }
            }
        }

        XCTAssertTrue(sender.completed,
                      "the 0x20 complete must round-trip the real stack")
        XCTAssertEqual(completedNames, ["dropped.dat"])
        XCTAssertEqual(try fileBytes(dir + "/dropped.dat"), payload,
                       "byte-exact through seal/unseal + ARQ + disk")
        XCTAssertEqual(try allEntries(dir), ["dropped.dat"])
        XCTAssertEqual(session.counters.bulkMessagesReceived, 4,
                       "offer + 3 chunks, exactly once each")
        XCTAssertGreaterThanOrEqual(
            session.counters.bulkArqDatagramsSent, 2,
            "accept and complete both rode chan 8"
        )
        XCTAssertTrue(session.arqIsQuiescent,
                      "both reliable sublayers drain to quiet")

        print("F-3 gate (in vivo): offer→accept→3 chunks→ack→verify→"
            + "complete through a real Session pair; dropped.dat "
            + "byte-exact in \(rounds) rounds")
    }
}
