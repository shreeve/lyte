import HostWire
import XCTest

final class SenderWaitTests: XCTestCase {
    func testTheSenderSleepsUntilTheNextTimer() {
        XCTAssertEqual(SenderWait.timeoutNS(
            nowNS: 1_000, nextWakeNS: 1_750_000, noBufferBackoff: false),
            1_749_000)
    }

    func testADueTimerMeansNoWait() {
        XCTAssertEqual(SenderWait.timeoutNS(
            nowNS: 5_000, nextWakeNS: 4_000, noBufferBackoff: false), 0)
        XCTAssertEqual(SenderWait.timeoutNS(
            nowNS: 5_000, nextWakeNS: 5_000, noBufferBackoff: false), 0)
    }

    func testNoTimerAndFarTimersAreBoundedByTheBackstop() {
        XCTAssertEqual(SenderWait.timeoutNS(
            nowNS: 0, nextWakeNS: nil, noBufferBackoff: false),
            SenderWait.maxWaitNS)
        XCTAssertEqual(SenderWait.timeoutNS(
            nowNS: 0, nextWakeNS: 5_000_000_000, noBufferBackoff: false),
            SenderWait.maxWaitNS)
    }

    func testENOBUFSRetriesAfterTheBackoff() {
        XCTAssertEqual(SenderWait.timeoutNS(
            nowNS: 0, nextWakeNS: 50_000_000, noBufferBackoff: true),
            SenderWait.noBufferBackoffNS)
    }
}
