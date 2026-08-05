@testable import lyte_host
import LyteWire
import XCTest

final class PreSessionShutdownTests: XCTestCase {
    func testAwaitClientObservesStopBeforeHandshake() throws {
        let wire = try SessionWire(
            listenPort: 0,
            peer: nil,
            rateBitsPerSecond: 1_000_000)
        defer {
            wire.shutdown(reason: .shuttingDown, lingerSeconds: 0)
        }
        let hostStatic = try NoiseKeyPair(
            privateKey: [UInt8](repeating: 0x31, count: 32))
        var polls = 0
        let started = ContinuousClock.now

        let outcome = try wire.awaitClient(
            hostStatic: hostStatic,
            timeoutSeconds: 10,
            stopRequested: {
                polls += 1
                return polls == 2
            })

        XCTAssertEqual(outcome, .terminationRequested)
        XCTAssertEqual(polls, 2)
        XCTAssertLessThan(
            started.duration(to: .now),
            .milliseconds(100))
    }
}
