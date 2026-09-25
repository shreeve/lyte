import XCTest
import LyteClientTestKit
import Foundation
import LyteTransport
import LyteWire
import LyteWireTestKit

// Clipboard text (key 10) through the real core against a scripted host in
// virtual time: a local copy rides as one byte-exact 0x1A (the 65,536-byte
// ceiling included), a host announce surfaces and its pasteboard echo is
// suppressed; consent gates both directions and the live toggle flips
// them; against a host without key 10 the share is refused before a byte
// leaves and hostile or role-confused words drop loud; over-ceiling copies
// suppress as weather.

final class ClipboardClientGateTests: XCTestCase {

    // MARK: - The scripted host

    /// A key-10 host that records every 0x1A it consumes.
    fileprivate final class ClipboardHostStandIn: DeclaringHost {
        var setsReceived: [[UInt8]] = []

        init(localCapabilities: Capabilities) {
            super.init(localCapabilities: localCapabilities, seed: 0xC1_15)
        }

        override func receive(
            _ message: [UInt8], on channel: ChannelId, nowMicros: UInt64
        ) throws {
            if message.first == CtrlMessageType.clipboardSet {
                setsReceived.append(message)
            }
        }
    }

    // MARK: - The client harness

    private typealias Harness = ClientCoreHarness<ClipboardHostStandIn>

    // MARK: The negotiated round trip + the boomerang proof

    func testGateShareAnnounceAndEchoSuppressionEndToEnd() throws {
        let host = ClipboardHostStandIn(
            localCapabilities: .wireDefault.declaringClipboardText())
        var config = LyteUdpSessionCoreConfig()
        config.shareClipboard = true   // the per-host default, ON
        let harness = try Harness(host: host, coreConfig: config)
        var t = try harness.openAndSettle()

        XCTAssertEqual(host.agreed?.clipboardText, true,
                       "the host must see key 10 in the client's 0x0F")
        XCTAssertTrue(harness.core.clipboardNegotiated)
        XCTAssertTrue(harness.core.control.clipboardSharingEnabled)

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
    }

    // MARK: Consent gates both directions, live toggle

    func testGateSharingOffMeansNothingLeavesAndNothingLands() throws {
        let host = ClipboardHostStandIn(
            localCapabilities: .wireDefault.declaringClipboardText())
        // Default config: consent OFF (no per-host default set).
        let harness = try Harness(host: host)
        var t = try harness.openAndSettle()
        XCTAssertTrue(harness.core.clipboardNegotiated,
                      "capability negotiates regardless — dialect, not consent")
        XCTAssertFalse(harness.core.control.clipboardSharingEnabled)

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
    }

    // MARK: The rule-3 gate + the ceiling

    func testGateUnnegotiatedRefusalsHostileDropsAndOverBudget() throws {
        // A v1 host: declares, but never key 10.
        let host = ClipboardHostStandIn(localCapabilities: .wireDefault)
        var config = LyteUdpSessionCoreConfig()
        config.shareClipboard = true   // even with consent on
        let harness = try Harness(host: host, coreConfig: config)
        var t = try harness.openAndSettle()
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
        var t2 = try negotiated.openAndSettle()
        let oneOver = String(
            repeating: "a", count: ClipboardWire.maxTextByteCount + 1)
        XCTAssertEqual(
            negotiated.core.shareLocalClipboard(
                oneOver, now: ClientTimestamp(microseconds: t2)),
            .overBudget(ClipboardWire.maxTextByteCount + 1)
        )
        try negotiated.settle(t: &t2)
        XCTAssertEqual(negotiatedHost.setsReceived, [])
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
