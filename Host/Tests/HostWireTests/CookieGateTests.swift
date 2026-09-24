import XCTest
import Foundation
import HostCore
import HostSession
import HostWire
import LyteWire
import LyteWireTestKit

// THE GATE (HS-21, H3 Wave 0 rung D-3: "HandshakeGate cookie-mode
// escalation under load — the host finally mints a live 0x13"). W8
// landed the retry-cookie codec and the client's answer path is armed in
// every dial (NoiseTransportCrypto), but the HOST never escalated, so no
// dial ever drew a 0x13. These legs pin the host half, sans-IO:
//
//   • the dial is OFF without a cookie secret — the exact HS-9 token
//     bucket, so every pre-HS-21 test is unchanged;
//   • a msg1 flood flips require-cookie mode ON at the enter threshold
//     and back OFF at the exit threshold (hysteresis, no flap);
//   • under the flood an un-cookied msg1 is answered with a stateless
//     RetryChallenge (one HMAC, a reply SMALLER than the request, no
//     Noise, no state) instead of being dropped;
//   • a cookie that verifies admits (one extra round trip); a forged,
//     stale, wrong-tuple, or wrong-msg1 cookie is dropped before Noise;
//   • and, driven all the way through Session.receive: a flood engages
//     the dial, a legitimate client caught in it still establishes with
//     one extra round trip, and the dial clears when pressure lifts.
//
// The HandshakeGate legs of the first four bullets live beside the type,
// in HostSessionTests/HandshakeGateTests; this file drives Session.

final class CookieGateTests: XCTestCase {

    private static let secret = [UInt8](repeating: 0x5A, count: 32)

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_157,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    // MARK: Session level — the whole host half, driven live-shaped

    private func rawMessage1(hostStatic: NoiseKeyPair) throws
        -> (client: NoiseSession, message1: [UInt8]) {
        var client = try NoiseSession(
            role: .initiator, staticKeys: NoiseKeyPair.generate(),
            remoteStaticPublicKey: hostStatic.publicKey
        )
        // ONE msg1, captured verbatim (0443beb's rule — the cookie MAC
        // over exactly these bytes makes the verbatim echo mandatory).
        let message1 = try client.writeMessage1()
        return (client, message1)
    }

