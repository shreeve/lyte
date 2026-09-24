import HostSession
import LyteWire
import XCTest

final class HandshakeGateTests: XCTestCase {
    private static let secret = [UInt8](repeating: 0x5A, count: 32)
    private static let tuple = Array("10.0.0.23:61000".utf8)

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
}
