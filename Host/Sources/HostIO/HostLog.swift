// The in-process bound on host.log. The service unit points stdout and
// stderr at host.log (O_APPEND, 0600) and rotates it before each exec,
// but the service lives for weeks, so the process rotates too: when its
// stdout is host.log (same inode) and has grown past the bound, the file
// moves to host.log.1 and a fresh 0600 host.log replaces it on every
// standard descriptor that pointed at the old one.
//
// No line is lost and no second writer appears: until the swap every
// write lands in the old inode (now host.log.1); after it, in the new
// one. stdio buffers are flushed first, and a line-buffered stream
// writes each line with one write(2), so a line lands whole in one file
// or the other even when another thread prints across the swap.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum HostLog {
    /// The unit's own bound (`find -size +65536k`).
    public static let rotateAboveBytes = 64 << 20

    /// Rotates `path` when `descriptors.first` is that file and it holds
    /// more than `limitBytes`; every descriptor pointing at it is
    /// re-pointed at the fresh file. Returns whether it rotated. When the
    /// first descriptor is not the file, the log is someone else's to
    /// bound and nothing happens.
    public static func rotateIfNeeded(
        path: String,
        limitBytes: Int = rotateAboveBytes,
        descriptors: [Int32] = [STDOUT_FILENO, STDERR_FILENO]
    ) throws -> Bool {
        guard let primary = descriptors.first else { return false }
        var current = stat()
        var named = stat()
        guard fstat(primary, &current) == 0,
              stat(path, &named) == 0,
              current.st_dev == named.st_dev, current.st_ino == named.st_ino,
              Int(current.st_size) > limitBytes
        else { return false }
        let previous = path + ".1"
        guard rename(path, previous) == 0 else {
            throw HostPathError.write("cannot move \(path) aside: \(Posix.errnoText())")
        }
        let fresh = open(
            path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, 0o600)
        guard fresh >= 0 else {
            // Writes keep landing in the moved file: nothing is lost.
            throw HostPathError.write("cannot create \(path): \(Posix.errnoText())")
        }
        defer { close(fresh) }
        _ = fchmod(fresh, 0o600)
        for descriptor in descriptors {
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  info.st_dev == current.st_dev, info.st_ino == current.st_ino
            else { continue }
            guard dup2(fresh, descriptor) >= 0 else {
                throw HostPathError.write(
                    "cannot point fd \(descriptor) at \(path): \(Posix.errnoText())")
            }
        }
        return true
    }

    /// `rotateIfNeeded` for this process's stdout and stderr, with every
    /// stdio buffer flushed first.
    public static func rotateStandardOutputIfNeeded(
        path: String, limitBytes: Int = rotateAboveBytes
    ) throws -> Bool {
        fflush(nil)
        return try rotateIfNeeded(path: path, limitBytes: limitBytes)
    }
}
