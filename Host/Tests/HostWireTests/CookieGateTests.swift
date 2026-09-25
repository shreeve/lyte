import XCTest
import HostSession
import HostWire
import HostWireTestKit
import LyteWire
import LyteWireTestKit

/// Require-cookie mode end to end, through the acceptor and the session it
/// answers: a flood engages the dial, and a legitimate client caught in it
/// still establishes with one extra round trip. The acceptor's own cases
/// are HostSessionTests' HandshakeAcceptorTests; the gate's are
/// HandshakeGateTests.
final class CookieGateTests: XCTestCase {
    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_157,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    func testAFloodEngagesTheDialAndACookieAdmitsTheLegitimateClient() throws {
        let host = HostSessionHarness(
            config: SessionConfig(rateBitsPerSecond: 20_000_000),
            acceptor: HandshakeAcceptor.Config(
                hostStatic: .generate(),
                gate: HandshakeGate.Config(
                    cookieSecret: [UInt8](repeating: 0x5A, count: 32),
                    cookieEnterThreshold: 6, cookieExitThreshold: 2,
                    floodWindowNS: 10_000_000_000)),
            tuple: Self.tupleA,
            rng: SplitMix64(seed: 0xC00C1E)
        )
        var rng = SplitMix64(seed: 0xF100D)
        for i in 0..<30 {
            let garbage = (0..<96).map { _ in UInt8.random(in: 0...255, using: &rng) }
            host.receive(try Envelope(
                channel: .ctrl, seq: ChannelSeq(rawValue: UInt16(i)),
                frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
            ).encode(payload: [CtrlMessageType.noiseHandshake1] + garbage),
                at: 1 + UInt64(i))
        }
        XCTAssertTrue(host.acceptor.cookieMode)
        XCTAssertNil(host.currentSession, "no garbage message 1 establishes anything")
        let floodChallenges = host.challenges.count
        XCTAssertGreaterThan(floodChallenges, 0)

        // A legitimate client dials into the flood: challenged, not
        // admitted.
        var client = try SealedCtrlPeer<ClientClock>(
            initiatorTo: host.acceptor.hostStaticPublicKey)
        let message1Datagram = try client.message1Datagram(timestamp: 2)
        XCTAssertEqual(host.receive(message1Datagram, at: 100), [])
        XCTAssertNil(host.currentSession)
        let challengeDatagram = try XCTUnwrap(host.challenges.last)
        XCTAssertEqual(host.challenges.count, floodChallenges + 1)

        // It resubmits the same message 1 with the cookie echoed (0x14):
        // one extra round trip, and the session is up.
        let (_, payload) = try Envelope.decode(challengeDatagram[...])
        let message1 = Array(try Envelope.decode(message1Datagram[...]).1.dropFirst())
        let resubmission = try client.datagram(
            body: RetryHandshake1(
                echoing: RetryChallenge.decode(payload), message1: message1
            ).encode(),
            sealed: false, timestamp: 3)
        XCTAssertTrue(host.receive(resubmission, at: 200).contains {
            if case .handshakeCompleted = $0 { return true }
            return false
        }, "a verifying cookie establishes the session")
        try host.deliver(to: &client, at: 300)
        XCTAssertTrue(client.isEstablished)
        XCTAssertEqual(host.acceptor.counters.cookiesVerified, 1)
    }
}
