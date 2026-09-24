import HostWire
import XCTest

final class VideoAdmissionGateTests: XCTestCase {
    func testAQueueBelowItsBudgetAdmitsEveryFrame() {
        var gate = VideoAdmissionGate()
        XCTAssertTrue(gate.admit(backlogWireTimeNS: 0, budgetNS: 50_000_000))
        XCTAssertTrue(gate.admit(
            backlogWireTimeNS: 49_999_999, budgetNS: 50_000_000))
        XCTAssertEqual(gate.admitted, 2)
        XCTAssertEqual(gate.skipped, 0)
    }

    /// B5: the direct leg encoded and queued every changed frame even when
    /// the queue already held a full budget of wire time.
    func testAQueueAtItsBudgetSkipsTheFrameBeforeEncode() {
        var gate = VideoAdmissionGate()
        XCTAssertFalse(gate.admit(
            backlogWireTimeNS: 50_000_000, budgetNS: 50_000_000))
        XCTAssertFalse(gate.admit(
            backlogWireTimeNS: 400_000_000, budgetNS: 50_000_000))
        XCTAssertTrue(gate.admit(
            backlogWireTimeNS: 10_000_000, budgetNS: 50_000_000))
        XCTAssertEqual(gate.skipped, 2)
        XCTAssertEqual(gate.admitted, 1)
    }
}
