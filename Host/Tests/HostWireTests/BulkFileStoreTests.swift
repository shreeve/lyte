#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import HostIO
import LyteWire
import XCTest

/// The POSIX file-drop store on its own: descriptor ownership, the
/// no-overwrite promotion, and hostile offsets at the filesystem seam.
final class BulkFileStoreTests: XCTestCase {
    private var directory = ""

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyte-bulk-store-\(getpid())-\(UUID().uuidString)")
            .path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// Persisting resume state closes only descriptors it opened, exactly
    /// once: a descriptor another thread opens meanwhile — a socket, a DRM
    /// fd, an identity temporary — stays open.
    func testPersistingResumeStateNeverClosesAnotherThreadsDescriptor() throws {
        let store = try BulkFileStore(directoryPath: directory)
        let state = resumeState(transferId: 0x51)
        try store.openStaging(transferId: state.transferId)
        let sentinel = DescriptorSentinel()
        let thread = Thread { sentinel.run() }
        thread.start()
        for _ in 0..<300 {
            try store.persistResumeState(state)
        }
        sentinel.stop()
        while !thread.isFinished { usleep(1_000) }
        XCTAssertEqual(sentinel.stolen, 0,
                       "persistResumeState closed a descriptor it did not own")
        XCTAssertEqual(store.loadResumeStates(), [state])
    }

    /// A name that became taken after the collision check — another
    /// writer, or a name the client planted — is never replaced: the
    /// promotion fails and the verified staging bytes stay.
    func testPromotionNeverReplacesAFileAlreadyThere() throws {
        let store = try BulkFileStore(directoryPath: directory)
        let existing = directory + "/photo.png"
        XCTAssertTrue(FileManager.default.createFile(
            atPath: existing, contents: Data([0xAA, 0xBB])))
        try store.openStaging(transferId: 7)
        try store.writeChunkDurably([1, 2, 3], atByteOffset: 0)
        XCTAssertThrowsError(try store.promoteStaging(toName: "photo.png"))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: existing)),
            Data([0xAA, 0xBB]))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: store.stagingPath(7))),
            Data([1, 2, 3]))

        try store.openStaging(transferId: 7)
        try store.promoteStaging(toName: "photo (1).png")
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: directory + "/photo (1).png")),
            Data([1, 2, 3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stagingPath(7)))
    }

    /// The filesystem seam judges a final name by its bytes: a "/" or "."
    /// hidden inside a combining-mark Character, a backslash or a NUL is
    /// refused before anything is linked, so no file lands in a
    /// subdirectory or as a dotfile and the staging bytes stay.
    func testPromotionRefusesSeparatorAndDotBytesWhateverTheirCharacter() throws {
        let store = try BulkFileStore(directoryPath: directory)
        try FileManager.default.createDirectory(
            atPath: directory + "/Documents", withIntermediateDirectories: false)
        let hostile = [
            "Documents/\u{301}evil.sh", "Documents\\evil.sh",
            "evil\u{0}.sh", ".\u{301}bashrc", ".profile", "",
        ]
        for name in hostile {
            try store.openStaging(transferId: 11)
            try store.writeChunkDurably([4, 5, 6], atByteOffset: 0)
            XCTAssertThrowsError(try store.promoteStaging(toName: name),
                                 name.debugDescription)
            store.closeStaging()
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: directory + "/Documents"), [])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory)
                .filter { !$0.hasPrefix(".lyte-bulk-") }, ["Documents"])
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: store.stagingPath(11))),
            Data([4, 5, 6]))
    }

    /// The wire allows offsets up to UInt64.max; one past off_t is a
    /// refused write, not a trap.
    func testChunkOffsetPastTheFileOffsetRangeIsRefused() throws {
        let store = try BulkFileStore(directoryPath: directory)
        try store.openStaging(transferId: 9)
        for offset in [UInt64.max, UInt64(Int64.max), UInt64(Int64.max) - 1] {
            XCTAssertThrowsError(
                try store.writeChunkDurably([1, 2, 3], atByteOffset: offset))
        }
    }

    private func resumeState(transferId: UInt64) -> BulkResumeState {
        BulkResumeState(
            transferId: transferId, totalByteCount: 4_096,
            chunkByteCount: 1_024,
            sha256: [UInt8](repeating: 0x5A, count: 32),
            name: "a.bin",
            possession: BulkPossession(contiguousCount: 2))
    }
}

/// Opens descriptors in a loop and checks each is still open while held:
/// a descriptor closed by someone else counts as stolen (and is not
/// closed again — its number may already be another owner's).
private final class DescriptorSentinel: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var stolenCount = 0

    var stolen: Int { lock.withLock { stolenCount } }

    func stop() { lock.withLock { running = false } }

    func run() {
        while lock.withLock({ running }) {
            let fd = open("/dev/null", O_RDONLY)
            guard fd >= 0 else { continue }
            var ours = true
            for _ in 0..<200 where fcntl(fd, F_GETFD) == -1 {
                ours = false
                break
            }
            if ours {
                close(fd)
            } else {
                lock.withLock { stolenCount += 1 }
            }
        }
    }
}
