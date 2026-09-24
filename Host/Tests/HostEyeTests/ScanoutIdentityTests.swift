#if os(Linux)

import Foundation
import Glibc
@testable import HostEye
import XCTest

/// What names a scanned-out buffer, and when a dark primary plane is
/// looked for elsewhere.
final class ScanoutIdentityTests: XCTestCase {
    /// Two fds on one buffer are one identity; another buffer is another,
    /// whatever framebuffer id carries it.
    func testTheBufferIdentityFollowsTheBufferNotTheFd() throws {
        let one = try temporaryFile()
        let other = try temporaryFile()
        let again = dup(one)
        defer { close(one); close(other); close(again) }

        func ticket(_ fd: Int32) -> ScanoutTicket {
            ScanoutTicket(width: 1, height: 1, fourcc: 0, modifier: 0,
                          planes: [(fd, 0, 4)])
        }
        XCTAssertNotNil(ticket(one).bufferIdentity)
        XCTAssertEqual(ticket(one).bufferIdentity, ticket(again).bufferIdentity)
        XCTAssertNotEqual(ticket(one).bufferIdentity, ticket(other).bufferIdentity)
        XCTAssertNil(ScanoutTicket(
            width: 1, height: 1, fourcc: 0, modifier: 0, planes: []
        ).bufferIdentity)
    }

    func testADarkPlaneIsLookedForOncePerIntervalUntilItScansOutAgain() {
        let interval = PlaneRecheckClock.intervalNS
        var clock = PlaneRecheckClock()
        XCTAssertFalse(clock.unavailable(now: 0), "DPMS-off gets its grace")
        XCTAssertFalse(clock.unavailable(now: interval - 1))
        XCTAssertTrue(clock.unavailable(now: interval))
        XCTAssertFalse(clock.unavailable(now: interval + 1))
        XCTAssertTrue(clock.unavailable(now: 2 * interval + 5))

        clock.available()
        XCTAssertFalse(clock.unavailable(now: 3 * interval),
            "a plane that scanned out again starts a fresh grace")
        XCTAssertTrue(clock.unavailable(now: 4 * interval))
    }

    private func temporaryFile() throws -> Int32 {
        let path = NSTemporaryDirectory() + "lyte-scanout-\(UUID().uuidString)"
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        unlink(path)
        return fd
    }
}

#endif
