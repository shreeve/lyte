import HostSession
import HostWire
import LyteTransport
import LyteWire
import XCTest

// Under flood the host answers a bare message 1 with an unsealed
// RetryChallenge from its listening socket; the shipping client initiator
// must read it, echo the cookie in a RetryHandshake1 and complete the
// handshake on the host's answer.

final class HandshakeCookieGateTests: XCTestCase {
    func testTheClientCompletesTheHandshakeThroughARetryChallenge() throws {
        let host = SystemHostSession(gate: HandshakeGate.Config(
            cookieSecret: [UInt8](repeating: 0x5A, count: 32),
            cookieEnterThreshold: 1, cookieExitThreshold: 0))
        let crypto = try NoiseTransportCrypto(
            hostAddress: "10.0.0.249", hostPort: 41_007,
            hostStaticPublicKey: host.staticKeys.publicKey,
            retry: .init(attempts: 2, intervalMicroseconds: 200_000))
        try crypto.performHandshake(io: host)

        XCTAssertEqual(crypto.retryChallengesAnsweredSnapshot, 1)
        let counters = host.harness.acceptor.counters
        XCTAssertEqual(counters.challengesMinted, 1)
        XCTAssertEqual(counters.cookiesVerified, 1)
        XCTAssertTrue(host.events.contains {
            if case .handshakeCompleted = $0 { return true }
            return false
        })
    }
}
