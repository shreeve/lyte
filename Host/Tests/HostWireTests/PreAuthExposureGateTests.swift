import XCTest
import HostSession
import HostWire
import HostWireTestKit
import LyteWire
import LyteWireTestKit

// What an unauthenticated sender can make the host do. A forged datagram on
// a channel the session never reads, or naming another session's conn-id,
// costs no AEAD open. A message 1 from a spoofable source gets its one
// answer and nothing more until the initiator proves key possession.
final class PreAuthExposureGateTests: XCTestCase {
    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_041,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    private func harness() -> HostSessionHarness {
        HostSessionHarness(
            config: SessionConfig(
                crypto: .noise(hostStatic: NoiseKeyPair.generate()),
                rateBitsPerSecond: 20_000_000
            ),
            tuple: Self.tupleA,
            rng: SplitMix64(seed: 0x9A07)
        )
    }

    func testUnreadChannelsAndForeignConnIdsAreRefusedBeforeTheAead() throws {
        let host = harness()
        var client = try host.connectClient(declaring: nil)
        try host.deliver(to: &client, at: 0)
        _ = host.receive(
            try client.datagram(body: [0x00], timestamp: 1), at: 1_000)
        XCTAssertTrue(host.session.isPeerConfirmed)
        let opensBefore = host.session.counters.unsealFailures

        let forged = try Envelope(
            channel: .videoActive, seq: ChannelSeq(rawValue: 9),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
        ).encode(payload: [UInt8](repeating: 0xEE, count: 600))
        XCTAssertEqual(host.receive(forged, at: 2_000),
                       [.dropped(.unhandledChannel(2))])

        // Even a genuinely sealed datagram on an unread channel is refused
        // on its header alone.
        XCTAssertEqual(
            host.receive(
                try client.datagram(
                    channel: .audio, body: [1, 2, 3], timestamp: 3),
                at: 3_000),
            [.dropped(.unhandledChannel(1))])

        let foreign = try ConnectionId(bytes: [9, 9, 9, 9, 9, 9, 9, 9])
        XCTAssertNotEqual(foreign, host.session.connectionId)
        XCTAssertEqual(
            host.receive(
                try client.datagram(
                    body: [0x00], timestamp: 4,
                    extensions: [foreign.wireExtension]),
                at: 4_000),
            [.dropped(.foreignConnectionId)])
        XCTAssertEqual(host.session.counters.unsealFailures, opensBefore,
                       "no refusal above reached the AEAD")
    }

    func testAnUnconfirmedSessionSendsNothingPastItsAnswer() throws {
        let host = harness()
        var client = try host.connectClient(declaring: nil)
        let answered = host.sent.count
        XCTAssertEqual(answered, 3,
                       "message 2, the session-start beacon, the declaration")

        // Ten seconds of timer wakes with no authenticated word back: no
        // 1 Hz beacons, no ARQ retransmits of the declaration.
        for t in stride(from: UInt64(100_000), through: 10_000_000,
                        by: 100_000) {
            _ = host.advance(to: t)
            XCTAssertNil(
                host.session.nextWake(now: t * 1_000).flatMap {
                    $0 <= t * 1_000 ? $0 : nil
                },
                "nothing parked may read as due")
        }
        XCTAssertEqual(host.sent.count, answered)

        // Key possession proven: the parked timers resume.
        try host.deliver(to: &client, at: 10_000_000)
        _ = host.receive(
            try client.datagram(body: [0x00], timestamp: 10_000_001),
            at: 10_000_100)
        XCTAssertTrue(host.session.isPeerConfirmed)
        _ = host.advance(to: 10_000_200)
        let resumed = host.sent.dropFirst(answered)
        XCTAssertTrue(resumed.contains { datagram in
            guard case .plain(_, let plaintext)? = try? client.absorb(
                datagram.bytes, nowMicros: 10_000_200)
            else { return false }
            return plaintext.first == CtrlMessageType.clockBeacon
        }, "the beacon cadence resumes once confirmed")
    }
}
