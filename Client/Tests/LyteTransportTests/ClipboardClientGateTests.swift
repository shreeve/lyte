import XCTest
import LyteClientTestKit
import Foundation
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE GATE (CL-15, the client half of clipboard sync). Pinned
// behaviors:
//
//   • the 0x1A/0x1B codecs answer the SAME hand-built arrays as
//     Wire's ClipboardCodecTests and Host/Tests' ClipboardGateTests
//     (the cross-pin) and never trap on hostile bytes;
//   • capability key 10 rides the W7 spine byte-equal to the host's
//     encoding, and the session core's DEFAULT config declares it
//     (declaration is dialect, not consent);
//   • in vivo, against a scripted key-10 host in virtual time: a
//     local copy rides as one byte-exact 0x1A (the exact 65,536-byte
//     ceiling included, through real ARQ segmentation both ways), a
//     host announce surfaces and pre-arms the book, and the announce's
//     pasteboard echo is SUPPRESSED — a set must not boomerang;
//     duplicates dedupe;
//   • consent gates BOTH directions: while sharing is off nothing
//     leaves (.sharingDisabled) and nothing lands (counted, no event);
//     the live toggle flips both mid-session;
//   • the rule-3 gate holds: against a no-key-10 host the share is
//     refused before a byte leaves, a hostile unnegotiated 0x1B drops
//     loud, and a role-confused 0x1A at the client drops loud;
//   • over-ceiling local copies suppress as weather (.overBudget);
//   • the per-host consent default: pre-CL-15 pinned_hosts.json
//     decodes unchanged, the preference survives a re-pair, and the
//     setter refuses unknown hashes.

final class ClipboardClientGateTests: XCTestCase {

    // MARK: Leg 1 — the 0x1A/0x1B bytes, pinned (the cross-pin)

