import Foundation
import LyteTransport
import XCTest

/// A pinned-host file that cannot be decoded is moved aside, never
/// overwritten: the operator's pins survive a hand edit or a future
/// build's schema change.
final class PinnedHostStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL {
        directory.appendingPathComponent("pinned_hosts.json")
    }

    private func quarantined() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".corrupt-") }
    }

    /// The file names hosts and LAN addresses: only its owner reads it.
    /// An entry whose key is not its own static's hash would make
    /// recognition dial a different key, so it never loads.
    func testSavedFileIsOwnerOnlyAndMiskeyedEntriesNeverLoad() throws {
        var store = PinnedHostStore()
        let key = [UInt8](repeating: 0x11, count: 32)
        store.pin(staticPublicKey: key, name: "pup", address: "10.0.0.5",
                  port: 41_151, pairedAt: "2026-09-24T00:00:00Z")
        let good = try XCTUnwrap(store.hosts.first)
        store.hosts[String(repeating: "0", count: 64)] = good.value
        try store.save(to: storeURL)

        let mode = try FileManager.default.attributesOfItem(
            atPath: storeURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(
            PinnedHostStore.load(from: storeURL).hosts.keys.sorted(),
            [good.key])
    }

    func testAbsentFileLoadsEmptyWithoutQuarantine() throws {
        let result = PinnedHostStore.loadQuarantiningUnreadable(from: storeURL)
        XCTAssertEqual(result.store, PinnedHostStore())
        XCTAssertNil(result.quarantinedTo)
        XCTAssertEqual(try quarantined(), [])
    }

    func testCorruptFileIsQuarantinedAndSaveKeepsTheOriginalBytes() throws {
        let original = Data(#"{"hosts":{"abc":{"name":7}}"#.utf8)
        try original.write(to: storeURL)

        var store = PinnedHostStore.load(from: storeURL)
        XCTAssertEqual(store, PinnedHostStore())
        let aside = try quarantined()
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: aside[0]), original)
        XCTAssertTrue(aside[0].lastPathComponent
            .hasPrefix("pinned_hosts.json.corrupt-"))

        store.pin(staticPublicKey: [UInt8](repeating: 3, count: 32),
                  name: "pup", address: "10.0.0.232", port: 41_151,
                  pairedAt: "2026-09-23T00:00:00Z")
        try store.save(to: storeURL)
        XCTAssertEqual(PinnedHostStore.load(from: storeURL), store)
        XCTAssertEqual(try Data(contentsOf: aside[0]), original,
                       "saving must never destroy the unreadable original")
    }

    func testRepeatedCorruptionNeverOverwritesAnEarlierQuarantine() throws {
        let first = Data("not json".utf8)
        let second = Data("[]".utf8)
        try first.write(to: storeURL)
        let firstAside = PinnedHostStore
            .loadQuarantiningUnreadable(from: storeURL).quarantinedTo
        try second.write(to: storeURL)
        let secondAside = PinnedHostStore
            .loadQuarantiningUnreadable(from: storeURL).quarantinedTo
        let urls = try XCTUnwrap([firstAside, secondAside] as? [URL])
        XCTAssertNotEqual(urls[0], urls[1])
        XCTAssertEqual(try Data(contentsOf: urls[0]), first)
        XCTAssertEqual(try Data(contentsOf: urls[1]), second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
    }
}
