import XCTest
import HostCore

// THE GATE (HS-20, D-2): the wire-marking policy, pinned as data. The
// protected CS6 lane carries control, audio, and — since HS-20 — the
// videoTail repair class (a NACK repair is deadline traffic; riding
// video's own DSCP meant a bottleneck squeezing video starved exactly
// the datagrams sent to heal the squeeze's damage). Fresh video and
// ratchet refinement stay on CS5; telemetry stays unmarked. The map is
// what SessionWire and lyte-pace-check both apply — one policy, pinned
// once.
final class WireTosTests: XCTestCase {

    func testMarkingPolicyPinned() {
        // The protected lane (CS6 / DSCP 48).
        XCTAssertEqual(WireTos.byte(for: .control), 0xC0)
        XCTAssertEqual(WireTos.byte(for: .audio), 0xC0)
        XCTAssertEqual(WireTos.byte(for: .videoTail), 0xC0,
                       "repairs ride the protected lane (HS-20)")
        // The video lane (CS5 / DSCP 40).
        XCTAssertEqual(WireTos.byte(for: .freshVideo), 0xA0)
        XCTAssertEqual(WireTos.byte(for: .refinement), 0xA0)
        // Telemetry is deliberately unmarked.
        XCTAssertEqual(WireTos.byte(for: .telemetry), 0x00)
    }

    func testEveryClassHasAMarking() {
        // Exhaustiveness by construction: a new PacerClass without a
        // ruling here should be a conscious decision, not an accident.
        for pacerClass in PacerClass.allCases {
            _ = WireTos.byte(for: pacerClass)
        }
    }
}
