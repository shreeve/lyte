import HostCore
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
                clientAddress: tuple,
                message1: message1[...],
                now: UInt64(i) * 1_000_000).admission {
                challenged = true
            }
        }
        XCTAssertTrue(challenged, "a flood meets the cookie challenge")
    }

    /// The standing service's own line, as the unit word-splits it.
    func testTheStandingServiceLineParsesAsTheService() throws {
        let opts = try Options.parse(["lyte-host"]
            + "--wire-listen 41151 --clipboard=images --advertise-interface wlp0s20f3"
                .split(separator: " ").map(String.init))
        XCTAssertEqual(opts.wireListen, 41151)
        XCTAssertTrue(opts.clipboard)
        XCTAssertTrue(opts.clipboardImages)
        XCTAssertEqual(opts.advertiseInterface, "wlp0s20f3")
        XCTAssertTrue(opts.advertise)
        XCTAssertFalse(opts.acceptFiles)
        XCTAssertFalse(opts.pair)
        XCTAssertFalse(opts.requirePaired)
        XCTAssertNil(opts.drmDevice)
        XCTAssertEqual(HostServiceLoop.posture(
            secondsGiven: opts.secondsGiven, pairing: opts.pair,
            seconds: opts.seconds), .service)
    }

    func testTheCapturedCardCanBeNamed() throws {
        XCTAssertNil(try Options.parse(["lyte-host"]).drmDevice)
        XCTAssertEqual(
            try Options.parse(["lyte-host", "--drm-device", "/dev/dri/card0"])
                .drmDevice,
            "/dev/dri/card0")
        XCTAssertThrowsError(
            try Options.parse(["lyte-host", "--drm-device", "card0"]))
    }

    /// "inf" and "nan" parse as Doubles; either would trap where the
    /// clock and the rate become integers.
    func testNonFiniteDurationsAndRatesAreRefused() {
        for value in ["inf", "-inf", "nan", "infinity"] {
            XCTAssertThrowsError(
                try Options.parse(["lyte-host", "--seconds", value]), value)
            XCTAssertThrowsError(
                try Options.parse(["lyte-host", "--wire-rate-mbps", value]),
                value)
        }
        XCTAssertEqual(
            try Options.parse(["lyte-host", "--seconds", "2.5"]).seconds, 2.5)
    }

    func testTheCookieThresholdsMustLeaveHysteresis() {
        XCTAssertThrowsError(try Options.parse([
            "lyte-host", "--wire-listen", "41999",
            "--cookie-enter", "10", "--cookie-exit", "10",
        ]))
        XCTAssertNoThrow(try Options.parse([
            "lyte-host", "--wire-listen", "41999",
            "--cookie-enter", "10", "--cookie-exit", "9",
        ]))
    }

    /// Without a listener there is no session: a session flag there would
    /// be silently ignored while the run captures to a file.
    func testSessionFlagsNeedAListener() {
        for flags in [
            ["--pair"], ["--require-paired"], ["--clipboard"],
            ["--clipboard=images"], ["--accept-files"],
            ["--accept-files=/srv/drop"], ["--host-audio", "muted"],
            ["--cookie-enter", "30"], ["--no-audio"], ["--input", "off"],
        ] {
            XCTAssertThrowsError(
                try Options.parse(["lyte-host"] + flags), "\(flags)")
            XCTAssertNoThrow(try Options.parse(
                ["lyte-host", "--wire-listen", "41999"] + flags), "\(flags)")
        }
    }

    /// A kbps value whose bps overflows Int32 used to trap the host.
    func testTheAudioBitrateIsBoundedBeforeItScales() throws {
        for value in ["0", "513", "3000000"] {
            XCTAssertThrowsError(try Options.parse([
                "lyte-host", "--wire-listen", "41999",
                "--audio-bitrate-kbps", value,
            ]), value)
        }
        XCTAssertEqual(try Options.parse([
            "lyte-host", "--wire-listen", "41999",
            "--audio-bitrate-kbps", "96",
        ]).audioBitrate, 96_000)
    }
}
