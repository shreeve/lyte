#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import HostIO
import XCTest

/// The XDG layout and the one-way adoption of pre-XDG identity files.
/// Every test runs under a private temporary HOME; nothing here resolves
/// the real home directory.
final class HostPathsTests: XCTestCase {
    private var home = ""

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyte-paths-\(getpid())-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    func testDefaultsFollowHome() {
        let paths = HostPaths(home: home)
        XCTAssertEqual(paths.configDirectory, home + "/.config/lyte")
        XCTAssertEqual(paths.stateDirectory, home + "/.local/state/lyte")
        XCTAssertEqual(paths.legacyConfigDirectory, home + "/.config/lyte-host")
        XCTAssertEqual(paths.config("noise_static.key"),
                       home + "/.config/lyte/noise_static.key")
        XCTAssertEqual(paths.state("host.log"), home + "/.local/state/lyte/host.log")
    }

    func testAbsoluteXdgVariablesWinAndRelativeOnesAreIgnored() {
        let custom = HostPaths(home: home, environment: [
            "XDG_CONFIG_HOME": home + "/cfg/",
            "XDG_STATE_HOME": home + "/st",
        ])
        XCTAssertEqual(custom.configDirectory, home + "/cfg/lyte")
        XCTAssertEqual(custom.stateDirectory, home + "/st/lyte")
        XCTAssertEqual(custom.legacyConfigDirectory, home + "/.config/lyte-host",
                       "the legacy directory never followed XDG")

        let relative = HostPaths(home: home, environment: [
            "XDG_CONFIG_HOME": "cfg", "XDG_STATE_HOME": "",
        ])
        XCTAssertEqual(relative, HostPaths(home: home))
    }

    func testNewOnlyIsReadInPlace() throws {
        let paths = HostPaths(home: home)
        try write([1, 2, 3], to: paths.config("noise_static.key"), mode: 0o600)
        let before = try snapshot(paths.config("noise_static.key"))

        let (path, note) = try paths.adoptConfigFile("noise_static.key")

        XCTAssertEqual(path, paths.config("noise_static.key"))
        XCTAssertNil(note)
        XCTAssertEqual(try snapshot(path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.legacyConfigDirectory))
    }

    func testLegacyOnlyIsCopiedOwnerOnlyAndLeftUntouched() throws {
        let paths = HostPaths(home: home)
        let legacy = paths.legacyConfig("paired_clients")
        let bytes = Array("aa bb\n# note\n".utf8)
        try write(bytes, to: legacy, mode: 0o644)
        let legacyBefore = try snapshot(legacy)

        let (path, note) = try paths.adoptConfigFile("paired_clients")

        XCTAssertEqual(path, paths.config("paired_clients"))
        XCTAssertEqual(try SecretFile.read(path), bytes)
        XCTAssertEqual(try mode(of: path), 0o600)
        XCTAssertEqual(try mode(of: paths.configDirectory), 0o700)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains(legacy) == true)
        XCTAssertEqual(try snapshot(legacy), legacyBefore,
                       "the legacy file keeps its bytes, mode, inode and mtime")

