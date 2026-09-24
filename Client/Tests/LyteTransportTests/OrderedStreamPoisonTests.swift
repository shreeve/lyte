import LyteClientTestKit
import LyteTransport
import LyteWire
import LyteWireTestKit
import XCTest

/// A host message over the shared 262,144 B ceiling poisons the ordered
/// CTRL stream: nothing on it can ever be delivered in order again. The
/// client ends the session with a typed teardown instead of streaming on
/// deaf to every later control word.
final class OrderedStreamPoisonTests: XCTestCase {
    fileprivate final class OversizeHost: ScriptedHost {
        var peer: SealedCtrlPeer<HostClock>
        var handshakeOutbox: [[UInt8]] = []
        var teardowns: [SessionTeardownReason] = []
        var progressMark: Int { teardowns.count }

        init() {
            var rng = SplitMix64(seed: 0x0B_5E)
            // This host's ceiling is not the client's: it will send what
            // the client must refuse.
            var config = ArqConfig()
            config.maxMessageByteCount = 1 << 20
            peer = SealedCtrlPeer(
                connectionId: ConnectionId.random(using: &rng),
                arqConfig: config)
            peer.openChannels = [.ctrl]
        }

        func didEstablish() throws {
            try declare(.wireDefault)
        }

        func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            guard case .reliable(_, _, let events) =
                try peer.absorb(bytes, nowMicros: nowMicros)
            else { return }
            for case .message(_, let message) in events
            where message.first == CtrlMessageType.sessionTeardown {
                teardowns.append(try SessionTeardown.decode(message).reason)
            }
        }
    }

    func testOverBudgetHostMessageEndsTheSessionWithATypedTeardown() throws {
        let host = OversizeHost()
        let harness = try ClientCoreHarness(host: host, hostPort: 41_151)
        var t: UInt64 = 1_000
        harness.clock.value = t
        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertFalse(harness.core.orderedStreamPoisoned)

        try host.injectReliable(
            [CtrlMessageType.clipboardAnnounce]
                + [UInt8](repeating: 0x61, count: 262_144),
            nowMicros: t)
        try harness.settle(t: &t)

        XCTAssertTrue(harness.core.orderedStreamPoisoned)
        XCTAssertEqual(harness.core.state, .closed)
        XCTAssertEqual(host.teardowns, [.shuttingDown],
                       "the host hears the typed goodbye exactly once")
        XCTAssertTrue(harness.events.contains {
            if case .closed(.localTeardown(.shuttingDown)) = $0 { return true }
            return false
        })
    }
}
