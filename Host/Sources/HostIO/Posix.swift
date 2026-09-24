// The POSIX plumbing HostIO's stores share. Every descriptor opened here
// is closed exactly once, before the call returns. Failures carry the
// path and strerror text; callers wrap them in their own error types.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct PosixFailure: Error {
    let text: String
}

enum Posix {
    static func errnoText() -> String {
        String(cString: strerror(errno))
    }

    /// `mkdir -p`: every missing component is created with `mode`;
    /// existing ones are left as they are. A relative path stays relative.
    /// Fails when a component cannot be created or `path` is not a
    /// directory afterwards.
    static func makeDirectories(_ path: String, mode: mode_t) throws(PosixFailure) {
        var built = path.hasPrefix("/") ? "/" : ""
        for component in path.split(separator: "/") {
            built += (built.isEmpty || built == "/")
                ? String(component) : "/\(component)"
            if mkdir(built, mode) != 0 && errno != EEXIST {
                throw PosixFailure(text: "\(built): \(errnoText())")
            }
        }
        var status = stat()
        guard stat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR
        else {
            throw PosixFailure(text: "\(path): not a directory")
        }
    }

    /// The whole file, or nil when it does not exist. Any other failure
    /// throws: an unreadable file is never mistaken for a missing one.
    static func readFile(_ path: String) throws(PosixFailure) -> [UInt8]? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw PosixFailure(text: "cannot open \(path): \(errnoText())")
        }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw PosixFailure(text: "cannot read \(path): \(errnoText())")
            }
            if n == 0 { return bytes }
            bytes += chunk[0..<n]
        }
    }

    /// Makes a rename or link inside `directory` durable.
    static func syncDirectory(_ directory: String) {
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 {
            _ = fsync(fd)
            close(fd)
        }
    }
}