        // A second resolution reads the adopted copy without a note.
        let again = try paths.adoptConfigFile("paired_clients")
        XCTAssertEqual(again.path, path)
        XCTAssertNil(again.note)
        XCTAssertEqual(try snapshot(legacy), legacyBefore)
    }

    func testBothPresentNewWinsAndNeitherChanges() throws {
        let paths = HostPaths(home: home)
        try write([9, 9], to: paths.config("noise_static.key"), mode: 0o600)
        try write([1, 1], to: paths.legacyConfig("noise_static.key"), mode: 0o600)
        let newBefore = try snapshot(paths.config("noise_static.key"))
        let legacyBefore = try snapshot(paths.legacyConfig("noise_static.key"))

        let (path, note) = try paths.adoptConfigFile("noise_static.key")

        XCTAssertEqual(path, paths.config("noise_static.key"))
        XCTAssertNil(note)
        XCTAssertEqual(try SecretFile.read(path), [9, 9])
        XCTAssertEqual(try snapshot(path), newBefore)
        XCTAssertEqual(try snapshot(paths.legacyConfig("noise_static.key")), legacyBefore)
    }

    /// Adoption creates the new-location file only if nothing is there:
    /// an entry it did not see as a file — here a symlink to a volume not
    /// yet mounted — is neither replaced nor removed.
    func testAdoptionNeverReplacesAnEntryAtTheNewLocation() throws {
        let paths = HostPaths(home: home)
        try write([1, 1], to: paths.legacyConfig("noise_static.key"), mode: 0o600)
        let legacyBefore = try snapshot(paths.legacyConfig("noise_static.key"))
        try FileManager.default.createDirectory(
            atPath: paths.configDirectory, withIntermediateDirectories: true)
        let target = paths.config("noise_static.key")
        let mountPoint = home + "/unmounted/noise_static.key"
        XCTAssertEqual(symlink(mountPoint, target), 0)

        let (path, note) = try paths.adoptConfigFile("noise_static.key")

        XCTAssertEqual(path, target)
        XCTAssertNil(note)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: target),
            mountPoint, "the new-location entry is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mountPoint))
        XCTAssertEqual(try snapshot(paths.legacyConfig("noise_static.key")),
                       legacyBefore)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: paths.configDirectory),
            ["noise_static.key"], "no temporary is left behind")
    }

    func testNeitherPresentCreatesNothing() throws {
        let paths = HostPaths(home: home)
        let (path, note) = try paths.adoptConfigFile("noise_static.key")
        XCTAssertEqual(path, paths.config("noise_static.key"))
        XCTAssertNil(note)
        XCTAssertNil(try SecretFile.read(path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configDirectory))
    }

    func testAdoptionFollowsXdgConfigHome() throws {
        let paths = HostPaths(home: home, environment: ["XDG_CONFIG_HOME": home + "/xdg"])
        try write([7], to: home + "/.config/lyte-host/noise_static.key", mode: 0o600)

        let (path, note) = try paths.adoptConfigFile("noise_static.key")

        XCTAssertEqual(path, home + "/xdg/lyte/noise_static.key")
        XCTAssertNotNil(note)
        XCTAssertEqual(try SecretFile.read(path), [7])
    }

    func testUnreadableLegacyIsLoudNotMissing() throws {
        try XCTSkipIf(getuid() == 0, "root reads mode-000 files")
        let paths = HostPaths(home: home)
        let legacy = paths.legacyConfig("noise_static.key")
        try write([5], to: legacy, mode: 0o000)
        XCTAssertThrowsError(try paths.adoptConfigFile("noise_static.key"))
        XCTAssertNil(try SecretFile.read(paths.config("noise_static.key")))
    }

    /// Key material is 0600 from the first byte and replaces the old file
    /// whole, leaving no temporary behind.
    func testSecretsLandOwnerOnlyAndReplaceWhole() throws {
        let target = home + "/dir/noise_static.key"

        try SecretFile.write([UInt8](repeating: 1, count: 32), to: target)
        try SecretFile.write([UInt8](repeating: 2, count: 16), to: target)

        XCTAssertEqual(try SecretFile.read(target), [UInt8](repeating: 2, count: 16))
        XCTAssertEqual(try mode(of: target), 0o600)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: home + "/dir"),
            ["noise_static.key"], "no temporary file is left behind")
    }

    /// A crash between create and rename used to leave `.<name>.<pid>.tmp`
    /// behind, and a later process reusing the PID then failed every write
    /// of that file with EEXIST. Temporary names are unique now.
    func testALeftoverTemporaryNeverBlocksAWrite() throws {
        let target = home + "/dir/paired_clients"
        try write([9], to: home + "/dir/.paired_clients.\(getpid()).tmp", mode: 0o600)
        try write([9], to: home + "/dir/.paired_clients.tmp.AAAAAA", mode: 0o600)

        try SecretFile.write([1, 2, 3], to: target)
        XCTAssertEqual(try SecretFile.read(target), [1, 2, 3])
    }

    /// A crashed writer's temporaries (which may hold a copy of a private
    /// key) are swept by the next write of that file once stale; a live
    /// writer's young temporary and unrelated files are left alone.
    func testStaleTemporariesAreSwept() throws {
        let dir = home + "/dir"
        let stale = [".noise_static.key.4242.tmp", ".noise_static.key.tmp.Zx81Qa"]
        let kept = [".noise_static.key.tmp.young1", ".other.key.4242.tmp",
                    ".noise_static.key.backup"]
        for name in stale + kept {
            try write([1], to: dir + "/" + name, mode: 0o600)
        }
        let old = timeval(tv_sec: time(nil) - 3_600, tv_usec: 0)
        for name in stale {
            XCTAssertEqual(utimes(dir + "/" + name, [old, old]), 0)
        }

        try SecretFile.write([7], to: dir + "/noise_static.key")

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir))
        XCTAssertEqual(left, Set(kept + ["noise_static.key"]))
    }

    /// First mint is create-if-absent: two starters racing cannot both
    /// win, and the loser never overwrites the winner's key.
    func testCreateNeverOverwrites() throws {
        let target = home + "/dir/noise_static.key"
        XCTAssertTrue(try SecretFile.create([UInt8](repeating: 1, count: 32), at: target))
        XCTAssertFalse(try SecretFile.create([UInt8](repeating: 2, count: 32), at: target))
        XCTAssertEqual(try SecretFile.read(target), [UInt8](repeating: 1, count: 32))
        XCTAssertEqual(try mode(of: target), 0o600)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: home + "/dir"),
            ["noise_static.key"], "the loser's temporary is gone too")
    }

    // MARK: - Helpers

    private struct Snapshot: Equatable {
        var bytes: [UInt8]
        var mode: mode_t
        var inode: UInt64
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int
    }

    private func snapshot(_ path: String) throws -> Snapshot {
        var info = stat()
        guard stat(path, &info) == 0 else { throw CocoaError(.fileNoSuchFile) }
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        #else
        let modified = info.st_mtim
        #endif
        return Snapshot(
            bytes: bytes, mode: info.st_mode & 0o7777, inode: UInt64(info.st_ino),
            modifiedSeconds: Int(modified.tv_sec),
            modifiedNanoseconds: Int(modified.tv_nsec))
    }

    private func mode(of path: String) throws -> mode_t {
        var info = stat()
        guard stat(path, &info) == 0 else { throw CocoaError(.fileNoSuchFile) }
        return info.st_mode & 0o777
    }

    private func write(_ bytes: [UInt8], to path: String, mode: mode_t) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        XCTAssertEqual(chmod(path, mode), 0)
    }
}
