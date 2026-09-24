@testable import lyte_host
import XCTest

/// A clipboard transfer is abandoned for making no progress, not for
/// taking long: a 30 MiB image through a 64 KiB pipe takes seconds.
final class TransferStallTests: XCTestCase {
    func testASlowTransferThatKeepsMovingNeverStalls() {
        var stall = TransferStall(at: 100)
        for second in 1...20 {
            let now = 100 + Double(second)
            XCTAssertFalse(stall.stalled(at: now), "at \(second) s")
            stall.progressed(at: now)
        }
    }

    func testATransferWithNoProgressPastTheTimeoutStalls() {
        var stall = TransferStall(at: 0)
        stall.progressed(at: 10)
        XCTAssertFalse(stall.stalled(at: 10 + TransferStall.timeoutSeconds))
        XCTAssertTrue(stall.stalled(at: 10.1 + TransferStall.timeoutSeconds))
    }
}
