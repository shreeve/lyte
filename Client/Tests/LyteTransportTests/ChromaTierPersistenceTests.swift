import Foundation
import LyteClientCore
import LyteTransport
import XCTest

// The Chroma tier's per-host persistence: the tier rides PinnedHost
// like the "start muted" and clipboard preferences — an optional field
// (old files decode unchanged), stored as its raw string (a future
// tier's file reads as the default here), Good stored as nil (clean
// files), and preserved across a pin refresh. The tier's declaration,
// fallback verdict and stream audit are LyteClientCore's
// (ChromaTierTests).

final class ChromaTierPersistenceTests: XCTestCase {

    private func makePinnedStore() -> (PinnedHostStore, pkh: String) {
        var store = PinnedHostStore()
        let key: [UInt8] = (0..<32).map { UInt8($0) }
        store.pin(staticPublicKey: key, name: "pup",
                  address: "10.0.0.249", port: 41_151,
                  pairedAt: "2026-07-22T00:00:00Z")
        let pkh = LyteDiscovery.publicKeyHash(ofStaticPublicKey: key)
        return (store, pkh)
    }

    func testChromaTierPersistsPerHostAndDefaultsToGood() throws {
        let made = makePinnedStore()
        var store = made.0
        let pkh = made.pkh
        // Unset = Good (the shipped posture).
        XCTAssertEqual(store.host(publicKeyHash: pkh)?.sessionChromaTier,
                       .good)
        XCTAssertTrue(store.setChromaTier(publicKeyHash: pkh, tier: .best))
        XCTAssertEqual(store.host(publicKeyHash: pkh)?.sessionChromaTier,
                       .best)
        // Round-trips through the JSON shelf shape.
        let decoded = try JSONDecoder().decode(
            PinnedHostStore.self, from: try JSONEncoder().encode(store))
        XCTAssertEqual(decoded.host(publicKeyHash: pkh)?.sessionChromaTier,
                       .best)
        // Good writes nil — the default keeps the file clean (the
        // setShareClipboard precedent).
        XCTAssertTrue(store.setChromaTier(publicKeyHash: pkh, tier: .good))
        XCTAssertNil(store.host(publicKeyHash: pkh)?.chromaTier)
        // An unpinned hash has nothing to hang the preference on.
        XCTAssertFalse(store.setChromaTier(
            publicKeyHash: String(repeating: "ab", count: 32),
            tier: .best))
    }

    func testUnknownAndUnselectableStoredTiersReadAsGood() {
        let made = makePinnedStore()
        var store = made.0
        let pkh = made.pkh
        // A future build's tier this build doesn't know: decode fine,
        // read as the default — the connect must always have a
        // declarable tier in hand.
        store.hosts[pkh]?.chromaTier = "ultra"
        XCTAssertEqual(store.host(publicKeyHash: pkh)?.sessionChromaTier,
                       .good)
        // The dormant Better can land in a file only by hand-editing;
        // it is not declarable, so it reads as Good too.
        store.hosts[pkh]?.chromaTier = "better"
        XCTAssertEqual(store.host(publicKeyHash: pkh)?.sessionChromaTier,
                       .good)
    }

    func testPinRefreshPreservesTheChromaTier() {
        let made = makePinnedStore()
        var store = made.0
        let pkh = made.pkh
        _ = store.setChromaTier(publicKeyHash: pkh, tier: .best)
        // A re-pair is a trust event, not a settings reset (the
        // CL-13/CL-15 preference rule, third verse).
        let key: [UInt8] = (0..<32).map { UInt8($0) }
        store.pin(staticPublicKey: key, name: "pup",
                  address: "10.0.0.7", port: 41_151,
                  pairedAt: "2026-07-29T00:00:00Z")
        XCTAssertEqual(store.host(publicKeyHash: pkh)?.sessionChromaTier,
                       .best)
    }
}
