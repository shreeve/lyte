import XCTest
import HostCore
import LyteCore

// The wire-marking policy, pinned as data. The protected CS6 lane
// carries control, audio and the videoTail repair class (a NACK repair
// is deadline traffic: on video's own DSCP, a bottleneck squeezing video
// starves exactly the datagrams sent to heal the damage). Fresh video
// and ratchet refinement stay on CS5; telemetry stays unmarked. The map
// is what SessionWire and lyte-pace-check both apply — one policy.
final class WireTosTests: XCTestCase {

    func testMarkingPolicyPinned() {
        // The protected lane (CS6 / DSCP 48).
        XCTAssertEqual(WireTos.byte(for: .control), WireTos.protected)
        XCTAssertEqual(WireTos.byte(for: .audio), WireTos.protected)
        XCTAssertEqual(WireTos.byte(for: .videoTail), WireTos.protected,
                       "repairs ride the protected lane")
        // The video lane (CS5 / DSCP 40).
        XCTAssertEqual(WireTos.byte(for: .freshVideo), WireTos.video)
        XCTAssertEqual(WireTos.byte(for: .refinement), WireTos.video)
        // Telemetry is deliberately unmarked.
        XCTAssertEqual(WireTos.byte(for: .telemetry), WireTos.unmarked)
        XCTAssertEqual(WireTos.byte(for: .bulk), WireTos.bulk)
    }

    func testEveryClassHasAMarking() {
        // Exhaustiveness by construction: a new PacerClass without a
        // ruling here should be a conscious decision, not an accident.
        for pacerClass in PacerClass.allCases {
            _ = WireTos.byte(for: pacerClass)
        }
    }
}
