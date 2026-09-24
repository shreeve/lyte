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

    /// A named interface missing at startup (a USB NIC plugged in later)
    /// is waited for: the advertiser comes up unfiled, without touching
    /// the bus, and keeps retrying instead of disabling discovery.
    func testAnInterfaceMissingAtStartupLeavesTheAdvertiserWaiting() {
        let advertiser = AvahiAdvertiser(
            port: 41_997, staticPublicKey: [UInt8](repeating: 7, count: 32),
            name: "lyte-test-missing-interface",
            interfaceName: "lytenone\(getpid() % 1_000)")
        XCTAssertFalse(advertiser.isFiled)
        advertiser.service()
        XCTAssertFalse(advertiser.isFiled)
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
