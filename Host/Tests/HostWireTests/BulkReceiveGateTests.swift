import XCTest
import Foundation
import HostCore
import HostIO
import HostSession
import HostWire
import HostWireTestKit
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
        let path = NSTemporaryDirectory() + """
            lyte-bulk-gate-\
            \(UUID().uuidString)
            """
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
        return rng.bytes(count)
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
            // A separator or dot carrying a combining mark is one
            // Character but still a 0x2F / 0x5C / 0x2E byte on disk.
            ("Documents/\u{301}evil.sh", "evil.sh"),
            ("Documents\\\u{301}evil.sh", "evil.sh"),
            (".\u{301}bashrc", "bashrc"),
            ("..\u{301}/\u{301}.\u{20DD}profile", "profile"),
            // Control bytes vanish; interior spaces survive.
            ("evil\u{0000}name.txt", "evilname.txt"),
            ("bell\u{07}~\u{7F}.png", "bell~.png"),
            (" padded name.txt ", "padded name.txt"),
            // C1 and bidi controls vanish: no name displays spoofed.
            ("invoice\u{202E}fdp.exe", "invoicefdp.exe"),
            ("a\u{2066}b\u{2069}\u{200F}c\u{061C}.txt", "abc.txt"),
            ("csi\u{9B}31m\u{85}.log", "csi31m.log"),
            ("two\u{2028}lines\u{2029}.md", "twolines.md"),
            // Zero-width and invisible format characters vanish, so none
            // can hide a leading dot.
            ("\u{FEFF}.bashrc", "bashrc"),
            ("zero\u{200B}wi\u{2060}d\u{200D}th\u{2064}.txt", "zerowidth.txt"),
            // Truncation that consumes the whole stem never exposes the
            // extension as a dotfile.
            ("a" + String(repeating: "\u{301}", count: 125) + ".txt",
             BulkFileNaming.fallbackName + ".txt"),
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
            let name = BulkFileNaming.sanitized(offered)
            XCTAssertEqual(name, expected,
                           "sanitized(\(offered.debugDescription))")
            let bytes = Array(name.utf8)
            XCTAssertNotEqual(bytes.first, 0x2E, offered.debugDescription)
            XCTAssertFalse(bytes.contains { $0 == 0x2F || $0 == 0x5C || $0 == 0x00 },
                           offered.debugDescription)
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

        // Collisions number around the stem, keeping the extension, up
        // to the last number.
        XCTAssertEqual(
            Array(BulkFileNaming.candidates("photo.png").prefix(3)),
            ["photo.png", "photo (1).png", "photo (2).png"]
        )
        XCTAssertEqual(
            Array(BulkFileNaming.candidates("plain").prefix(2)),
            ["plain", "plain (1)"]
        )
        XCTAssertEqual(
            Array(BulkFileNaming.candidates("full.txt")).last,
            "full (9999).txt"
        )
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
    }

    // MARK: Leg 5 — the shared streaming digest survives shell chunking

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
    }

    // MARK: Leg 7 — storage failures: honest aborts, possession kept

    /// A real BulkFileStore with sabotage dials: a write budget, a
    /// lying free-space gauge, a racer that plants a file on the chosen
    /// name just before each of the next `racesToLose` promotions, and a
    /// directory that claims every name is taken.
    private final class SabotagedStore: BulkReceiveStore {
        let inner: BulkFileStore
        var writesAllowed: Int?
        var fakeFreeBytes: UInt64?
        var racesToLose = 0
        var everyNameTaken = false
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
            if racesToLose > 0 {
                racesToLose -= 1
                _ = FileManager.default.createFile(
                    atPath: inner.directoryPath + "/" + name,
                    contents: Data("racer".utf8))
            }
            try inner.promoteStaging(toName: name)
        }
        func removeStaging(transferId: UInt64) {
            inner.removeStaging(transferId: transferId)
        }
        func closeStaging() { inner.closeStaging() }
        func finalNameExists(_ name: String) -> Bool {
            everyNameTaken || inner.finalNameExists(name)
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

    func testGateANameTakenDuringPromotionMovesToTheNextNumber() throws {
        let dir = try makeTempDir()
        let store = try SabotagedStore(directoryPath: dir)
        store.racesToLose = 2
        let shell = BulkReceiveShell(store: store)
        let payload = makePayload(count: 5_000, seed: 0x2ACE)
        let offer = try makeOffer(id: 0xC4, payload: payload, name: "report.pdf")
        let events = try run(
            shell: shell, sender: ScriptedSender(offer: offer, payload: payload))

        XCTAssertTrue(events.contains(.fileCompleted(
            name: "report (2).pdf", path: dir + "/report (2).pdf",
            byteCount: 5_000)))
        XCTAssertEqual(try fileBytes(dir + "/report (2).pdf"), payload)
        for racer in ["report.pdf", "report (1).pdf"] {
            XCTAssertEqual(try fileBytes(dir + "/" + racer),
                           Array("racer".utf8), "\(racer) was replaced")
        }
        XCTAssertEqual(shell.counters.storageFailures, 0)
    }

    func testGateEveryNameTakenFailsLoudAndOverwritesNothing() throws {
        let dir = try makeTempDir()
        let store = try SabotagedStore(directoryPath: dir)
        store.everyNameTaken = true
        let shell = BulkReceiveShell(store: store)
        let payload = makePayload(count: 5_000, seed: 0xF011)
        let offer = try makeOffer(id: 0xC5, payload: payload, name: "full.bin")
        let events = try run(
            shell: shell, sender: ScriptedSender(offer: offer, payload: payload))

        XCTAssertTrue(events.contains(.storageFailure("promote: no free name")))
        XCTAssertFalse(events.contains { event in
            if case .fileCompleted = event { return true }
            return false
        })
        XCTAssertEqual(shell.counters.storageFailures, 1)
        XCTAssertEqual(try visibleEntries(dir), [],
                       "the sha-good staging bytes stay dotted, nothing lands")
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
    }

    // MARK: Leg 8 — key 11 on the spine, mutual-only intersection

    // MARK: The negotiated loopback client (the ClipboardGateTests
    // shape, grown a bulk channel)

    private struct BulkClient: PeerBackedClient {
        var peer: SealedCtrlPeer<ClientClock>
        var receivedBulk: [BulkMessage] = []

        var progressMark: Int { peer.received.count + receivedBulk.count }

        mutating func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            guard case .reliable(let envelope, _, let events) =
                    try peer.absorb(bytes, nowMicros: nowMicros),
                  envelope.channel == .bulkTransfer
            else { return } // CTRL lands in `received`; beacons etc. aside
            for case .message(_, let bytes) in events {
                receivedBulk.append(try BulkMessage.decode(bytes))
            }
        }

        mutating func sendBulk(
            _ message: BulkMessage, nowMicros: UInt64
        ) throws {
            try peer.sendBulk(message.encode(), nowMicros: nowMicros)
        }

        mutating func takeBulk() -> [BulkMessage] {
            defer { receivedBulk.removeAll() }
            return receivedBulk
        }
    }

    private func establish(
        hostCapabilities: Capabilities,
        clientCapabilities: Capabilities
    ) throws -> (host: HostSessionHarness, client: BulkClient) {
        let host = HostSessionHarness(
            config: SessionConfig(
                crypto: .noise(hostStatic: NoiseKeyPair.generate()),
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62,
                capabilities: hostCapabilities
            ),
            tuple: Self.tupleA,
            rng: SplitMix64(seed: 0xB0B)
        )
        var client = BulkClient(peer: try host.connectClient(
            declaring: clientCapabilities,
            openChannels: [.ctrl, .bulkTransfer]
        ))
        client.peer.bulkArq = ArqEndpoint(channel: .bulkTransfer)
        XCTAssertEqual(host.session.phase, .established)
        return (host, client)
    }

    // MARK: Leg 9 — the rule-3 gate: toggle off, chan 8 refused loud

    func testGateToggleOffDropsChanEightLoudAndRefusesSendBulk() throws {
        // The toggle-off host: key 11 never declared (exactly what
        // lyte-host does without --accept-files).
        let (host, clientValue) = try establish(
            hostCapabilities: .wireDefault,
            clientCapabilities: .wireDefault.declaringBulkTransfer()
        )
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000

        var agreed: Capabilities?
        try host.settle(&client, t: &t) {
            if case .capabilitiesAgreed(let set) = $0 { agreed = set }
        }
        XCTAssertEqual(agreed?.bulkTransfer, false,
                       "one-sided key 11 must not survive intersection")
        XCTAssertNotEqual(session.agreedCapabilities?.bulkTransfer, true)

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
        try host.settle(&client, t: &t) {
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
    }

    // MARK: Leg 10 — the full drop, in vivo: Session + shell + disk

    func testGateFullFileDropThroughRealSessionPair() throws {
        let dir = try makeTempDir()
        let (host, clientValue) = try establish(
            hostCapabilities: .wireDefault.declaringBulkTransfer(),
            clientCapabilities: .wireDefault.declaringBulkTransfer()
        )
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000
        try host.settle(&client, t: &t)
        XCTAssertEqual(session.agreedCapabilities?.bulkTransfer, true)

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
            try host.settle(&client, t: &t) {
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
    }
}
