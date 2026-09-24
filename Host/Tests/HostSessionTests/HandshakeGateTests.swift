import HostSession
import LyteWire
import XCTest

final class HandshakeGateTests: XCTestCase {
    private static let secret = [UInt8](repeating: 0x5A, count: 32)
    private static let tuple = Array("10.0.0.23:61000".utf8)
    /// A stand-in message 1 (the gate never parses it — only the cookie
    /// MAC binds it).
    private static let msg1 = [UInt8](repeating: 0xC3, count: 96)

    private func message1(_ seed: UInt8) -> [UInt8] {
        [UInt8](repeating: seed, count: 96)
    }

    /// A verified cookie proves an address, not good intent: replaying the
    /// same RetryHandshake1 must not buy a Noise handshake per datagram.
    func testReplayedCookieIsAdmittedOnce() throws {
        var gate = HandshakeGate(config: .init(
            cookieSecret: Self.secret,
            cookieEnterThreshold: 1, cookieExitThreshold: 0))
        let msg1 = message1(0xC3)
        let cookie = try RetryCookie.mint(
            clientTuple: Self.tuple, message1: msg1[...],
            now: 1_000, secret: Self.secret)
        var admits = 0
        // One second of line-rate replays inside the cookie's lifetime.
        for index in 0..<1_000 {
            let decision = gate.admitMessage1(
                presentedCookie: cookie[...], clientTuple: Self.tuple,
                message1: msg1[...], now: 2_000 + UInt64(index) * 1_000_000)
            if decision.admission == .admit { admits += 1 }
        }
        XCTAssertEqual(admits, 1)
        XCTAssertEqual(gate.cookiesVerified, 1_000)
        XCTAssertEqual(gate.cookiesThrottled, 999)
    }

