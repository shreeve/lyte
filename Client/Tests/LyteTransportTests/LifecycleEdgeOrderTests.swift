import LyteClientTestKit
import Foundation
@testable import LyteTransport
import LyteWire
import XCTest

/// Lifecycle edges reach the owner in decision order even when the
/// machine beat and the receive thread's FROZEN pass interleave.
final class LifecycleEdgeOrderTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64 = 1_000
        var value: UInt64 {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    func testSupersededFrozenEdgeIsNotDeliveredAfterTheActiveOne() throws {
        let crypto = PassthroughTransportCrypto()
        let clock = Clock()
        let states = Locked<[SessionState]>()
        let core = LyteUdpSessionCore(
            demux: ReceiveDemux(crypto: crypto),
            sender: TransportSender(crypto: crypto, transmit: { _ in true }),
            now: { ClientTimestamp(microseconds: clock.value) },
            videoSink: HeadlessVideoSink(),
            onEvent: { event in
                if case .stateChanged(let state) = event { states.append(state) }
            })
        let envelope = Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0)

        // The beat decides FROZEN; before it delivers, a datagram's
        // immediate pass decides ACTIVE and delivers first.
        var interleaved = false
        core.testingBeforeLifecycleExecution = {
            guard !interleaved else { return }
            interleaved = true
            core.handleDatagram(
                .accepted(envelope: envelope, payload: [0x7F]),
                arrivalMicroseconds: 0)
        }
        clock.value += 3_000_000
        core.tick(now: ClientTimestamp(microseconds: clock.value))

        XCTAssertTrue(interleaved)
        XCTAssertEqual(core.state, .active)
        XCTAssertEqual(states.all, [.active],
                       "the superseded FROZEN edge must not follow ACTIVE")
    }
}
