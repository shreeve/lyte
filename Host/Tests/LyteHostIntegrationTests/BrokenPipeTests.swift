import Glibc
@testable import lyte_host
import XCTest

/// A host whose stdout reader went away keeps running: the write fails
/// with EPIPE instead of SIGPIPE killing the process.
final class BrokenPipeTests: XCTestCase {
    func testAWriteToAClosedPipeFailsInsteadOfKilling() {
        signal(SIGPIPE, SIG_DFL)
        lyteIgnoreBrokenPipes()

        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        close(ends[0])
        defer { close(ends[1]) }
        let byte: [UInt8] = [0x0A]
        XCTAssertEqual(write(ends[1], byte, 1), -1)
        XCTAssertEqual(errno, EPIPE)
    }
}
