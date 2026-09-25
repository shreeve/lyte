import Foundation
import LyteClientCore
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

    /// Every per-host preference is optional (a file written before it
    /// decodes unchanged), survives save/load and a re-pin at a new
    /// address, stores its default as nil, and refuses an unpinned hash.
    func testPreferencesSurviveReloadAndRepinAndRefuseUnknownHosts() throws {
        let legacy = Data("""
        {"hosts":{"deadbeef":{"name":"pup","address":"10.0.0.249",\
        "port":41000,"staticPublicKeyHex":"\(String(repeating: "ab", count: 32))",\
        "pairedAt":"2026-07-21T09:00:00Z"}}}
        """.utf8)
        var old = try XCTUnwrap(JSONDecoder().decode(
            PinnedHostStore.self, from: legacy).hosts["deadbeef"])
        XCTAssertNil(old.startHostAudioMuted)
        XCTAssertNil(old.shareClipboard)
        XCTAssertNil(old.shareClipboardImages)
        XCTAssertEqual(old.sessionChromaTier, .good)
        // Only an explicit false opts out of starting the host muted.
        for (stored, posture) in [(nil, .hostMuted), (true, .hostMuted),
                                  (false, .hostAudible)]
            as [(Bool?, HostAudioRoutingMode)] {
            old.startHostAudioMuted = stored
            XCTAssertEqual(old.sessionStartHostAudioRouting, posture)
        }
        // A tier this build cannot declare reads as the default.
        for stored in ["ultra", "better"] {
            old.chromaTier = stored
            XCTAssertEqual(old.sessionChromaTier, .good)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinned-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let key = (0..<32).map { UInt8($0) }
        let pkh = LyteDiscovery.publicKeyHash(ofStaticPublicKey: key)
        var store = PinnedHostStore()
        store.pin(staticPublicKey: key, name: "pup", address: "10.0.0.60",
                  port: 41_161, pairedAt: "2026-07-28T00:00:00Z")
        XCTAssertTrue(store.setStartHostAudioMuted(publicKeyHash: pkh, muted: false))
        XCTAssertTrue(store.setShareClipboard(publicKeyHash: pkh, share: true))
        XCTAssertTrue(store.setShareClipboardImages(publicKeyHash: pkh, share: true))
        XCTAssertTrue(store.setChromaTier(publicKeyHash: pkh, tier: .best))
        try store.save(to: url)

        var moved = PinnedHostStore.load(from: url)
        XCTAssertFalse(moved.pin(
            staticPublicKey: key, name: "pup", address: "172.16.4.9",
            port: 41_161, pairedAt: "2026-07-28T01:00:00Z"))
        let host = try XCTUnwrap(moved.host(publicKeyHash: pkh))
        XCTAssertEqual(host.address, "172.16.4.9")
        XCTAssertNil(moved.host(address: "10.0.0.60"), "the address was a hint")
        XCTAssertEqual(host.sessionStartHostAudioRouting, .hostAudible)
        XCTAssertEqual(host.shareClipboard, true)
        XCTAssertEqual(host.shareClipboardImages, true)
        XCTAssertEqual(host.sessionChromaTier, .best)

        XCTAssertTrue(moved.setShareClipboardImages(publicKeyHash: pkh, share: false))
        XCTAssertTrue(moved.setChromaTier(publicKeyHash: pkh, tier: .good))
        XCTAssertNil(moved.host(publicKeyHash: pkh)?.shareClipboardImages)
        XCTAssertNil(moved.host(publicKeyHash: pkh)?.chromaTier)

        let stranger = String(repeating: "0", count: 64)
        XCTAssertFalse(moved.setStartHostAudioMuted(publicKeyHash: stranger, muted: true))
        XCTAssertFalse(moved.setShareClipboard(publicKeyHash: stranger, share: true))
        XCTAssertFalse(moved.setShareClipboardImages(publicKeyHash: stranger, share: true))
        XCTAssertFalse(moved.setChromaTier(publicKeyHash: stranger, tier: .best))
    }
}
