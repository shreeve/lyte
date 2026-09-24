import Foundation
import LyteWire
import XCTest
@testable import LyteTransport

/// The app's pairing sheet and `wire-pair` speak one wording and pin
/// through one path.
final class LytePairingOutcomeTextTests: XCTestCase {
    func testEveryFailureHasAMessageAndSuccessHasNone() {
        XCTAssertNil(LytePairing.Outcome.paired(hostStaticPublicKey: [1]).failureMessage)
        let failures: [LytePairing.Outcome] = [
            .pinMismatch, .hostRejected(.confirmationFailed), .invalidShare, .timedOut,
            .failed("bind: address in use"),
        ]
        for outcome in failures {
            XCTAssertFalse(outcome.failureMessage?.isEmpty ?? true, "\(outcome)")
        }
        XCTAssertEqual(LytePairing.Outcome.failed("bind: x").failureMessage, "bind: x")
    }

    func testPinPairedStampsAndReportsFreshness() throws {
        var store = PinnedHostStore()
        let key = (0..<32).map { UInt8($0) }
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(store.pinPaired(
            staticPublicKey: key, name: "pup", address: "10.0.0.9", port: 41_151, at: at))
        XCTAssertFalse(store.pinPaired(
            staticPublicKey: key, name: "pup", address: "10.0.0.10", port: 41_151, at: at))
        let pinned = try XCTUnwrap(store.hosts.values.first)
        XCTAssertEqual(pinned.address, "10.0.0.10")
        XCTAssertEqual(pinned.pairedAt, ISO8601DateFormatter().string(from: at))
    }
}
