import Foundation
import LyteClientTestKit
import LyteTransport
import LyteWire
import XCTest

/// ARQ output is sealed and sent outside the endpoint's lock, in poll
/// order.
final class ReliableCtrlTransmitTests: XCTestCase {
    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[UInt8]] = []
        var gate: DispatchSemaphore?
        let entered = DispatchSemaphore(value: 0)

        func transmit(_ datagram: [UInt8]) -> Bool {
            let gate = lock.withLock { () -> DispatchSemaphore? in
                stored.append(datagram)
                return self.gate
            }
            if let gate {
                entered.signal()
                gate.wait()
            }
            return true
        }

        var segmentSeqs: [UInt16] {
            lock.withLock { stored }.flatMap { datagram -> [UInt16] in
                guard let (_, payload) = try? Envelope.decode(datagram),
                      let frames = try? ArqFrame.decodeAll(Array(payload))
                else { return [] }
                return frames.compactMap {
                    if case .segment(let segment) = $0,
                       segment.group == .orderedStream {
                        return segment.seq.rawValue
                    }
                    return nil
                }
            }
        }
    }

    private func endpoint(_ wire: Wire) -> ReliableCtrlEndpoint {
        let crypto = PassthroughTransportCrypto()
        return ReliableCtrlEndpoint(
            sender: TransportSender(
                crypto: crypto, transmit: { wire.transmit($0) }),
            now: { ClientTimestamp(microseconds: 1_000) })
    }

    func testReadersNeverWaitOnATransmitInFlight() throws {
        let wire = Wire()
        let gate = DispatchSemaphore(value: 0)
        wire.gate = gate
        let reliable = endpoint(wire)
        DispatchQueue.global().async {
            try? reliable.send([CtrlMessageType.inputEvent, 1])
        }
        XCTAssertEqual(wire.entered.wait(timeout: .now() + 2), .success)

        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = reliable.snapshotStats()
            _ = reliable.isQuiescent
            read.signal()
        }
        XCTAssertEqual(read.wait(timeout: .now() + 2), .success,
                       "stats and quiescence must not wait behind sendto")
        gate.signal()
        wire.gate = nil
    }

    /// The production PTO wake retransmits a lost segment on its own. The
    /// endpoint's clock runs slower than the timer's, so the first wake
    /// finds the same deadline still ahead and must re-arm for it.
    func testTheTimerRetransmitsALostSegmentOnItsOwn() {
        let wire = Wire()
        let origin = DispatchTime.now().uptimeNanoseconds
        let reliable = ReliableCtrlEndpoint(
            sender: TransportSender(
                crypto: PassthroughTransportCrypto(),
                transmit: { wire.transmit($0) }),
            config: ArqConfig(initialRttMicroseconds: 10_000),
            now: {
                let elapsed = DispatchTime.now().uptimeNanoseconds - origin
                return ClientTimestamp(microseconds: elapsed / 1_250)
            })
        reliable.start()
        defer { reliable.stop() }
        XCTAssertNoThrow(try reliable.send([CtrlMessageType.inputEvent, 1]))
        XCTAssertEqual(wire.segmentSeqs, [0], "the first copy is lost")

        let deadline = Date().addingTimeInterval(2)
        while wire.segmentSeqs.count < 2, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(wire.segmentSeqs.prefix(2), [0, 0],
                       "the PTO wake must retransmit without other traffic")
    }

    func testConcurrentSendersTransmitSegmentsInPollOrder() {
        let wire = Wire()
        let reliable = endpoint(wire)
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            for index in 0..<16 {
                try? reliable.send(
                    [CtrlMessageType.inputEvent, UInt8(worker), UInt8(index)])
            }
        }
        let seqs = wire.segmentSeqs
        XCTAssertFalse(seqs.isEmpty)
        XCTAssertEqual(seqs, seqs.sorted(),
                       "fresh segments must reach the wire in seq order")
    }
}
