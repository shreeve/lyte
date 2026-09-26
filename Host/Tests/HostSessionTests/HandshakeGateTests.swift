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

    private func address(_ index: Int) -> [UInt8] {
        Array("10.0.\(index / 256).\(index % 256):61000".utf8)
    }

    /// The share key of an "address:port" tuple, as Session derives it.
    private func shareKey(_ tuple: [UInt8]) -> [UInt8] {
        let text = String(decoding: tuple, as: UTF8.self)
        let address = text.split(separator: ":").dropLast().joined(separator: ":")
        return HandshakeGate.addressShareKey(address)
    }

    /// A host-wide refusal leaves the refused address's share whole: once
    /// the host budget refills, that address is admitted even though its
    /// own share refills far slower.
    func testAHostWideRefusalDoesNotSpendTheAddressShare() throws {
        var gate = HandshakeGate(config: .init(
            cookieSecret: Self.secret,
            cookieEnterThreshold: 1, cookieExitThreshold: 0,
            cookieAdmissionsPerSecond: 10, cookieAdmissionBurst: 1,
            cookieAdmissionsPerAddressPerSecond: 1))
        func present(_ tuple: [UInt8], seed: UInt8, now: UInt64) throws
            -> HandshakeGate.Admission {
            let msg1 = message1(seed)
            let cookie = try RetryCookie.mint(
                clientTuple: tuple, message1: msg1[...],
                now: 1_000, secret: Self.secret)
            return gate.admitMessage1(
                presentedCookie: cookie[...], clientTuple: tuple,
                clientAddress: shareKey(tuple),
                message1: msg1[...], now: now).admission
        }
        XCTAssertEqual(try present(address(1), seed: 1, now: 2_000), .admit)
        XCTAssertEqual(try present(address(2), seed: 2, now: 2_000),
                       .drop(.throttled), "the host budget is spent")
        XCTAssertEqual(try present(address(2), seed: 3, now: 100_002_000),
                       .admit, "its share was not burned by the refusal")
    }

    /// Share keys: IPv4 as written, IPv6 by /64 whatever the spelling,
    /// IPv4-mapped IPv6 as its IPv4, never a port.
    func testAddressShareKeys() {
        typealias Gate = HandshakeGate
        XCTAssertEqual(Gate.addressShareKey("10.0.0.5"), Array("10.0.0.5".utf8))
        XCTAssertEqual(Gate.addressShareKey("::ffff:10.0.0.5"),
                       Gate.addressShareKey("10.0.0.5"))
        XCTAssertEqual(Gate.addressShareKey("2001:db8:1:2:aaaa::1"),
                       Gate.addressShareKey("2001:0db8:0001:0002:bbbb:cccc:dddd:eeee"))
        XCTAssertEqual(Gate.addressShareKey("2001:db8:1:2::"),
                       Gate.addressShareKey("2001:db8:1:2:0:0:0:9"))
        XCTAssertNotEqual(Gate.addressShareKey("2001:db8:1:2::1"),
                          Gate.addressShareKey("2001:db8:1:3::1"))
        XCTAssertEqual(Gate.addressShareKey("fe80::1%en0"),
                       Gate.addressShareKey("fe80::2%en1"))
        XCTAssertNotEqual(Gate.addressShareKey("::1"),
                          Gate.addressShareKey("1::"))
        XCTAssertEqual(Gate.addressShareKey("1:::2"), Array("1:::2".utf8),
                       "not IPv6: keyed as written")
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
        var admits = 0, throttled = 0
        // One second of line-rate replays inside the cookie's lifetime.
        for index in 0..<1_000 {
            let decision = gate.admitMessage1(
                presentedCookie: cookie[...], clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
                message1: msg1[...], now: 2_000 + UInt64(index) * 1_000_000)
            if decision.admission == .admit { admits += 1 }
            if decision.admission == .drop(.throttled) { throttled += 1 }
        }
        XCTAssertEqual(admits, 1)
        XCTAssertEqual(throttled, 999)
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
        for index in 0..<20 {
            let msg1 = message1(UInt8(index))
            let cookie = try RetryCookie.mint(
                clientTuple: address(index), message1: msg1[...],
                now: 1_000, secret: Self.secret)
            let decision = gate.admitMessage1(
                presentedCookie: cookie[...], clientTuple: address(index), clientAddress: shareKey(address(index)),
                message1: msg1[...], now: 2_000)
            if decision.admission == .admit { admits += 1 }
        }
        XCTAssertEqual(admits, 5, "the burst, then the rate")

        let later = message1(0xEE)
        let cookie = try RetryCookie.mint(
            clientTuple: address(99), message1: later[...],
            now: 100_002_000, secret: Self.secret)
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: cookie[...], clientTuple: address(99), clientAddress: shareKey(address(99)),
            message1: later[...], now: 100_002_000
        ).admission, .admit, "100 ms refills one cookie admission")
    }

    /// One proven address minting fresh cookies (fresh ephemerals dodge
    /// the replay memory) spends only its own share: another client's
    /// cookie still admits in the same instant, and the holder's share
    /// refills at its own rate.
    func testOneProvenAddressCannotSpendEveryonesCookieAdmissions() throws {
        var gate = HandshakeGate(config: .init(
            cookieSecret: Self.secret,
            cookieEnterThreshold: 1, cookieExitThreshold: 0))
        let holder = address(1)
        var admits = 0
        for seed in 0..<200 {
            let msg1 = message1(UInt8(seed))
            let cookie = try RetryCookie.mint(
                clientTuple: holder, message1: msg1[...],
                now: 1_000, secret: Self.secret)
            if gate.admitMessage1(
                presentedCookie: cookie[...], clientTuple: holder, clientAddress: shareKey(holder),
                message1: msg1[...], now: 2_000
            ).admission == .admit { admits += 1 }
        }
        XCTAssertEqual(admits, 2, "one address's share of the cookie budget")

        let honest = address(2)
        let msg1 = message1(0xAB)
        let cookie = try RetryCookie.mint(
            clientTuple: honest, message1: msg1[...],
            now: 1_000, secret: Self.secret)
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: cookie[...], clientTuple: honest, clientAddress: shareKey(honest),
            message1: msg1[...], now: 2_000
        ).admission, .admit)

        let refilled = message1(0xCD)
        let fresh = try RetryCookie.mint(
            clientTuple: holder, message1: refilled[...],
            now: 500_002_000, secret: Self.secret)
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: fresh[...], clientTuple: holder, clientAddress: shareKey(holder),
            message1: refilled[...], now: 500_002_000
        ).admission, .admit, "500 ms refills one of the holder's admissions")
    }

    /// A spoofed msg1 flood above the bucket's rate (10/s) but below the
    /// dial's threshold (20 in a second) drains the bucket without ever
    /// engaging require-cookie mode. With a secret, an honest msg1 that
    /// meets the empty bucket is challenged instead of dropped, and its
    /// echoed cookie gets it in.
    func testFloodBelowTheDialStillLetsACookiedClientIn() throws {
        var gate = HandshakeGate(config: .init(cookieSecret: Self.secret))
        let floodInterval: UInt64 = 1_000_000_000 / 15
        var now: UInt64 = 0
        for index in 0..<45 {
            now = UInt64(index) * floodInterval
            _ = gate.admitMessage1(
                presentedCookie: nil, clientTuple: address(index), clientAddress: shareKey(address(index)),
                message1: message1(UInt8(index))[...], now: now)
        }
        XCTAssertFalse(gate.cookieMode, "15/s never engages the dial")

        let honest = address(500)
        let msg1 = message1(0x77)
        guard case .challenge(let cookie) = gate.admitMessage1(
            presentedCookie: nil, clientTuple: honest, clientAddress: shareKey(honest),
            message1: msg1[...], now: now
        ).admission else {
            return XCTFail("the drained bucket must challenge, not drop")
        }
        for index in 45..<48 {
            now = UInt64(index) * floodInterval
            _ = gate.admitMessage1(
                presentedCookie: nil, clientTuple: address(index), clientAddress: shareKey(address(index)),
                message1: message1(UInt8(index))[...], now: now)
        }
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: cookie[...], clientTuple: honest, clientAddress: shareKey(honest),
            message1: msg1[...], now: now
        ).admission, .admit)
    }

    /// An instant earlier than the window's arrivals ages nothing out: a
    /// clock step backwards cannot clear the dial.
    func testAnEarlierInstantDoesNotEmptyTheFloodWindow() {
        var gate = HandshakeGate(config: .init(
            cookieSecret: Self.secret,
            cookieEnterThreshold: 3, cookieExitThreshold: 1,
            floodWindowNS: 1_000))
        let msg1 = message1(1)
        for now: UInt64 in [5_000, 5_001, 5_002, 4_000] {
            _ = gate.admitMessage1(
                presentedCookie: nil, clientTuple: Self.tuple,
                clientAddress: shareKey(Self.tuple),
                message1: msg1[...], now: now)
        }
        XCTAssertTrue(gate.cookieMode)
    }

    /// No secret = the pure token-bucket posture: the bucket admits the
    /// burst and throttles the rest; require-cookie never engages.
    func testDisabledWithoutSecretIsThePureTokenBucket() {
        var gate = HandshakeGate(config: .init(ratePerSecond: 10, burst: 10))
        var admits = 0, drops = 0
        for i in 0..<200 {
            let decision = gate.admitMessage1(
                presentedCookie: nil, clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
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
                presentedCookie: nil, clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
                message1: Self.msg1[...], now: UInt64(i) * 1_000_000
            )
            XCTAssertFalse(gate.cookieMode)
            XCTAssertNil(decision.cookieModeChangedTo)
        }
        // The fifth crosses the enter threshold → engaged.
        let engaged = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
            message1: Self.msg1[...], now: 4_000_000
        )
        XCTAssertTrue(gate.cookieMode, "5 arrivals in 1 s engages the dial")
        XCTAssertEqual(engaged.cookieModeChangedTo, true)

        let held = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
            message1: Self.msg1[...], now: 5_000_000
        )
        XCTAssertTrue(gate.cookieMode)
        XCTAssertNil(held.cookieModeChangedTo,
                     "remaining in the same posture emits no second edge")

        // Let the window drain: an arrival 2 s later sees only itself
        // in the window (1 ≤ exit threshold 2) → cleared.
        let cleared = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
            message1: Self.msg1[...], now: 2_000_000_000
        )
        XCTAssertFalse(gate.cookieMode, "the window drained — pressure gone")
        XCTAssertEqual(cleared.cookieModeChangedTo, false)
        // And with the dial cleared, that lone un-cookied msg1 falls to
        // the token bucket (admitted, not challenged).
        XCTAssertEqual(cleared.admission, .admit)
        let stayedClear = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
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
            presentedCookie: nil, clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
            message1: Self.msg1[...], now: 10_000
        )
        XCTAssertEqual(decision.cookieModeChangedTo, true)
        guard case .challenge(let cookie) = decision.admission else {
            return XCTFail("a flooded un-cookied msg1 must be challenged")
        }
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
            presentedCookie: nil, clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
            message1: Self.msg1[...], now: 1_000
        ).admission else { return XCTFail("expected a challenge") }

        // The echoed cookie admits.
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: cookie[...], clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
            message1: Self.msg1[...], now: 2_000
        ).admission, .admit)

        // A tampered cookie drops.
        var forged = cookie
        forged[forged.count - 1] ^= 0xFF
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: forged[...], clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
            message1: Self.msg1[...], now: 3_000
        ).admission, .drop(.cookieInvalid))

        // The right cookie for the WRONG msg1 drops (the binding holds).
        let otherMsg1 = [UInt8](repeating: 0x11, count: 96)
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: cookie[...], clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
            message1: otherMsg1[...], now: 4_000
        ).admission, .drop(.cookieInvalid))

        // The right cookie from the WRONG address drops.
        XCTAssertEqual(gate.admitMessage1(
            presentedCookie: cookie[...],
            clientTuple: Array("10.0.0.99:5000".utf8), clientAddress: shareKey(Array("10.0.0.99:5000".utf8)),
            message1: Self.msg1[...], now: 5_000
        ).admission, .drop(.cookieInvalid))
    }

    func testPresentedCookieBranchesCarryTheSameExactModeEdge() throws {
        var gate = HandshakeGate(config: .init(
            cookieSecret: Self.secret,
            cookieEnterThreshold: 2, cookieExitThreshold: 1,
            floodWindowNS: 1_000_000_000
        ))
        let first = gate.admitMessage1(
            presentedCookie: nil, clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
            message1: Self.msg1[...], now: 0
        )
        XCTAssertNil(first.cookieModeChangedTo)

        let forged = [UInt8](repeating: 0xEE, count: RetryCookie.byteCount)
        let entered = gate.admitMessage1(
            presentedCookie: forged[...], clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
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
            presentedCookie: cookie[...], clientTuple: Self.tuple, clientAddress: shareKey(Self.tuple),
            message1: Self.msg1[...], now: later
        )
        XCTAssertEqual(cleared.admission, .admit)
        XCTAssertEqual(cleared.cookieModeChangedTo, false)
    }
}
