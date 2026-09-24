import Foundation
import Glibc
import HostIO
import HostWire
import LyteWire
@testable import lyte_host
import XCTest

/// The host's identity loaders over the XDG layout: a fresh host mints
/// into ~/.config/lyte only, a pre-XDG host keeps its key by copy, and
/// pairing writes never reach the legacy directory.
final class HostIdentityFilesTests: XCTestCase {
    private var home = ""

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyte-identity-\(getpid())-\(UUID().uuidString)")
            .path
        try FileManager.default.createDirectory(
            atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    func testFreshHostMintsIntoTheNewLocationOnly() throws {
        let paths = HostPaths(home: home)
        let minted = try HostStaticKey.loadOrCreate(paths: paths)
        XCTAssertEqual(
            try SecretFile.read(paths.config("noise_static.key")), minted.privateKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.legacyConfigDirectory))
        XCTAssertEqual(
            try HostStaticKey.loadOrCreate(paths: paths).publicKey, minted.publicKey)
    }

    func testLegacyKeyIsAdoptedNotReminted() throws {
        let paths = HostPaths(home: home)
        let legacyPair = NoiseKeyPair.generate()
        try SecretFile.write(legacyPair.privateKey, to: paths.legacyConfig("noise_static.key"))

        let loaded = try HostStaticKey.loadOrCreate(paths: paths)

        XCTAssertEqual(loaded.publicKey, legacyPair.publicKey)
        XCTAssertEqual(
            try SecretFile.read(paths.config("noise_static.key")), legacyPair.privateKey)
        XCTAssertEqual(
            try SecretFile.read(paths.legacyConfig("noise_static.key")), legacyPair.privateKey)
    }

    func testPairingWritesOnlyTheNewKeystore() throws {
        let paths = HostPaths(home: home)
        let legacyText = "# pre-XDG store\n"
        try SecretFile.write(Array(legacyText.utf8), to: paths.legacyConfig("paired_clients"))

        var store = try PairedClients.load(paths: paths)
        XCTAssertTrue(store.pin([UInt8](repeating: 0xAB, count: 32), note: "test"))
        try PairedClients.save(store, paths: paths)

        XCTAssertEqual(try PairedClients.load(paths: paths).entries.count, 1)
        XCTAssertEqual(
            try SecretFile.read(paths.legacyConfig("paired_clients")), Array(legacyText.utf8))
    }
}
