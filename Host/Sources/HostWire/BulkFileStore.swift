// BulkFileStore (F-3): the one production BulkReceiveStore — plain
// POSIX file IO on the destination directory. Direct syscalls rather
// than Foundation (HostWire keeps Wire's no-Foundation spirit, and
// open/pwrite/fsync/rename need no macros — the disk is an OS leaf
// Swift reaches directly, the CNetIO rationale without the C target).
//
// Layout inside the drop directory, all of it dotted (invisible):
//   .lyte-bulk-<16-hex transferId>.part    the staging file — chunks
//                                          pwritten at exact offsets,
//                                          fsync'd before every ack
//   .lyte-bulk-<16-hex transferId>.resume  the persisted
//                                          BulkResumeState (atomic
//                                          tmp+fsync+rename)
// Completion promotes the .part by fsync-then-rename to the sanitized
// final name, then fsyncs the directory — a kill -9 at ANY instant
// leaves either the dotted staging pair or the finished file, never a
// partial in the visible listing.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import LyteCore
import LyteWire

public enum BulkStoreError: Error, Equatable, Sendable {
    case directoryUnavailable(String)
    case openFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case renameFailed(String)
    /// A final name carrying a path separator — sanitization upstream
    /// makes this unreachable; refused anyway (defense at the seam
    /// where the bytes hit the filesystem).
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
        try Self.makeDirectories(directoryPath)
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
            throw BulkStoreError.openFailed("\(path): \(Self.errnoText())")
        }
        fd = descriptor
        openTransferId = transferId
    }

    public func writeChunkDurably(
        _ data: [UInt8], atByteOffset byteOffset: UInt64
    ) throws {
        guard fd >= 0 else { throw BulkStoreError.noStagingOpen }
        var written = 0
        while written < data.count {
            let result = data.withUnsafeBytes { buffer -> Int in
                pwrite(
                    fd,
                    buffer.baseAddress!.advanced(by: written),
                    data.count - written,
                    off_t(byteOffset) + off_t(written)
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw BulkStoreError.writeFailed(Self.errnoText())
            }
            written += result
        }
        guard fsync(fd) == 0 else {
            throw BulkStoreError.writeFailed("fsync: \(Self.errnoText())")
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
                throw BulkStoreError.readFailed(Self.errnoText())
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
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
              !name.hasPrefix(".")
        else {
            throw BulkStoreError.invalidFinalName(name)
        }
        guard fsync(fd) == 0 else {
            throw BulkStoreError.writeFailed("fsync: \(Self.errnoText())")
        }
        close(fd)
        fd = -1
        openTransferId = nil
        let destination = directoryPath + "/" + name
        guard rename(stagingPath(transferId), destination) == 0 else {
            throw BulkStoreError.renameFailed(
                "\(destination): \(Self.errnoText())"
            )
        }
        syncDirectory()
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
        access(directoryPath + "/" + name, F_OK) == 0
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
            let path = directoryPath + "/" + name
            guard let bytes = try? Self.readWholeFile(path),
                  let state = try? BulkResumeStateCodec.decode(bytes),
                  access(stagingPath(state.transferId), F_OK) == 0
            else {
                // A torn write or an orphaned record: weather, not an
                // error — losing the cache costs re-received chunks,
                // and the digest arbitrates the finish line anyway.
                unlink(path)
                continue
            }
            states.append(state)
        }
        return states
    }

    public func persistResumeState(_ state: BulkResumeState) throws {
        let path = resumePath(state.transferId)
        let temporary = path + ".tmp"
        let descriptor = open(
            temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o600
        )
        guard descriptor >= 0 else {
            throw BulkStoreError.openFailed(
                "\(temporary): \(Self.errnoText())"
            )
        }
        defer { if descriptor >= 0 { close(descriptor) } }
        let bytes = BulkResumeStateCodec.encode(state)
        var written = 0
        while written < bytes.count {
            let result = bytes.withUnsafeBytes { buffer -> Int in
                write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: written),
                    bytes.count - written
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw BulkStoreError.writeFailed(Self.errnoText())
            }
            written += result
        }
        guard fsync(descriptor) == 0 else {
            throw BulkStoreError.writeFailed("fsync: \(Self.errnoText())")
        }
        close(descriptor)
        guard rename(temporary, path) == 0 else {
            throw BulkStoreError.renameFailed(
                "\(path): \(Self.errnoText())"
            )
        }
        syncDirectory()
    }

    public func removeResumeState(transferId: UInt64) {
        unlink(resumePath(transferId))
    }

    // MARK: Paths and plumbing

    /// Exposed for tests that pre-seed staging bytes (the holed-map
    /// vector replay) and audit stray files.
    public func stagingPath(_ transferId: UInt64) -> String {
        directoryPath + "/" + Self.stagingPrefix
            + Hex.string(transferId, width: 16) + ".part"
    }

    public func resumePath(_ transferId: UInt64) -> String {
        directoryPath + "/" + Self.stagingPrefix
            + Hex.string(transferId, width: 16) + ".resume"
    }

    private func syncDirectory() {
        let dirFd = open(directoryPath, O_RDONLY)
        if dirFd >= 0 {
            fsync(dirFd)
            close(dirFd)
        }
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }

    private static func makeDirectories(_ path: String) throws {
        var built = path.hasPrefix("/") ? "/" : ""
        for component in path.split(separator: "/") {
            built += (built.isEmpty || built == "/")
                ? String(component) : "/" + component
            if mkdir(built, 0o755) != 0 && errno != EEXIST {
                throw BulkStoreError.directoryUnavailable(
                    "\(built): \(errnoText())"
                )
            }
        }
        var status = stat()
        guard stat(path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR
        else {
            throw BulkStoreError.directoryUnavailable(
                "\(path): not a directory"
            )
        }
    }

    private static func readWholeFile(_ path: String) throws -> [UInt8] {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw BulkStoreError.openFailed("\(path): \(errnoText())")
        }
        defer { close(descriptor) }
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                read(descriptor, raw.baseAddress, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw BulkStoreError.readFailed(errnoText())
            }
            if count == 0 { break }
            out.append(contentsOf: buffer[0..<count])
        }
        return out
    }
}