    func testClipboardCodecsPinBytes() throws {
        XCTAssertEqual(
            try ClipboardSet(text: "hello").encode(),
            [0x1A, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
        )
        XCTAssertEqual(
            try ClipboardAnnounce(text: "hello").encode(),
            [0x1B, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
        )
        XCTAssertEqual(
            try ClipboardSet.decode(
                [0x1A, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
            ).text, "hello"
        )
        XCTAssertEqual(
            try ClipboardAnnounce.decode(
                [0x1B, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
            ).text, "hello"
        )
        XCTAssertThrowsError(try ClipboardSet.decode([]))
        XCTAssertThrowsError(try ClipboardSet.decode([0x1A]))
        XCTAssertThrowsError(try ClipboardSet.decode([0x1B, 0x61]))
        XCTAssertThrowsError(try ClipboardAnnounce.decode([0x1A, 0x61]))
        XCTAssertThrowsError(try ClipboardAnnounce.decode([0x1B, 0xFF]))
        print("CL-15 gate (codec): 0x1A/0x1B pinned byte-exact against "
            + "the Wire/host arrays")
    }

    // MARK: Leg 2 — key 10 on the spine; the core default declares

    func testCapabilityKeyTenOnTheSpineAndCoreDefaultDeclares() throws {
        let base = try Capabilities.wireDefault.encodeCbor()
        XCTAssertEqual(base.first, 0xA8)
        var expected = base
        expected[0] = 0xA9
        expected += [0x0A, 0xF5]
        let declared = Capabilities.wireDefault.declaringClipboardText()
        XCTAssertEqual(try declared.encodeCbor(), expected)

        XCTAssertTrue(declared.intersecting(declared).clipboardText)
        XCTAssertFalse(declared.intersecting(.wireDefault).clipboardText)
        XCTAssertFalse(
            Capabilities.wireDefault.intersecting(declared).clipboardText
        )

        // The session core's DEFAULT declaration carries key 10 (and
        // still key 9): dialect, not consent — sharing stays OFF by
        // default and the intersection decides whether the toggle
        // exists.
        let defaults = LyteUdpSessionCoreConfig()
        XCTAssertTrue(defaults.capabilities.clipboardText)
        XCTAssertTrue(defaults.capabilities.hostAudioRouting)
        XCTAssertFalse(defaults.shareClipboard,
                       "consent defaults OFF — clipboards carry passwords")
        print("CL-15 gate (spine): declaration = frozen bytes + `0A F5`; "
            + "core default declares, consent defaults off")
    }

    // MARK: - The scripted host

    /// A key-10-capable host stand-in: Noise responder, host-clock
    /// ARQ, capability negotiator (declaration = first reliable word),
    /// and the host's clipboard rules — consumed 0x1A bytes recorded
    /// verbatim, announces scripted by the test. No video/beacons.
    fileprivate final class ClipboardHostStandIn: ScriptedHost {
        var peer: SealedCtrlPeer<HostClock>
        var handshakeOutbox: [[UInt8]] = []
        let localCapabilities: Capabilities

        // Evidence.
        var agreed: Capabilities?
        var setsReceived: [[UInt8]] = []
        var receivedReliableTypes: [UInt8] = []

        var progressMark: Int { receivedReliableTypes.count }

        init(localCapabilities: Capabilities) {
            var rng = SplitMix64(seed: 0xC1_15)
            peer = SealedCtrlPeer(
                connectionId: ConnectionId.random(using: &rng))
            peer.openChannels = [.ctrl]
            self.localCapabilities = localCapabilities
        }

        /// HS-11's first-word rule, load-bearing: the declaration queues
        /// at establishment, before any client word could be consumed.
        func didEstablish() throws {
            try declare(localCapabilities)
        }

        /// One client datagram: unseal → ARQ ingest → record.
        func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            guard case .reliable(_, _, let events) =
                try peer.absorb(bytes, nowMicros: nowMicros)
            else { return }
            for case .message(_, let message) in events {
                receivedReliableTypes.append(message.first ?? 0)
                try dispatchReliable(message)
            }
        }

        private func dispatchReliable(_ message: [UInt8]) throws {
            switch message.first {
            case CtrlMessageType.capabilityDeclaration:
                guard let declaration =
                    try? CapabilityDeclaration.decode(message)
                else { return XCTFail("malformed client declaration") }
                if case .agreed(let intersection) =
                    try peer.negotiator!.receive(declaration) {
                    agreed = intersection
                }
            case CtrlMessageType.clipboardSet:
                setsReceived.append(message)
            default:
                break
            }
        }
    }

    // MARK: - The client harness

    private typealias Harness = ClientCoreHarness<ClipboardHostStandIn>

    // MARK: Leg 3 — the negotiated round trip + the boomerang proof

    func testGateShareAnnounceAndEchoSuppressionEndToEnd() throws {
        let host = ClipboardHostStandIn(
            localCapabilities: .wireDefault.declaringClipboardText())
        var config = LyteUdpSessionCoreConfig()
        config.shareClipboard = true   // the per-host default, ON
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        XCTAssertEqual(host.agreed?.clipboardText, true,
                       "the host must see key 10 in the client's 0x0F")
        XCTAssertTrue(harness.core.clipboardNegotiated)
        XCTAssertTrue(harness.core.clipboardSharingEnabled)

        // A local copy rides as ONE byte-exact 0x1A.
        XCTAssertEqual(
            harness.core.shareLocalClipboard(
                "copied on the mac", now: ClientTimestamp(microseconds: t)),
            .shared
        )
        try harness.settle(t: &t)
        XCTAssertEqual(
            host.setsReceived,
            [try ClipboardSet(text: "copied on the mac").encode()]
        )

        // Duplicate copy dedupes — nothing new leaves.
        XCTAssertEqual(
            harness.core.shareLocalClipboard(
                "copied on the mac", now: ClientTimestamp(microseconds: t)),
            .suppressedDuplicate
        )
        try harness.settle(t: &t)
        XCTAssertEqual(host.setsReceived.count, 1)

        // A host announce surfaces exactly once...
        try host.injectReliable(
            try ClipboardAnnounce(text: "copied on the host").encode(),
            nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.clipboardEvents, ["copied on the host"])

        // ...and the pasteboard's echo of applying it is SUPPRESSED —
        // a set must not boomerang (the proof obligation).
        XCTAssertEqual(
            harness.core.shareLocalClipboard(
                "copied on the host", now: ClientTimestamp(microseconds: t)),
            .suppressedEcho
        )
        try harness.settle(t: &t)
        XCTAssertEqual(host.setsReceived.count, 1,
                       "the announce's echo must never return as a 0x1A")

        // The exact ceiling flows through real ARQ segmentation.
        let atCeiling = String(
            repeating: "x", count: ClipboardWire.maxTextByteCount)
        XCTAssertEqual(
            harness.core.shareLocalClipboard(
                atCeiling, now: ClientTimestamp(microseconds: t)),
            .shared
        )
        try harness.settle(t: &t)
        XCTAssertEqual(host.setsReceived.count, 2)
        XCTAssertEqual(host.setsReceived.last,
                       try ClipboardSet(text: atCeiling).encode(),
                       "65,537 bytes reassembled byte-exact off the stream")

        let counters = harness.core.snapshotCounters()
        XCTAssertEqual(counters.clipboardSharesSent, 2)
        XCTAssertEqual(counters.clipboardAnnouncesReceived, 1)
        XCTAssertEqual(counters.clipboardLoopSuppressed, 2)
        XCTAssertEqual(counters.clipboardDropsLoud, 0)
        XCTAssertEqual(counters.malformedReliableMessages, 0)

        print("CL-15 gate (in vivo): copy → byte-exact 0x1A (ceiling "
            + "included); announce → event; echo suppressed — no boomerang")
    }

    // MARK: Leg 4 — consent gates both directions, live toggle

    func testGateSharingOffMeansNothingLeavesAndNothingLands() throws {
        let host = ClipboardHostStandIn(
            localCapabilities: .wireDefault.declaringClipboardText())
        // Default config: consent OFF (no per-host default set).
        let harness = try Harness(host: host)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertTrue(harness.core.clipboardNegotiated,
                      "capability negotiates regardless — dialect, not consent")
        XCTAssertFalse(harness.core.clipboardSharingEnabled)

        // Nothing leaves.
        XCTAssertEqual(
            harness.core.shareLocalClipboard(
                "private", now: ClientTimestamp(microseconds: t)),
            .sharingDisabled
        )
        try harness.settle(t: &t)
        XCTAssertEqual(host.setsReceived, [])

        // Nothing lands: the announce is counted and ignored — no
        // event, so the glue can never touch the pasteboard.
        try host.injectReliable(
            try ClipboardAnnounce(text: "host stuff").encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.clipboardEvents, [])
        XCTAssertEqual(
            harness.core.snapshotCounters().clipboardIgnoredDisabled, 1)

        // The strip's toggle flips both directions live.
        harness.core.setClipboardSharing(true)
        XCTAssertEqual(
            harness.core.shareLocalClipboard(
                "now shared", now: ClientTimestamp(microseconds: t)),
            .shared
        )
        try harness.settle(t: &t)
        XCTAssertEqual(host.setsReceived,
                       [try ClipboardSet(text: "now shared").encode()])
        try host.injectReliable(
            try ClipboardAnnounce(text: "host reply").encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.clipboardEvents, ["host reply"])

        print("CL-15 gate (consent): off = quiet AND deaf; the live "
            + "toggle opens both directions")
    }

    // MARK: Leg 5 — the rule-3 gate + the ceiling

    func testGateUnnegotiatedRefusalsHostileDropsAndOverBudget() throws {
        // A v1 host: declares, but never key 10.
        let host = ClipboardHostStandIn(localCapabilities: .wireDefault)
        var config = LyteUdpSessionCoreConfig()
        config.shareClipboard = true   // even with consent on
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(host.agreed?.clipboardText, false)
        XCTAssertFalse(harness.core.clipboardNegotiated)

        // Refused BEFORE a byte leaves.
        XCTAssertEqual(
            harness.core.shareLocalClipboard(
                "refused", now: ClientTimestamp(microseconds: t)),
            .notNegotiated
        )
        try harness.settle(t: &t)
        XCTAssertEqual(host.setsReceived, [])
        XCTAssertFalse(
            harness.core.snapshotCounters().clipboardSharesSent > 0)

        // A hostile/buggy 0x1B from the no-key-10 host: dropped loud,
        // no event, pasteboard never touched.
        try host.injectReliable(
            try ClipboardAnnounce(text: "sneaky").encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.clipboardEvents, [])
        XCTAssertEqual(
            harness.core.snapshotCounters().clipboardDropsLoud, 1)

        // Role confusion: a 0x1A arriving AT the client — same loud drop.
        try host.injectReliable(
            try ClipboardSet(text: "confused").encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(
            harness.core.snapshotCounters().clipboardDropsLoud, 2)

        // The ceiling suppresses as weather on a NEGOTIATED session.
        let negotiatedHost = ClipboardHostStandIn(
            localCapabilities: .wireDefault.declaringClipboardText())
        var onConfig = LyteUdpSessionCoreConfig()
        onConfig.shareClipboard = true
        let negotiated = try Harness(
            host: negotiatedHost, coreConfig: onConfig)
        var t2: UInt64 = 1_000
        negotiated.clock.value = t2
        try negotiated.core.open(now: ClientTimestamp(microseconds: t2))
        try negotiated.settle(t: &t2)
        let oneOver = String(
            repeating: "a", count: ClipboardWire.maxTextByteCount + 1)
        XCTAssertEqual(
            negotiated.core.shareLocalClipboard(
                oneOver, now: ClientTimestamp(microseconds: t2)),
            .overBudget(ClipboardWire.maxTextByteCount + 1)
        )
        try negotiated.settle(t: &t2)
        XCTAssertEqual(negotiatedHost.setsReceived, [])

        print("CL-15 gate (rule 3): share refused pre-wire, hostile 0x1B "
            + "and role-confused 0x1A dropped loud, ceiling is weather")
    }

    // MARK: Leg 6 — the per-host consent default's plumbing

    func testPinnedHostClipboardPreferencePlumbing() throws {
        // A pre-CL-15 file (no shareClipboard key) decodes unchanged:
        // the preference reads nil, meaning OFF.
        let keyHex = String(repeating: "ab", count: 32)
        let legacy = Data("""
        {"hosts":{"deadbeef":{"name":"pup","address":"10.0.0.249",\
        "port":41000,"staticPublicKeyHex":"\(keyHex)",\
        "pairedAt":"2026-07-21T09:00:00Z","startHostAudioMuted":true}}}
        """.utf8)
        let store = try JSONDecoder().decode(PinnedHostStore.self, from: legacy)
        XCTAssertNil(store.hosts["deadbeef"]?.shareClipboard)
        XCTAssertEqual(store.hosts["deadbeef"]?.startHostAudioMuted, true,
                       "CL-13's preference decodes beside the new one")

        // Round trip through the real save/load path, preference set.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cl15-pinned-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var live = PinnedHostStore()
        let staticKey = (0..<32).map { UInt8($0) }
        live.pin(staticPublicKey: staticKey, name: "pup",
                 address: "10.0.0.249", port: 41_000,
                 pairedAt: "2026-07-22T15:00:00Z")
        let pkh = try XCTUnwrap(live.hosts.keys.first)
        XCTAssertTrue(live.setShareClipboard(publicKeyHash: pkh, share: true))
        try live.save(to: url)
        let reloaded = PinnedHostStore.load(from: url)
        XCTAssertEqual(
            reloaded.host(publicKeyHash: pkh)?.shareClipboard, true)

        // A re-pair refreshes dial hints WITHOUT resetting consent.
        var repaired = reloaded
        repaired.pin(staticPublicKey: staticKey, name: "pup",
                     address: "10.0.0.77", port: 41_131,
                     pairedAt: "2026-07-23T09:00:00Z")
        XCTAssertEqual(repaired.hosts[pkh]?.address, "10.0.0.77")
        XCTAssertEqual(repaired.hosts[pkh]?.shareClipboard, true,
                       "a re-pair is a trust event, not a settings reset")

        // The setter refuses hashes it has never pinned.
        XCTAssertFalse(repaired.setShareClipboard(
            publicKeyHash: "0000", share: true))
    }
}

fileprivate extension ClientCoreHarness
where Host == ClipboardClientGateTests.ClipboardHostStandIn {
    convenience init(
        host: Host,
        coreConfig: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig()
    ) throws {
        try self.init(host: host, hostPort: 41_131, coreConfig: coreConfig)
    }

    var clipboardEvents: [String] {
        events.compactMap {
            if case .hostClipboardChanged(let text) = $0 { return text }
            return nil
        }
    }
}
