import XCTest
import Foundation
import HostCore
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

final class CookieGateTests: XCTestCase {

    private static let secret = [UInt8](repeating: 0x5A, count: 32)
    private static let tupleBytes = Array("10.0.0.23:61000".utf8)
    /// A stand-in message 1 for the gate-level legs (the gate never
    /// parses it — only the cookie MAC binds it).
    private static let msg1 = [UInt8](repeating: 0xC3, count: 96)

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_157,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    // MARK: Gate level

    func testHandshakeGateAloneOwnsCookieModeTransitions() throws {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false
        )
        components.removeLast(3)
        let packageRoot = components.joined(separator: "/")
        let session = try String(contentsOfFile:
            packageRoot + "/Sources/HostWire/Session.swift",
            encoding: .utf8
        )

        XCTAssertTrue(session.contains("decision.cookieModeChangedTo"))
        XCTAssertTrue(session.contains("switch decision.admission"))
        XCTAssertFalse(session.contains("lastCookieMode"))
        XCTAssertFalse(session.contains("noteCookieModeTransition"))

        let gate = try String(contentsOfFile:
            packageRoot + "/Sources/HostWire/HandshakeGate.swift",
            encoding: .utf8
        )
        XCTAssertTrue(gate.contains("public struct Decision"))
        XCTAssertTrue(gate.contains("let previousCookieMode = cookieMode"))
    }

    /// No secret = the pure HS-9 posture: the token bucket admits the
    /// burst and throttles the rest; require-cookie never engages.
    func testDisabledWithoutSecretIsThePureTokenBucket() {
        var gate = HandshakeGate(config: .init(ratePerSecond: 10, burst: 10))
        var admits = 0, drops = 0
        for i in 0..<200 {
            let decision = gate.admitMessage1(
                presentedCookie: nil, clientTuple: Self.tupleBytes,
                message1: Self.msg1[...], now: 1_000 + UInt64(i)
            )
            XCTAssertNil(decision.cookieModeChangedTo)
            switch decision.admission {
            case .admit: admits += 1
            case .drop(.throttled): drops += 1
            default: XCTFail("no cookie machinery without a secret")
            }
        }
        XCTAssertEqual(admits, 10, "exactly the burst is admitted")
        XCTAssertEqual(drops, 190)
        XCTAssertFalse(gate.cookieMode)
        XCTAssertEqual(gate.challengesMinted, 0)
    }

    /// The flood detector flips ON at the enter threshold and OFF at the
    /// exit threshold, with hysteresis (the window ages arrivals out).
    func testFloodEngagesThenClearsWithHysteresis() {
        var gate = HandshakeGate(config: .init(
            cookieSecret: Self.secret,
            cookieEnterThreshold: 5, cookieExitThreshold: 2,
            floodWindowNS: 1_000_000_000
        ))
        // Four arrivals in the window: still under the enter threshold.
        for i in 0..<4 {
            let decision = gate.admitMessage1(
                presentedCookie: nil, clientTuple: Self.tupleBytes,
                message1: Self.msg1[...], now: UInt64(i) * 1_000_000
            )
            XCTAssertFalse(gate.cookieMode)
            XCTAssertNil(decision.cookieModeChangedTo)
        }
        // The fifth crosses the enter threshold → engaged.
        let engaged = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tupleBytes,
            message1: Self.msg1[...], now: 4_000_000
        )
        XCTAssertTrue(gate.cookieMode, "5 arrivals in 1 s engages the dial")
        XCTAssertEqual(engaged.cookieModeChangedTo, true)

        let held = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tupleBytes,
            message1: Self.msg1[...], now: 5_000_000
        )
        XCTAssertTrue(gate.cookieMode)
        XCTAssertNil(held.cookieModeChangedTo,
                     "remaining in the same posture emits no second edge")

        // Let the window drain: an arrival 2 s later sees only itself
        // in the window (1 ≤ exit threshold 2) → cleared.
        let cleared = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tupleBytes,
            message1: Self.msg1[...], now: 2_000_000_000
        )
        XCTAssertFalse(gate.cookieMode, "the window drained — pressure gone")
        XCTAssertEqual(cleared.cookieModeChangedTo, false)
        // And with the dial cleared, that lone un-cookied msg1 falls to
        // the token bucket (admitted, not challenged).
        XCTAssertEqual(cleared.admission, .admit)
        let stayedClear = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tupleBytes,
            message1: Self.msg1[...], now: 2_100_000_000
        )
        XCTAssertNil(stayedClear.cookieModeChangedTo,
                     "remaining clear emits no second exit edge")
    }

    /// Under flood, an un-cookied msg1 is challenged with a well-formed,
    /// verifiable cookie — and the challenge reply is SMALLER than the
    /// msg1 it answers (no amplification; the QUIC-Retry property).
    func testUncookiedUnderFloodIsChallengedBoundedAndVerifiable() throws {
        var gate = HandshakeGate(config: .init(
            cookieSecret: Self.secret,
            cookieEnterThreshold: 1, cookieExitThreshold: 0
        ))
        let decision = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tupleBytes,
            message1: Self.msg1[...], now: 10_000
        )
        XCTAssertEqual(decision.cookieModeChangedTo, true)
        guard case .challenge(let cookie) = decision.admission else {
            return XCTFail("a flooded un-cookied msg1 must be challenged")
        }
        XCTAssertEqual(gate.challengesMinted, 1)
        XCTAssertEqual(cookie.count, RetryCookie.byteCount, "24-byte cookie")
        // The cookie the challenge carries verifies for this exact
        // (tuple, msg1) inside its lifetime.
        XCTAssertTrue(RetryCookie.verify(
            cookie: cookie[...], clientTuple: Self.tupleBytes,
            message1: Self.msg1[...], now: 20_000, secrets: [Self.secret]
        ))
        // Bounded cost: the wire challenge (0x13 + len + cookie) is
        // smaller than the message 1 it answered.
        let wire = try RetryChallenge(cookie: cookie).encode()
        XCTAssertLessThan(wire.count, Self.msg1.count,
            "the challenge reply must not amplify the request")
    }

    /// A verifying cookie admits without spending a bucket token; a
    /// forged/stale/mismatched cookie is dropped before any Noise.
    func testValidCookieAdmitsInvalidCookieDrops() throws {
        var gate = HandshakeGate(config: .init(
            cookieSecret: Self.secret,
            cookieEnterThreshold: 1, cookieExitThreshold: 0
        ))
        // Mint one via a challenge.
        guard case .challenge(let cookie) = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tupleBytes,
            message1: Self.msg1[...], now: 1_000
        ).admission else { return XCTFail("expected a challenge") }

        // The echoed cookie admits.
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: cookie[...], clientTuple: Self.tupleBytes,
            message1: Self.msg1[...], now: 2_000
        ).admission, .admit)
        XCTAssertEqual(gate.cookiesVerified, 1)

        // A tampered cookie drops.
        var forged = cookie
        forged[forged.count - 1] ^= 0xFF
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: forged[...], clientTuple: Self.tupleBytes,
            message1: Self.msg1[...], now: 3_000
        ).admission, .drop(.cookieInvalid))

        // The right cookie for the WRONG msg1 drops (the binding holds).
        let otherMsg1 = [UInt8](repeating: 0x11, count: 96)
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: cookie[...], clientTuple: Self.tupleBytes,
            message1: otherMsg1[...], now: 4_000
        ).admission, .drop(.cookieInvalid))

        // The right cookie from the WRONG address drops.
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: cookie[...],
            clientTuple: Array("10.0.0.99:5000".utf8),
            message1: Self.msg1[...], now: 5_000
        ).admission, .drop(.cookieInvalid))
        XCTAssertEqual(gate.cookiesRejected, 3)
    }

    func testPresentedCookieBranchesCarryTheSameExactModeEdge() throws {
        var gate = HandshakeGate(config: .init(
            cookieSecret: Self.secret,
            cookieEnterThreshold: 2, cookieExitThreshold: 1,
            floodWindowNS: 1_000_000_000
        ))
        let first = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tupleBytes,
            message1: Self.msg1[...], now: 0
        )
        XCTAssertNil(first.cookieModeChangedTo)

        let forged = [UInt8](repeating: 0xEE, count: RetryCookie.byteCount)
        let entered = gate.admitMessage1(
            presentedCookie: forged[...], clientTuple: Self.tupleBytes,
            message1: Self.msg1[...], now: 1
        )
        XCTAssertEqual(entered.admission, .drop(.cookieInvalid))
        XCTAssertEqual(entered.cookieModeChangedTo, true)

        let later = UInt64(2_000_000_000)
        let cookie = try RetryCookie.mint(
            clientTuple: Self.tupleBytes, message1: Self.msg1[...],
            now: later, secret: Self.secret
        )
        let cleared = gate.admitMessage1(
            presentedCookie: cookie[...], clientTuple: Self.tupleBytes,
            message1: Self.msg1[...], now: later
        )
        XCTAssertEqual(cleared.admission, .admit)
        XCTAssertEqual(cleared.cookieModeChangedTo, false)
    }

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

        print("HS-21 gate (session): 30-msg1 flood → dial ENGAGED, "
            + "\(session.counters.handshakeChallengesMinted) 0x13 minted "
            + "(no Noise), legit client established via 0x14 in one extra "
            + "round trip")
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