    private func ctrlDatagram(seq: UInt16, payload: [UInt8]) throws -> [UInt8] {
        try Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: seq),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
        ).encode(payload: payload)
    }

    /// The headline leg: a flood engages require-cookie mode on the wire,
    /// a legitimate client caught in the flood still establishes — one
    /// extra round trip via a 0x13/0x14 exchange — and the challenge
    /// cost is bounded (no Noise, no session state per flood datagram).
    func testSessionFloodEngagesDialAndCookieAdmitsLegitClient() throws {
        let hostStatic = NoiseKeyPair.generate()
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: 20_000_000,
                handshakeGate: HandshakeGate.Config(
                    ratePerSecond: 10, burst: 10,
                    cookieSecret: Self.secret,
                    cookieEnterThreshold: 6, cookieExitThreshold: 2,
                    floodWindowNS: 10_000_000_000
                )
            ),
            clientTuple: Self.tupleA, now: 0,
            rng: SplitMix64(seed: 0xC00C1E)
        ) { sent.append($0) }

        // The flood: 30 garbage message 1s in a tight window.
        var rng = SplitMix64(seed: 0xF100D)
        var engaged = false
        for i in 0..<30 {
            let garbage = (0..<96).map { _ in UInt8.random(in: 0...255, using: &rng) }
            for e in session.receive(
                try ctrlDatagram(seq: UInt16(i),
                    payload: [CtrlMessageType.noiseHandshake1] + garbage),
                from: Self.tupleA, now: 1_000 + UInt64(i) * 1_000,
                hostMicroseconds: 1
            ) {
                if case .handshakeCookieModeChanged(true) = e { engaged = true }
            }
        }
        XCTAssertTrue(engaged, "the flood must flip the dial ON on the wire")
        XCTAssertTrue(session.handshakeCookieMode)
        XCTAssertEqual(session.phase, .awaitingHandshake,
                       "no garbage msg1 establishes anything")
        XCTAssertGreaterThan(session.counters.handshakeChallengesMinted, 0,
                       "un-cookied floods draw stateless 0x13 challenges")

        // Drain the flood's challenges off the pacer and discard them:
        // the legit client's challenge must be the ONLY one we pick up.
        var pumpAt: UInt64 = 100_000
        for _ in 0..<32 { session.pump(now: pumpAt); pumpAt += 1_000_000 }
        sent.removeAll()

        // A legitimate client dials INTO the flood. Its bare msg1 is
        // challenged, not admitted.
        let (_, message1) = try rawMessage1(hostStatic: hostStatic)
        let challengedEvents = session.receive(
            try ctrlDatagram(seq: 1_000,
                payload: [CtrlMessageType.noiseHandshake1] + message1),
            from: Self.tupleA, now: pumpAt, hostMicroseconds: 2
        )
        XCTAssertTrue(challengedEvents.contains(.handshakeChallenged))
        XCTAssertEqual(session.phase, .awaitingHandshake,
                       "the legit client is challenged first, not admitted")

        // Drain the pacer so the bare 0x13 reaches the wire (the shell's
        // service pass does this after every receive).
        for _ in 0..<16 where sent.isEmpty {
            pumpAt += 1_000_000
            session.pump(now: pumpAt)
        }

        // Pull the cookie the host minted for it off the wire (the bare
        // 0x13, destined for the client's exact tuple).
        let challenge = try XCTUnwrap(sent.compactMap { datagram -> RetryChallenge? in
            guard let (env, payload) = try? Envelope.decode(datagram.bytes),
                  env.channel == .ctrl,
                  payload.first == CtrlMessageType.retryChallenge
            else { return nil }
            return try? RetryChallenge.decode(payload)
        }.first, "the host must have sent a RetryChallenge")

        // The client resubmits the SAME msg1 with the cookie echoed
        // (0x14). It admits — one extra round trip, session up.
        let admitted = session.receive(
            try ctrlDatagram(seq: 1_001, payload:
                try RetryHandshake1(echoing: challenge, message1: message1).encode()),
            from: Self.tupleA, now: pumpAt + 10_000, hostMicroseconds: 3
        )
        XCTAssertTrue(admitted.contains { if case .handshakeCompleted = $0 {
            return true } else { return false } },
            "a verifying cookie establishes the session")
        XCTAssertEqual(session.phase, .established)
        XCTAssertEqual(session.counters.handshakeCookiesVerified, 1)

        print("""
            HS-21 gate (session): 30-msg1 flood → dial ENGAGED, \
            \(session.counters.handshakeChallengesMinted) 0x13 minted \
            (no Noise), legit client established via 0x14 in one extra \
            round trip
            """)
    }

    /// A 0x14 whose cookie does not verify is dropped before any Noise.
    func testSessionRejectsBadCookieBeforeNoise() throws {
        let hostStatic = NoiseKeyPair.generate()
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: 20_000_000,
                handshakeGate: HandshakeGate.Config(
                    cookieSecret: Self.secret,
                    cookieEnterThreshold: 1, cookieExitThreshold: 0
                )
            ),
            clientTuple: Self.tupleA, now: 0,
            rng: SplitMix64(seed: 0xBADC0)
        ) { _ in }

        let (_, message1) = try rawMessage1(hostStatic: hostStatic)
        let forgedCookie = [UInt8](repeating: 0xEE, count: RetryCookie.byteCount)
        let events = session.receive(
            try ctrlDatagram(seq: 0, payload:
                try RetryHandshake1(cookie: forgedCookie, message1: message1).encode()),
            from: Self.tupleA, now: 1_000, hostMicroseconds: 1
        )
        XCTAssertTrue(events.contains(.dropped(.handshakeCookieInvalid)))
        XCTAssertEqual(session.phase, .awaitingHandshake)
        XCTAssertEqual(session.counters.handshakeCookiesRejected, 1)
    }

    /// The dial flips back to the token bucket once the flood clears —
    /// surfaced as exactly one `.handshakeCookieModeChanged(false)`.
    func testSessionDialClearsWhenPressureLifts() throws {
        let hostStatic = NoiseKeyPair.generate()
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: 20_000_000,
                handshakeGate: HandshakeGate.Config(
                    cookieSecret: Self.secret,
                    cookieEnterThreshold: 4, cookieExitThreshold: 1,
                    floodWindowNS: 1_000_000_000
                )
            ),
            clientTuple: Self.tupleA, now: 0,
            rng: SplitMix64(seed: 0xC1EA1)
        ) { _ in }

        var rng = SplitMix64(seed: 0x5EED)
        func floodOne(now: UInt64) -> [SessionEvent] {
            let garbage = (0..<96).map { _ in UInt8.random(in: 0...255, using: &rng) }
            return session.receive(
                (try? ctrlDatagram(seq: UInt16(truncatingIfNeeded: now),
                    payload: [CtrlMessageType.noiseHandshake1] + garbage)) ?? [],
                from: Self.tupleA, now: now, hostMicroseconds: 1
            )
        }
        var engaged = false
        for i in 0..<6 {
            let events = floodOne(now: 1_000 + UInt64(i) * 1_000)
            for e in events {
                if case .handshakeCookieModeChanged(true) = e { engaged = true }
            }
            if events.contains(.handshakeCookieModeChanged(requireCookie: true)) {
                XCTAssertEqual(
                    events.first,
                    .handshakeCookieModeChanged(requireCookie: true)
                )
            }
        }
        XCTAssertTrue(engaged)

        // Two seconds on, the window has drained: the next arrival sees
        // only itself and the dial clears (exactly one OFF event).
        let clearing = floodOne(now: 3_000_000_000)
        XCTAssertTrue(clearing.contains(.handshakeCookieModeChanged(requireCookie: false)))
        XCTAssertEqual(
            clearing.first,
            .handshakeCookieModeChanged(requireCookie: false)
        )
        XCTAssertFalse(session.handshakeCookieMode)
    }
}