    /// Distinct verified cookies (one per honest client) spend their own
    /// budget: a burst is admitted, the rest waits for refill, and the
    /// message-1 bucket is never touched.
    func testDistinctCookiesSpendTheCookieBudget() throws {
        var gate = HandshakeGate(config: .init(
            ratePerSecond: 1, burst: 1,
            cookieSecret: Self.secret,
            cookieEnterThreshold: 1, cookieExitThreshold: 0,
            cookieAdmissionsPerSecond: 10, cookieAdmissionBurst: 5))
        var admits = 0
        for seed in 0..<20 {
            let msg1 = message1(UInt8(seed))
            let cookie = try RetryCookie.mint(
                clientTuple: Self.tuple, message1: msg1[...],
                now: 1_000, secret: Self.secret)
            let decision = gate.admitMessage1(
                presentedCookie: cookie[...], clientTuple: Self.tuple,
                message1: msg1[...], now: 2_000)
            if decision.admission == .admit { admits += 1 }
        }
        XCTAssertEqual(admits, 5, "the burst, then the rate")

        let later = message1(0xEE)
        let cookie = try RetryCookie.mint(
            clientTuple: Self.tuple, message1: later[...],
            now: 100_002_000, secret: Self.secret)
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: cookie[...], clientTuple: Self.tuple,
            message1: later[...], now: 100_002_000
        ).admission, .admit, "100 ms refills one cookie admission")
    }

    /// Without cookies the flood detector still counts only the window:
    /// arrivals older than it fall out and the dial clears.
    func testFloodWindowForgetsOldArrivals() {
        var gate = HandshakeGate(config: .init(
            cookieSecret: Self.secret,
            cookieEnterThreshold: 3, cookieExitThreshold: 1,
            floodWindowNS: 1_000))
        let msg1 = message1(1)
        for now: UInt64 in [0, 1, 2] {
            _ = gate.admitMessage1(
                presentedCookie: nil, clientTuple: Self.tuple,
                message1: msg1[...], now: now)
        }
        XCTAssertTrue(gate.cookieMode)
        let quiet = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tuple,
            message1: msg1[...], now: 5_000)
        XCTAssertEqual(quiet.cookieModeChangedTo, false)
    }

    /// No secret = the pure HS-9 posture: the token bucket admits the
    /// burst and throttles the rest; require-cookie never engages.
    func testDisabledWithoutSecretIsThePureTokenBucket() {
        var gate = HandshakeGate(config: .init(ratePerSecond: 10, burst: 10))
        var admits = 0, drops = 0
        for i in 0..<200 {
            let decision = gate.admitMessage1(
                presentedCookie: nil, clientTuple: Self.tuple,
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
                presentedCookie: nil, clientTuple: Self.tuple,
                message1: Self.msg1[...], now: UInt64(i) * 1_000_000
            )
            XCTAssertFalse(gate.cookieMode)
            XCTAssertNil(decision.cookieModeChangedTo)
        }
        // The fifth crosses the enter threshold → engaged.
        let engaged = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tuple,
            message1: Self.msg1[...], now: 4_000_000
        )
        XCTAssertTrue(gate.cookieMode, "5 arrivals in 1 s engages the dial")
        XCTAssertEqual(engaged.cookieModeChangedTo, true)

        let held = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tuple,
            message1: Self.msg1[...], now: 5_000_000
        )
        XCTAssertTrue(gate.cookieMode)
        XCTAssertNil(held.cookieModeChangedTo,
                     "remaining in the same posture emits no second edge")

        // Let the window drain: an arrival 2 s later sees only itself
        // in the window (1 ≤ exit threshold 2) → cleared.
        let cleared = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tuple,
            message1: Self.msg1[...], now: 2_000_000_000
        )
        XCTAssertFalse(gate.cookieMode, "the window drained — pressure gone")
        XCTAssertEqual(cleared.cookieModeChangedTo, false)
        // And with the dial cleared, that lone un-cookied msg1 falls to
        // the token bucket (admitted, not challenged).
        XCTAssertEqual(cleared.admission, .admit)
        let stayedClear = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tuple,
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
            presentedCookie: nil, clientTuple: Self.tuple,
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
            cookie: cookie[...], clientTuple: Self.tuple,
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
            presentedCookie: nil, clientTuple: Self.tuple,
            message1: Self.msg1[...], now: 1_000
        ).admission else { return XCTFail("expected a challenge") }

        // The echoed cookie admits.
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: cookie[...], clientTuple: Self.tuple,
            message1: Self.msg1[...], now: 2_000
        ).admission, .admit)
        XCTAssertEqual(gate.cookiesVerified, 1)

        // A tampered cookie drops.
        var forged = cookie
        forged[forged.count - 1] ^= 0xFF
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: forged[...], clientTuple: Self.tuple,
            message1: Self.msg1[...], now: 3_000
        ).admission, .drop(.cookieInvalid))

        // The right cookie for the WRONG msg1 drops (the binding holds).
        let otherMsg1 = [UInt8](repeating: 0x11, count: 96)
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: cookie[...], clientTuple: Self.tuple,
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
            presentedCookie: nil, clientTuple: Self.tuple,
            message1: Self.msg1[...], now: 0
        )
        XCTAssertNil(first.cookieModeChangedTo)

        let forged = [UInt8](repeating: 0xEE, count: RetryCookie.byteCount)
        let entered = gate.admitMessage1(
            presentedCookie: forged[...], clientTuple: Self.tuple,
            message1: Self.msg1[...], now: 1
        )
        XCTAssertEqual(entered.admission, .drop(.cookieInvalid))
        XCTAssertEqual(entered.cookieModeChangedTo, true)

        let later = UInt64(2_000_000_000)
        let cookie = try RetryCookie.mint(
            clientTuple: Self.tuple, message1: Self.msg1[...],
            now: later, secret: Self.secret
        )
        let cleared = gate.admitMessage1(
            presentedCookie: cookie[...], clientTuple: Self.tuple,
            message1: Self.msg1[...], now: later
        )
        XCTAssertEqual(cleared.admission, .admit)
        XCTAssertEqual(cleared.cookieModeChangedTo, false)
    }
}
