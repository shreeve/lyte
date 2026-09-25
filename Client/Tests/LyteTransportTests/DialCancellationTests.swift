import Foundation
import LyteClientTestKit
import LyteTransport
import LyteWire
import XCTest

/// A dial in flight belongs to its owner: stopping the endpoint or the
/// session ends the blocking handshake within one poll slice instead of
/// after every message-1 attempt has timed out.
final class DialCancellationTests: XCTestCase {
    /// Five one-second attempts at a port nobody answers (5 s if the
    /// handshake runs to exhaustion), signalling once the dial is under way.
    private final class SilentHostCrypto: HandshakingTransportCrypto,
        @unchecked Sendable
    {
        let inner: NoiseTransportCrypto
        let dialing = DispatchSemaphore(value: 0)

        init() throws {
            inner = try NoiseTransportCrypto(
                hostAddress: "127.0.0.1", hostPort: 9,
                hostStaticPublicKey: NoiseKeyPair.generate().publicKey,
                retry: .init(attempts: 5, intervalMicroseconds: 1_000_000))
        }

        var hostAddress: String { inner.hostAddress }
        var hostPort: UInt16 { inner.hostPort }
        var modeDescription: String { inner.modeDescription }
        func open() throws { try inner.open() }

        func performHandshake(io: any NoiseHandshakeIO) throws {
            dialing.signal()
            try inner.performHandshake(io: io)
        }

        func unseal(
            wirePayload: ArraySlice<UInt8>, aad: ArraySlice<UInt8>,
            envelope: Envelope
        ) throws -> [UInt8] {
            try inner.unseal(wirePayload: wirePayload, aad: aad, envelope: envelope)
        }

        func seal(
            plaintext: ArraySlice<UInt8>, aad: ArraySlice<UInt8>,
            envelope: Envelope
        ) throws -> [UInt8] {
            try inner.seal(plaintext: plaintext, aad: aad, envelope: envelope)
        }
    }

    private final class Outcome: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var error: (any Error)?
    }

    private func assertCancelledPromptly(
        dialing: DispatchSemaphore,
        start: @escaping @Sendable () throws -> Void,
        stop: () -> Void
    ) {
        let outcome = Outcome()
        DispatchQueue.global().async {
            do { try start() } catch { outcome.error = error }
            outcome.done.signal()
        }
        XCTAssertEqual(dialing.wait(timeout: .now() + 5), .success,
                       "the dial never started")
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
        let crypto = try SilentHostCrypto()
        let endpoint = UdpReceiveEndpoint(
            port: 0, bindAddress: "127.0.0.1", crypto: crypto)
        assertCancelledPromptly(
            dialing: crypto.dialing,
            start: { try endpoint.bindAndHandshake() },
            stop: { endpoint.stop() })
    }

    func testSessionStopEndsAnInFlightDial() throws {
        var config = LyteUdpSession.Config()
        config.bindAddress = "127.0.0.1"
        config.audioPlayback = false
        let crypto = try SilentHostCrypto()
        let session = LyteUdpSession(
            crypto: crypto, config: config,
            videoSink: HeadlessVideoSink(), onEvent: { _ in })
        assertCancelledPromptly(
            dialing: crypto.dialing,
            start: { try session.start() },
            stop: { session.stop() })
        XCTAssertNil(session.core, "a cancelled dial publishes no core")
        XCTAssertThrowsError(try session.start(),
                             "a stopped session never dials again")
    }
}
