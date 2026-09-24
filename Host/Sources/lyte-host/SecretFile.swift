// SecretFile: how the host persists key material and trust state. The
// bytes go to a temporary file created 0600 with O_EXCL (never readable
// by anyone else, not even for an instant, and never a file someone
// else planted), are fsync'ed, then renamed over the target and the
// directory fsync'ed. A crash leaves the old file or the new one, never
// a torn one.

import Foundation
#if canImport(Glibc)
import Glibc
#endif

enum SecretFile {
    static func write(_ bytes: [UInt8], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(getpid()).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw HostError("cannot create \(temporary.path): errno \(errno)")
        }
        var written = 0
        let failure: Int32? = bytes.withUnsafeBytes { raw in
            while written < raw.count {
                let n = Glibc.write(fd, raw.baseAddress! + written, raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                written += n
            }
            return fsync(fd) == 0 ? nil : errno
        }
        close(fd)
        if let failure {
            unlink(temporary.path)
            throw HostError("cannot write \(temporary.path): errno \(failure)")
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw HostError("cannot rename into \(url.path): errno \(code)")
        }
        let directoryFd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directoryFd >= 0 {
            _ = fsync(directoryFd)
            close(directoryFd)
        }
    }
}
