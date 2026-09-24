import Glibc
@testable import lyte_host
import XCTest

/// The first SIGINT or SIGTERM asks for the graceful exit; a second one
/// exits at once with the shell's 128 + signal status, so a supervisor
/// sees which signal ended the process.
final class TerminationSignalTests: XCTestCase {
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
}
