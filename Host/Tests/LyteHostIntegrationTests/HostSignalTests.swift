import Glibc
@testable import lyte_host
import XCTest

/// The host's signal dispositions, each in a forked child.
final class HostSignalTests: XCTestCase {
    /// The first SIGINT or SIGTERM asks for the graceful exit; a second
    /// one exits at once with the shell's 128 + signal status, so a
    /// supervisor sees which signal ended the process.
    func testASecondSignalExitsWithItsOwnStatus() {
        for sig in [SIGTERM, SIGINT] {
            let child = fork()
            if child == 0 {
                // Only async-signal-safe work in the forked child.
                lyteTerminationRequested = 0
                lyteInstallTerminationHandlers()
                raise(sig)
                raise(sig)
                _exit(0)
            }
            XCTAssertGreaterThan(child, 0)
            var status: Int32 = 0
            XCTAssertEqual(waitpid(child, &status, 0), child)
            XCTAssertEqual(status & 0x7F, 0, "exited, not killed")
            XCTAssertEqual((status >> 8) & 0xFF, 128 + sig, "signal \(sig)")
        }
    }

    /// A host whose stdout reader went away keeps running: the write
    /// fails with EPIPE instead of SIGPIPE killing the process.
    func testAWriteToAClosedPipeFailsInsteadOfKilling() {
        let child = fork()
        if child == 0 {
            signal(SIGPIPE, SIG_DFL)
            lyteIgnoreBrokenPipes()
            var ends: [Int32] = [0, 0]
            guard pipe(&ends) == 0 else { _exit(2) }
            close(ends[0])
            var byte: UInt8 = 0x0A
            _exit(write(ends[1], &byte, 1) == -1 && errno == EPIPE ? 0 : 1)
        }
        XCTAssertGreaterThan(child, 0)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(child, &status, 0), child)
        XCTAssertEqual(status & 0x7F, 0, "exited, not killed by SIGPIPE")
        XCTAssertEqual((status >> 8) & 0xFF, 0, "the write failed with EPIPE")
    }
}
