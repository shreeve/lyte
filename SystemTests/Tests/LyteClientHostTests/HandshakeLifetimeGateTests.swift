import XCTest
import HostWire
import LyteClientSession

// The host discards an unconfirmed answer after a fixed span, and once
// discarded it ignores the answered message 1 for the rest of its run. A
// client still retrying past that span can then never connect, so every
// client retry schedule must end inside it with room for a round trip.

final class HandshakeLifetimeGateTests: XCTestCase {
    func testEveryClientRetryScheduleEndsBeforeTheHostDiscardsItsAnswer() {
        let marginNS: UInt64 = 1_000_000_000
        let schedules: [(String, ClientHandshakeInitiator.Retry)] = [
            ("firstDial", .firstDial),
            ("redial", .redial),
            ("default", ClientHandshakeInitiator.Retry()),
        ]
        for (name, retry) in schedules {
            let spanNS = UInt64(retry.attempts) * retry.intervalMicroseconds * 1_000
            XCTAssertLessThanOrEqual(
                spanNS + marginNS, Session.unconfirmedAnswerLifetimeNS,
                "\(name): \(retry.attempts) × \(retry.intervalMicroseconds) µs "
                    + "outlasts the host's unconfirmed-answer lifetime")
        }
    }
}
