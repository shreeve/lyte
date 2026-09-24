import Foundation
import LyteWire
import XCTest
@testable import LyteTransport

/// The pinned-host keystore's own contract: save/load round trip, the
/// discovery-hash recognition, manual-dial lookups, re-pin refresh, and
/// unpair. Pure client code — no host in the loop.
final class PinnedHostStoreRoundTripTests: XCTestCase {
    func testPinnedHostStoreRoundTripAndLookups() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinned-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let key = NoiseKeyPair.generate().publicKey
        var store = PinnedHostStore.load(from: url)
        XCTAssertTrue(store.hosts.isEmpty)
        XCTAssertTrue(store.pin(
            staticPublicKey: key, name: "pup", address: "10.0.0.249",
            port: 41_007, pairedAt: "2026-07-22T08:00:00Z"))
        try store.save(to: url)

        var loaded = PinnedHostStore.load(from: url)
        XCTAssertEqual(loaded, store)

        // Recognition is the TXT pkh — the LyteDiscovery hash, exactly.
        let pkh = LyteDiscovery.publicKeyHash(ofStaticPublicKey: key)
        let byHash = try XCTUnwrap(loaded.host(publicKeyHash: pkh))
        XCTAssertEqual(byHash.staticPublicKey, key)
        XCTAssertEqual(byHash.publicKeyHash, pkh)
        var malformed = byHash
        malformed.staticPublicKeyHex = String(repeating: "ab", count: 31) + "  "
        XCTAssertNil(malformed.staticPublicKey,
                     "stored keys stay exact-width, not CLI-tolerant")
        let advertisement = DiscoveredLyteHost(
            name: "pup", address: "10.0.0.249", port: 41_007,
            wireVersion: WireVersion.major, publicKeyHash: pkh)
        XCTAssertTrue(advertisement.matches(pinnedStaticPublicKey: key))

        // Manual-dial lookups, by address and by name, case-insensitive.
        XCTAssertEqual(loaded.host(address: "10.0.0.249")?.name, "pup")
        XCTAssertEqual(loaded.host(address: "PUP")?.name, "pup")
        XCTAssertNil(loaded.host(address: "10.0.0.1"))

        // Re-pin the same key: refreshed hints, not a new entry.
        XCTAssertFalse(loaded.pin(
            staticPublicKey: key, name: "pup", address: "10.0.0.250",
            port: 41_008, pairedAt: "2026-07-23T08:00:00Z"))
        XCTAssertEqual(loaded.hosts.count, 1)
        XCTAssertEqual(loaded.host(publicKeyHash: pkh)?.address, "10.0.0.250")

        // Unpair: the entry is gone; unknown hashes are a nil no-op.
        XCTAssertNotNil(loaded.unpin(publicKeyHash: pkh))
        XCTAssertNil(loaded.unpin(publicKeyHash: pkh))
        XCTAssertTrue(loaded.hosts.isEmpty)
    }
}
