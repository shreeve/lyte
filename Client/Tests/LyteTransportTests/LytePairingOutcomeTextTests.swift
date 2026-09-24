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

    /// A PIN that is not six ASCII digits is refused before the socket
    /// opens, so it never spends one of the host's guesses.
    func testNonAsciiPinIsRefusedBeforeDialing() {
        let progress = LockedLines()
        let outcome = LytePairing.run(LytePairing.Config(
            hostAddress: "127.0.0.1", hostPort: 9,
            hostStaticPublicKey: [UInt8](repeating: 7, count: 32),
            pin: "\u{FF12}\u{FF14}\u{FF16}\u{FF18}\u{FF11}\u{FF10}",
            clientStaticKeys: NoiseKeyPair.generate(),
            timeoutSeconds: 1,
            onProgress: { progress.append($0) }))
        guard case .failed(let message) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertTrue(message.contains("6 digits"), message)
        XCTAssertTrue(progress.lines.isEmpty, "\(progress.lines)")
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
