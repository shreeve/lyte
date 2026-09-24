import XCTest
import Foundation
import LyteClientSession
import LyteTransport
import LyteWire

/// The shared model's live feed: BeaconEchoResponder closes samples into
/// the one HostClockModel every consumer maps through.
final class HostClockModelTests: XCTestCase {
    // MARK: - The live feed seam

    func testResponderFeedsTheModelPerClosedSample() throws {
        // BeaconEchoResponder → onClockSample → model, end to end: the
        // worked example's exchange closes one sample carrying its own
        // t2 as the regression coordinate.
        let model = HostClockModel()
        let clock = TickingClock(start: 1_253_500)
        let responder = BeaconEchoResponder(
            now: { clock.next() },
            onClockSample: { model.ingest($0) },
            emit: { _ in })

        let first = ClockBeacon(
            beaconSeq: 0, hostSend: HostTimestamp(microseconds: 1_000_000))
        responder.handleCtrlPayload(first.encode(), arrivalMicroseconds: 1_253_000)
        XCTAssertNil(model.estimate(), "no mirror yet, nothing fed")

        let second = ClockBeacon(
            beaconSeq: 1,
            hostSend: HostTimestamp(microseconds: 2_000_000),
            lastEcho: ClockBeacon.LastEcho(
                beaconSeq: 0,
                clientSend: ClientTimestamp(microseconds: 1_253_500),
                hostReceive: HostTimestamp(microseconds: 1_008_500)))
        responder.handleCtrlPayload(second.encode(), arrivalMicroseconds: 2_253_000)

        let fit = try XCTUnwrap(model.estimate())
        XCTAssertEqual(fit.offsetMicroseconds, 249_000,
                       "the worked example's offset, straight through the seam")
        XCTAssertEqual(fit.minRttMicroseconds, 8_000)
        XCTAssertEqual(fit.anchor.microseconds, 1_253_000,
                       "the coordinate is the exchange's t2, not the mirror's arrival")
    }

    private final class TickingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64
        init(start: UInt64) { value = start }
        func next() -> ClientTimestamp {
            lock.lock()
            defer { lock.unlock() }
            let v = value
            value += 1_000_000
            return ClientTimestamp(microseconds: v)
        }
    }
}
