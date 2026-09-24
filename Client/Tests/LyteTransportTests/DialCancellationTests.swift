import Foundation
import LyteClientTestKit
import LyteTransport
import LyteWire
import XCTest

/// A dial in flight belongs to its owner: stopping the endpoint or the
/// session ends the blocking handshake within one poll slice instead of
/// after every message-1 attempt has timed out.
final class DialCancellationTests: XCTestCase {
    /// Five one-second attempts at a port nobody answers: 5 s if the
    /// handshake runs to exhaustion.
    private func silentHostCrypto() throws -> NoiseTransportCrypto {
        try NoiseTransportCrypto(
            hostAddress: "127.0.0.1", hostPort: 9,
            hostStaticPublicKey: NoiseKeyPair.generate().publicKey,
            attempts: 5, attemptTimeoutMilliseconds: 1_000)
    }

    private final class Outcome: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var error: (any Error)?
    }

    private func assertCancelledPromptly(
        start: @escaping @Sendable () throws -> Void,
        stop: () -> Void
    ) {
        let outcome = Outcome()
        DispatchQueue.global().async {
            do { try start() } catch { outcome.error = error }
            outcome.done.signal()
        }
        usleep(100_000)
        let stopped = DispatchTime.now()
        stop()
        XCTAssertEqual(outcome.done.wait(timeout: stopped + .seconds(1)),
                       .success, "the dial outlived its stop by a second")
        guard case TransportEndpointError.cancelled? =
            outcome.error as? TransportEndpointError
        else {
            return XCTFail("expected cancelled, got \(String(describing: outcome.error))")
        }
    }

    func testEndpointStopEndsAnInFlightHandshake() throws {
        let endpoint = UdpReceiveEndpoint(
            port: 0, bindAddress: "127.0.0.1", crypto: try silentHostCrypto())
        assertCancelledPromptly(
            start: { try endpoint.bindAndHandshake() },
            stop: { endpoint.stop() })
    }

    func testSessionStopEndsAnInFlightDial() throws {
        var config = LyteUdpSession.Config()
        config.bindAddress = "127.0.0.1"
        config.audioPlayback = false
        let session = LyteUdpSession(
            crypto: try silentHostCrypto(), config: config,
            videoSink: HeadlessVideoSink(), onEvent: { _ in })
        assertCancelledPromptly(
            start: { try session.start() },
            stop: { session.stop() })
        XCTAssertNil(session.core, "a cancelled dial publishes no core")
        XCTAssertThrowsError(try session.start(),
                             "a stopped session never dials again")
    }
}
