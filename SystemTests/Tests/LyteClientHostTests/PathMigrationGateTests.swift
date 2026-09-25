import XCTest
import HostSession
import HostWire
import LyteWire

// Host-validated path migration end to end: the real native client core
// roams to a new source tuple, its next conn-id-tagged datagram draws the
// shipping Session's PathChallenge on that tuple, and the client's
// PathResponse — sealed through the real ReceiveDemux/TransportSender pair
// — promotes it. Only UDP IO and the clocks are replaced.

final class PathMigrationGateTests: XCTestCase {
    private static let roamedTuple = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_081,
        remoteAddress: "192.168.7.40", remotePort: 52_310
    )

    func testClientAnswersThePathChallengeAndTheHostPromotesTheNewTuple()
        throws
    {
        let host = SystemHostSession()
        let client = try SystemClient(host: host)
        try client.core.open(now: ClientTimestamp(microseconds: 1_000))
        var t: UInt64 = 1_000
        var forwarded = 0
        try client.settleStartup(forwarded: &forwarded, at: t)
        XCTAssertEqual(host.session.validator.primary.tuple,
                       SystemHostSession.initialClientTuple)

        // The Mac changes networks: every later datagram arrives from the
        // new tuple. A reliable word carries the learned conn-id tag.
        host.harness.tuple = Self.roamedTuple
        t += 10_000
        client.clock.advance(to: t)
        try client.core.sendInput(
            .keyKeycode(keycode: 30, pressed: true), now: ClientTimestamp(microseconds: t))
        try client.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertTrue(host.events.contains {
            if case .path(.sendChallenge(on: Self.roamedTuple, _)) = $0 {
                return true
            }
            return false
        }, "an authenticated tagged datagram from a new tuple is probed")

        for datagram in host.takeReadyControlDatagrams() {
            client.deliver(datagram, at: t)
        }
        try client.pumpOutboundToHost(forwarded: &forwarded)

        XCTAssertEqual(host.session.validator.primary.tuple, Self.roamedTuple,
                       "the echoed token promotes the probed tuple")
        XCTAssertTrue(host.events.contains {
            if case .path(.freshKeyframeNeeded) = $0 { return true }
            return false
        }, "video restarts from an IDR on the new path")
    }
}
