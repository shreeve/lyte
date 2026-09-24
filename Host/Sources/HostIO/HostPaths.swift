// Where the Lyte host keeps its files, per the XDG base directories.
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
// place (0600, atomic, create-if-absent, verified byte-for-byte) and never
// deletes, moves, or writes the legacy file. Adoption never replaces or
// removes anything at the new location: whatever lands there first wins.

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
    /// A new-location entry that appears meanwhile (another host process,
    /// a `--pair` run) wins; a copy that reads back wrong throws and is
    /// left in place for the operator.
    public func adoptConfigFile(_ name: String) throws -> (path: String, note: String?) {
        let target = config(name)
        if SecretFile.exists(target) {
            return (target, nil)
        }
        let legacy = legacyConfig(name)
        guard let bytes = try SecretFile.read(legacy),
              try SecretFile.create(bytes, at: target)
        else {
            return (target, nil)
        }
        guard try SecretFile.read(target) == bytes else {
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
/// uniquely named temporary (mkstemp: 0600 with O_EXCL, never readable by
/// anyone else, never a planted file), are fsync'ed, then renamed over the
/// target (or, for `create`, linked only if nothing is there) and the
/// directory fsync'ed. A crash leaves the old file or the new one, never a
/// torn one; a leftover temporary is swept by the next write of that file
/// once it is `staleTemporarySeconds` old.
public enum SecretFile {
    /// A temporary this old is a crashed writer's, not a live one's.
    public static let staleTemporarySeconds = 60

    public static func write(_ bytes: [UInt8], to path: String) throws {
        let temporary = try writeTemporary(bytes, for: path)
        guard rename(temporary, path) == 0 else {
            let text = Posix.errnoText()
            unlink(temporary)
            throw HostPathError.write("cannot rename into \(path): \(text)")
        }
        syncDirectory(of: path)
    }

    /// Writes `bytes` to `path` only if nothing is there, atomically: two
    /// processes creating the same file concurrently cannot both win, and
    /// neither overwrites the other. Returns false (writing nothing) when
    /// the file already exists — the caller reads the winner's.
    public static func create(_ bytes: [UInt8], at path: String) throws -> Bool {
        let temporary = try writeTemporary(bytes, for: path)
        defer { unlink(temporary) }
        guard link(temporary, path) == 0 else {
            if errno == EEXIST { return false }
            throw HostPathError.write("cannot create \(path): \(Posix.errnoText())")
        }
        syncDirectory(of: path)
        return true
    }

    /// The bytes, fsync'ed, in a fresh `.<name>.tmp.XXXXXX` beside `path`.
    private static func writeTemporary(
        _ bytes: [UInt8], for path: String
    ) throws -> String {
        let directory = parent(of: path)
        let name = basename(of: path)
        try makeDirectories(directory)
        sweepStaleTemporaries(in: directory, for: name)
        var template = Array("\(directory)/.\(name).tmp.XXXXXX".utf8CString)
        let fd = template.withUnsafeMutableBufferPointer {
            mkstemp($0.baseAddress!)
        }
        guard fd >= 0 else {
            throw HostPathError.write(
                "cannot create a temporary for \(path): \(Posix.errnoText())")
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let temporary = String(decoding: template.dropLast().map {
            UInt8(bitPattern: $0)
        }, as: UTF8.self)
        _ = fchmod(fd, 0o600)
        var written = 0
        let failure: String? = bytes.withUnsafeBytes { raw in
            while written < raw.count {
                let n = Self.writeSome(fd, raw.baseAddress! + written, raw.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    return Posix.errnoText()
                }
                written += n
            }
            return fsync(fd) == 0 ? nil : Posix.errnoText()
        }
        close(fd)
        if let failure {
            unlink(temporary)
            throw HostPathError.write("cannot write \(temporary): \(failure)")
        }
        return temporary
    }

    /// Removes a crashed writer's temporaries of `name` — this scheme's
    /// `.<name>.tmp.*` and the older `.<name>.<pid>.tmp` — once they are
    /// `staleTemporarySeconds` old; a live writer's are younger.
    static func sweepStaleTemporaries(
        in directory: String, for name: String,
        olderThanSeconds: Int = staleTemporarySeconds
    ) {
        guard let dir = opendir(directory) else { return }
        defer { closedir(dir) }
        let prefix = ".\(name)."
        let now = time(nil)
        while let entry = readdir(dir) {
            let entryName = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard entryName.hasPrefix(prefix) else { continue }
            let rest = entryName.dropFirst(prefix.count)
            let ours = rest.hasPrefix("tmp.")
                || (rest.hasSuffix(".tmp")
                    && rest.dropLast(4).allSatisfy(\.isNumber))
            guard ours else { continue }
            let candidate = directory + "/" + entryName
            var info = stat()
            guard lstat(candidate, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  Int(now) - Int(info.st_mtimeSpec.tv_sec) >= olderThanSeconds
            else { continue }
            unlink(candidate)
        }
    }

    private static func syncDirectory(of path: String) {
        Posix.syncDirectory(parent(of: path))
    }

    /// The whole file, or nil when it does not exist. Any other failure
    /// throws: an unreadable identity is never mistaken for a missing one.
    public static func read(_ path: String) throws -> [UInt8]? {
        do {
            return try Posix.readFile(path)
        } catch {
            throw HostPathError.read(error.text)
        }
    }

    public static func exists(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0
    }

    /// `mkdir -p` with owner-only permissions for every directory created.
    public static func makeDirectories(_ path: String) throws {
        do {
            try Posix.makeDirectories(path, mode: 0o700)
        } catch {
            throw HostPathError.createDirectory(error.text)
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
}

private extension stat {
    var st_mtimeSpec: timespec {
        #if canImport(Darwin)
        st_mtimespec
        #else
        st_mtim
        #endif
    }
}
