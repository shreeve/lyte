import XCTest
@testable import HostCore

final class SocketLaneTests: XCTestCase {
    func testLatencyClassesNeverShareTheVideoSocketLane() {
        XCTAssertEqual(SocketLane.forClass(.control), .latency)
        XCTAssertEqual(SocketLane.forClass(.audio), .latency)
        for priorityClass in PacerClass.allCases
        where priorityClass > .audio {
            XCTAssertEqual(SocketLane.forClass(priorityClass), .video)
        }
    }
}
