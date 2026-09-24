#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import HostIO
import LyteWire
import XCTest

/// The POSIX file-drop store on its own.
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
