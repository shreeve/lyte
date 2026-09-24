import HostSession
@testable import lyte_host
import LyteWire
import XCTest

/// The command line's postures that decide what a remote peer meets.
final class HostOptionsTests: XCTestCase {
    /// A plain service run arms the retry-cookie dial, so a spoofed
    /// message-1 flood engages cookies instead of starving every honest
    /// dial from the one token bucket.
    func testEveryRunArmsTheRetryCookieDial() throws {
        let opts = try Options.parse(["lyte-host", "--wire-listen", "41999"])
        var rng = SystemRandomNumberGenerator()
        let config = opts.handshakeGateConfig(using: &rng)
        XCTAssertEqual(config.cookieSecret?.count, RetryCookie.secretByteCount)
        XCTAssertEqual(config.cookieEnterThreshold, 20)
        XCTAssertEqual(config.cookieExitThreshold, 5)

        var gate = HandshakeGate(config: config)
        let tuple = [UInt8](repeating: 7, count: 6)
        var challenged = false
        for i in 0..<100 where !challenged {
            let message1 = [UInt8](repeating: UInt8(i), count: 96)
            if case .challenge = gate.admitMessage1(
                presentedCookie: nil, clientTuple: tuple,
                message1: message1[...],
                now: UInt64(i) * 1_000_000).admission {
                challenged = true
            }
        }
        XCTAssertTrue(challenged, "a flood meets the cookie challenge")
    }

    func testTheCookieThresholdsMustLeaveHysteresis() {
        XCTAssertThrowsError(try Options.parse([
            "lyte-host", "--cookie-enter", "10", "--cookie-exit", "10",
        ]))
        XCTAssertNoThrow(try Options.parse([
            "lyte-host", "--cookie-enter", "10", "--cookie-exit", "9",
        ]))
    }
}
