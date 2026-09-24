// The production BulkReceiveStore: plain POSIX file IO on the
// destination directory, in HostIO so HostWire stays IO-free.
//
// Layout inside the drop directory, all of it dotted (invisible):
//   .lyte-bulk-<16-hex transferId>.part    the staging file — chunks
//                                          pwritten at exact offsets,
//                                          fsync'd before every ack
//   .lyte-bulk-<16-hex transferId>.resume  the persisted
//                                          BulkResumeState (SecretFile:
//                                          atomic tmp+fsync+rename)
// Completion fsyncs the .part, links it to the sanitized final name only
// if that name is free, unlinks the .part and fsyncs the directory: a
// kill -9 at any instant leaves the dotted staging pair or the finished
// file, never a visible partial, and a promotion never replaces a file
// already in the directory.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import HostWire
import LyteCore
import LyteWire

public enum BulkStoreError: Error, Equatable, Sendable {
    case directoryUnavailable(String)
    case openFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case renameFailed(String)
    /// A final name that is empty, starts with a 0x2E byte, or carries a
    /// 0x2F, 0x5C or 0x00 byte. Upstream sanitization makes this
    /// unreachable; refused anyway at the filesystem seam.
    case invalidFinalName(String)
    case noStagingOpen
}

public final class BulkFileStore: BulkReceiveStore {
    public let directoryPath: String

    private static let stagingPrefix = ".lyte-bulk-"

    private var fd: Int32 = -1
    private var openTransferId: UInt64?

    /// Creates the directory (and its ancestors) if missing.
    public init(directoryPath: String) throws {
        self.directoryPath = directoryPath
        do {
            try Posix.makeDirectories(directoryPath, mode: 0o755)
        } catch {
            throw BulkStoreError.directoryUnavailable(error.text)
        }
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    // MARK: Staging

    public func openStaging(transferId: UInt64) throws {
        closeStaging()
        let path = stagingPath(transferId)
        let descriptor = open(path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            throw BulkStoreError.openFailed("\(path): \(Posix.errnoText())")
        }
        fd = descriptor
        openTransferId = transferId
    }

    public func writeChunkDurably(
        _ data: [UInt8], atByteOffset byteOffset: UInt64
    ) throws {
        guard fd >= 0 else { throw BulkStoreError.noStagingOpen }
        // The wire bounds offsets by a UInt64 total; the file by off_t.
        guard let base = off_t(exactly: byteOffset),
              base <= off_t.max - off_t(data.count)
        else {
            throw BulkStoreError.writeFailed("offset \(byteOffset) past off_t")
        }
        var written = 0
        while written < data.count {
            let result = data.withUnsafeBytes { buffer -> Int in
                pwrite(
                    fd,
                    buffer.baseAddress!.advanced(by: written),
                    data.count - written,
                    base + off_t(written)
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw BulkStoreError.writeFailed(Posix.errnoText())
            }
            written += result
        }
        guard fsync(fd) == 0 else {
            throw BulkStoreError.writeFailed("fsync: \(Posix.errnoText())")
        }
    }

    public func stagingDigest() throws -> [UInt8] {
        guard fd >= 0 else { throw BulkStoreError.noStagingOpen }
        var stream = Sha256()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var offset: off_t = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                pread(fd, raw.baseAddress, raw.count, offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw BulkStoreError.readFailed(Posix.errnoText())
            }
            if count == 0 { break }
            stream.update(buffer[0..<count])
            offset += off_t(count)
        }
        return stream.finalized()
    }

    public func promoteStaging(toName name: String) throws {
        guard let transferId = openTransferId, fd >= 0 else {
            throw BulkStoreError.noStagingOpen
        }
        // Judged on the bytes the kernel sees: a Character-level test
        // misses a "/" or "." that carries a combining mark.
        guard let first = name.utf8.first, first != 0x2E,
              !name.utf8.contains(where: { $0 == 0x2F || $0 == 0x5C || $0 == 0x00 })
        else {
            throw BulkStoreError.invalidFinalName(name)
        }
        guard fsync(fd) == 0 else {
            throw BulkStoreError.writeFailed("fsync: \(Posix.errnoText())")
        }
        close(fd)
        fd = -1
        openTransferId = nil
        let staging = stagingPath(transferId)
        let destination = directoryPath + "/\(name)"
        if link(staging, destination) == 0 {
            unlink(staging)
        } else if [EPERM, ENOTSUP, EOPNOTSUPP, EMLINK].contains(errno) {
            // A filesystem without hard links: the best no-replace
            // rename it offers.
            guard access(destination, F_OK) != 0 else {
                throw BulkStoreError.renameFailed("\(destination): exists")
            }
            guard rename(staging, destination) == 0 else {
                throw BulkStoreError.renameFailed(
                    "\(destination): \(Posix.errnoText())")
            }
        } else {
            throw BulkStoreError.renameFailed(
                "\(destination): \(Posix.errnoText())")
        }
        Posix.syncDirectory(directoryPath)
    }

    public func removeStaging(transferId: UInt64) {
        if openTransferId == transferId { closeStaging() }
        unlink(stagingPath(transferId))
    }

    public func closeStaging() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        openTransferId = nil
    }

    public func finalNameExists(_ name: String) -> Bool {
        access(directoryPath + "/\(name)", F_OK) == 0
    }

    public func freeDiskSpaceByteCount() -> UInt64? {
        var vfs = statvfs()
        guard statvfs(directoryPath, &vfs) == 0 else { return nil }
        return UInt64(vfs.f_bavail) &* UInt64(vfs.f_frsize)
    }

    // MARK: Resume persistence

    public func loadResumeStates() -> [BulkResumeState] {
        guard let dir = opendir(directoryPath) else { return [] }
        defer { closedir(dir) }
        var states: [BulkResumeState] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
                ) { String(cString: $0) }
            }
            guard name.hasPrefix(Self.stagingPrefix),
                  name.hasSuffix(".resume") else { continue }
            let path = directoryPath + "/\(name)"
            guard let bytes = try? Posix.readFile(path),
                  let state = try? BulkResumeStateCodec.decode(bytes),
                  access(stagingPath(state.transferId), F_OK) == 0
            else {
                // A torn or orphaned record is not an error: losing it
                // costs re-received chunks, and the digest arbitrates.
                unlink(path)
                continue
            }
            states.append(state)
        }
        return states
    }

    public func persistResumeState(_ state: BulkResumeState) throws {
        try SecretFile.write(
            BulkResumeStateCodec.encode(state),
            to: resumePath(state.transferId))
    }

    public func removeResumeState(transferId: UInt64) {
        unlink(resumePath(transferId))
    }

    // MARK: Paths

    /// Exposed for tests that pre-seed staging bytes and audit strays.
    public func stagingPath(_ transferId: UInt64) -> String {
        directoryPath + """
            /\(Self.stagingPrefix)\(Hex.string(transferId, width: 16)).part
            """
    }

    public func resumePath(_ transferId: UInt64) -> String {
        directoryPath + """
            /\(Self.stagingPrefix)\(Hex.string(transferId, width: 16)).resume
            """
    }
}

extension BulkReceiveShell {
    /// The production shape: a POSIX store on `directoryPath`, created if
    /// missing. Throws when the directory cannot exist.
    public convenience init(
        directoryPath: String,
        config: BulkTransferConfig = BulkTransferConfig()
    ) throws {
        self.init(
            store: try BulkFileStore(directoryPath: directoryPath),
            config: config
        )
    }
}
