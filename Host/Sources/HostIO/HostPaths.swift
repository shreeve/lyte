// HostPaths: where the Lyte host keeps its files, per the XDG base
// directories.
//
//   <XDG_CONFIG_HOME or ~/.config>/lyte       noise_static.key, paired_clients,
//                                             host.conf (the unit's knobs)
//   <XDG_STATE_HOME or ~/.local/state>/lyte   host.log, the audio crash ledger
//
// An XDG variable counts only when it holds an absolute path (the spec's
// rule); otherwise the home default applies.
//
// Identity once lived in ~/.config/lyte-host. `adoptConfigFile` reads the
// new location first; when only the legacy file exists it COPIES it into
// place (0600, atomic, verified byte-for-byte) and never deletes, moves, or
// writes the legacy file. Writes go only to the new location.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum HostPathError: Error, Equatable, Sendable {
    case noHome
    case createDirectory(String)
    case read(String)
    case write(String)
    case adoptionMismatch(String)
}

public struct HostPaths: Equatable, Sendable {
    /// `<config home>/lyte` — identity and host.conf.
    public let configDirectory: String
    /// `<state home>/lyte` — log and crash-recovery state.
    public let stateDirectory: String
    /// `~/.config/lyte-host` — the pre-XDG identity directory; read-only.
    public let legacyConfigDirectory: String

    public init(home: String, environment: [String: String] = [:]) {
        func base(_ key: String, _ fallback: String) -> String {
            if let value = environment[key], value.hasPrefix("/") {
                return Self.trimmed(value)
            }
            return Self.trimmed(home) + fallback
        }
        configDirectory = base("XDG_CONFIG_HOME", "/.config") + "/lyte"
        stateDirectory = base("XDG_STATE_HOME", "/.local/state") + "/lyte"
        legacyConfigDirectory = Self.trimmed(home) + "/.config/lyte-host"
    }

    /// The running process's paths: $HOME (else the password database)
    /// plus the XDG variables.
    public static func current() throws -> HostPaths {
        var environment: [String: String] = [:]
        for key in ["XDG_CONFIG_HOME", "XDG_STATE_HOME"] {
            if let value = getenv(key) {
                environment[key] = String(cString: value)
            }
        }
        if let value = getenv("HOME"), value.pointee == UInt8(ascii: "/") {
            return HostPaths(home: String(cString: value), environment: environment)
        }
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir,
              directory.pointee == UInt8(ascii: "/")
        else {
            throw HostPathError.noHome
        }
        return HostPaths(home: String(cString: directory), environment: environment)
    }

    public func config(_ name: String) -> String { configDirectory + "/" + name }
    public func state(_ name: String) -> String { stateDirectory + "/" + name }
    public func legacyConfig(_ name: String) -> String {
        legacyConfigDirectory + "/" + name
    }

    /// The config file `name` to read and write — always the new location.
    /// When only `~/.config/lyte-host/<name>` exists it is copied there
    /// first and `note` says so; the legacy file is left exactly as found.
    public func adoptConfigFile(_ name: String) throws -> (path: String, note: String?) {
        let target = config(name)
        if SecretFile.exists(target) {
            return (target, nil)
        }
        let legacy = legacyConfig(name)
        guard let bytes = try SecretFile.read(legacy) else {
            return (target, nil)
        }
        try SecretFile.write(bytes, to: target)
        guard try SecretFile.read(target) == bytes else {
            unlink(target)
            throw HostPathError.adoptionMismatch(target)
        }
        return (target, "identity: copied \(legacy) → \(target) (legacy file left in place)")
    }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path == "/" ? "" : path
    }
}

/// How the host persists key material and trust state. The bytes go to a
/// temporary file created 0600 with O_EXCL (never readable by anyone
/// else, not even for an instant, and never a file someone else planted),
/// are fsync'ed, then renamed over the target and the directory fsync'ed.
/// A crash leaves the old file or the new one, never a torn one.
public enum SecretFile {
    public static func write(_ bytes: [UInt8], to path: String) throws {
        let directory = parent(of: path)
        try makeDirectories(directory)
        let temporary = "\(directory)/.\(basename(of: path)).\(getpid()).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw HostPathError.write("cannot create \(temporary): \(errnoText())")
        }
        var written = 0
        let failure: String? = bytes.withUnsafeBytes { raw in
            while written < raw.count {
                let n = Self.writeSome(fd, raw.baseAddress! + written, raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errnoText()
                }
                written += n
            }
            return fsync(fd) == 0 ? nil : errnoText()
        }
        close(fd)
        if let failure {
            unlink(temporary)
            throw HostPathError.write("cannot write \(temporary): \(failure)")
        }
        guard rename(temporary, path) == 0 else {
            let text = errnoText()
            unlink(temporary)
            throw HostPathError.write("cannot rename into \(path): \(text)")
        }
        let directoryFd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directoryFd >= 0 {
            _ = fsync(directoryFd)
            close(directoryFd)
        }
    }

    /// The whole file, or nil when it does not exist. Any other failure
    /// throws: an unreadable identity is never mistaken for a missing one.
    public static func read(_ path: String) throws -> [UInt8]? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw HostPathError.read("cannot open \(path): \(errnoText())")
        }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { readSome(fd, $0.baseAddress!, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                throw HostPathError.read("cannot read \(path): \(errnoText())")
            }
            if n == 0 { return bytes }
            bytes += chunk[0..<n]
        }
    }

    public static func exists(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0
    }

    /// `mkdir -p` with owner-only permissions for every directory created.
    public static func makeDirectories(_ path: String) throws {
        var built = ""
        for component in path.split(separator: "/") {
            built += "/" + component
            if mkdir(built, 0o700) != 0 && errno != EEXIST {
                throw HostPathError.createDirectory("\(built): \(errnoText())")
            }
        }
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else {
            return "/"
        }
        return String(path[..<slash])
    }

    private static func basename(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private static func writeSome(
        _ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int
    ) -> Int {
        #if canImport(Darwin)
        Darwin.write(fd, buffer, count)
        #else
        Glibc.write(fd, buffer, count)
        #endif
    }

    private static func readSome(
        _ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int
    ) -> Int {
        #if canImport(Darwin)
        Darwin.read(fd, buffer, count)
        #else
        Glibc.read(fd, buffer, count)
        #endif
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
