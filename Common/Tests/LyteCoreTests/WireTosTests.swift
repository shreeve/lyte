import XCTest
@testable import LyteCore

final class WireTosTests: XCTestCase {
    func testProductLanesPinCompleteTosBytesAndDscpCodepoints() {
        XCTAssertEqual(WireTos.unmarked, 0x00)
        XCTAssertEqual(WireTos.bulk, 0x20)
        XCTAssertEqual(WireTos.video, 0xA0)
        XCTAssertEqual(WireTos.protected, 0xC0)

        XCTAssertEqual(WireTos.dscp(WireTos.unmarked), 0)
        XCTAssertEqual(WireTos.dscp(WireTos.bulk), 8)
        XCTAssertEqual(WireTos.dscp(WireTos.video), 40)
        XCTAssertEqual(WireTos.dscp(WireTos.protected), 48)
    }

    func testEveryProductLaneLeavesEcnBitsClear() {
        for byte in [
            WireTos.unmarked, WireTos.bulk, WireTos.video, WireTos.protected,
        ] {
            XCTAssertEqual(byte & 0x03, 0)
        }
    }
}
