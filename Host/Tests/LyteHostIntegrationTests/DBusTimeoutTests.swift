import CDBus
import Foundation
import Glibc
@testable import lyte_host
import XCTest

/// A D-Bus peer that never answers costs a leaf call about a second, not
/// the listener's whole handshake wait. The peer is a name held on a
/// private bus daemon, so no desktop service is touched.
final class DBusTimeoutTests: XCTestCase {
    private var daemon: Process?
    private var savedAddress: String?

    override func setUpWithError() throws {
        let path = "/usr/bin/dbus-daemon"
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: path),
            "no dbus-daemon")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--session", "--nofork", "--print-address=1"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        daemon = process
        var address = ""
        let handle = output.fileHandleForReading
        while !address.hasSuffix("\n") {
            let byte = handle.readData(ofLength: 1)
            guard !byte.isEmpty else { break }
            address += String(decoding: byte, as: UTF8.self)
        }
        address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(address.isEmpty, "the private bus printed its address")
        savedAddress = ProcessInfo.processInfo
            .environment["DBUS_SESSION_BUS_ADDRESS"]
        setenv("DBUS_SESSION_BUS_ADDRESS", address, 1)
    }

    override func tearDown() {
        if let savedAddress {
            setenv("DBUS_SESSION_BUS_ADDRESS", savedAddress, 1)
        } else {
            unsetenv("DBUS_SESSION_BUS_ADDRESS")
        }
        daemon?.terminate()
        daemon?.waitUntilExit()
    }

    func testACallToAPeerThatNeverAnswersFailsWithinTheCallTimeout() throws {
        let silent = try SessionBus()
        var err = DBusError()
        dbus_error_init(&err)
        XCTAssertEqual(
            dbus_bus_request_name(silent.conn, "dev.lyte.Silent", 0, &err),
            Int32(DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER))
        dbus_error_free(&err)

        let caller = try SessionBus()
        let start = Date()
        XCTAssertThrowsError(try caller.call(
            dest: "dev.lyte.Silent", path: "/dev/lyte/Silent",
            interface: "dev.lyte.Silent", method: "Hang"))
        let waited = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(waited, 0.5)
        XCTAssertLessThan(waited, 5, "a stalled peer costs about a second")
        withExtendedLifetime(silent) {}
    }
}
