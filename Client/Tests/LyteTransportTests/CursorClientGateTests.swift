import XCTest
import LyteClientTestKit
import Foundation
import LyteTransport
import LyteWire
import LyteWireTestKit

// Cursor shapes (key 13) through the real core against a scripted host:
// each 0x24 surfaces exactly once, byte-exact, visible and hidden alike;
// without key 13 a 0x24 drops without an event, and malformed bytes count
// and never trap.

final class CursorClientGateTests: XCTestCase {

    /// The same hand-built shape the host gate pins.
    private static let arrow = CursorShape(
        width: 2, height: 1, hotspotX: 1, hotspotY: 0,
        pixels: [0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    )

    // MARK: - The scripted host

    fileprivate final class CursorHostStandIn: ScriptedHost {
        var peer: SealedCtrlPeer<HostClock>
        var handshakeOutbox: [[UInt8]] = []
        let localCapabilities: Capabilities

        // Evidence.
        var agreed: Capabilities?
        var receivedReliableTypes: [UInt8] = []

        var progressMark: Int { receivedReliableTypes.count }

        init(localCapabilities: Capabilities) {
            var rng = SplitMix64(seed: 0xE3_24)
            peer = SealedCtrlPeer(
                connectionId: ConnectionId.random(using: &rng))
            peer.openChannels = [.ctrl]
            self.localCapabilities = localCapabilities
        }

        func didEstablish() throws {
            try declare(localCapabilities)
        }

        func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            guard case .reliable(_, _, let events) =
                try peer.absorb(bytes, nowMicros: nowMicros)
            else { return }
            for case .message(_, let message) in events {
                receivedReliableTypes.append(message.first ?? 0)
                if message.first == CtrlMessageType.capabilityDeclaration,
                   let intersection = try peer.receiveDeclaration(message) {
                    agreed = intersection
                }
            }
        }
    }

    // MARK: - The client harness

    private typealias Harness = ClientCoreHarness<CursorHostStandIn>

    // MARK: Negotiated shapes surface exactly once

    func testGateNegotiatedShapesSurfaceByteExact() throws {
        let host = CursorHostStandIn(
            localCapabilities: .wireDefault.declaringCursorShape())
        let harness = try Harness(host: host)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        XCTAssertEqual(host.agreed?.cursorShape, true,
                       "the host must see key 13 in the client's 0x0F")

        // A visible shape surfaces exactly once, byte-exact through
        // real ARQ.
        try host.injectReliable(try Self.arrow.encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.cursorEvents, [Self.arrow])

        // The hidden state travels — it is a STATE, not an omission.
        try host.injectReliable(
            try CursorShape.hidden.encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.cursorEvents, [Self.arrow, .hidden])
        XCTAssertTrue(harness.cursorEvents.last?.isHidden == true)

        let counters = harness.core.snapshotCounters()
        XCTAssertEqual(counters.cursorShapesReceived, 2)
        XCTAssertEqual(counters.malformedReliableMessages, 0)
    }

    // MARK: The rule-3 gate and hostile bytes

    func testGateUnnegotiatedShapeDropsAndMalformedNeverTraps() throws {
        // A host that never declared key 13 (a portal-era host).
        let host = CursorHostStandIn(localCapabilities: .wireDefault)
        let harness = try Harness(host: host)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(host.agreed?.cursorShape, false)

        // An out-of-agreement 0x24: dropped, no event — nothing can
        // dress the view outside the agreement.
        try host.injectReliable(try Self.arrow.encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.cursorEvents, [])
        XCTAssertEqual(
            harness.core.snapshotCounters().cursorShapesReceived, 0)

        // Malformed 0x24 bytes (truncated header; a lying pixel
        // count): counted as malformed, never trapped, no event.
        try host.injectReliable([0x24, 0x01, 0x00], nowMicros: t)
        try host.injectReliable(
            [0x24, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
             0xFF],
            nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.cursorEvents, [])
        XCTAssertEqual(
            harness.core.snapshotCounters().malformedReliableMessages, 2)
    }
}

fileprivate extension ClientCoreHarness
where Host == CursorClientGateTests.CursorHostStandIn {
    convenience init(
        host: Host,
        coreConfig: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig()
    ) throws {
        try self.init(host: host, hostPort: 41_132, coreConfig: coreConfig)
    }

    var cursorEvents: [CursorShape] {
        events.compactMap {
            if case .hostCursorShapeChanged(let shape) = $0 {
                return shape
            }
            return nil
        }
    }
}
