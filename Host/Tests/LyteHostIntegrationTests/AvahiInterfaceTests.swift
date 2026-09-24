@testable import lyte_host
import XCTest

/// A record pinned to a named interface follows the interface, not the
/// index it had at startup: a re-plugged USB NIC keeps its name and gets
/// a new index.
final class AvahiInterfaceTests: XCTestCase {
    func testANamedInterfaceResolvesAtEveryAsk() {
        XCTAssertEqual(AvahiAdvertiser.interfaceIndex(named: ""), -1,
            "no name advertises on every interface")
        XCTAssertEqual(
            AvahiAdvertiser.interfaceIndex(named: "enx0") { _ in 7 }, 7)
        XCTAssertNil(
            AvahiAdvertiser.interfaceIndex(named: "enx0") { _ in 0 })
        XCTAssertNotNil(AvahiAdvertiser.interfaceIndex(named: "lo"))
    }

    func testARecordIsFiledAgainWhenItsInterfaceChanges() {
        XCTAssertNil(AvahiAdvertiser.refileReason(
            interfaceName: "enx0", filed: 7, current: 7))
        XCTAssertNotNil(AvahiAdvertiser.refileReason(
            interfaceName: "enx0", filed: 7, current: 9),
            "re-plugged under a new index")
        XCTAssertNotNil(AvahiAdvertiser.refileReason(
            interfaceName: "enx0", filed: 7, current: nil),
            "unplugged")
        XCTAssertNil(AvahiAdvertiser.refileReason(
            interfaceName: "", filed: -1, current: -1))
    }
}
