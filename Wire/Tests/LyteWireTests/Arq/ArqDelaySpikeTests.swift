import XCTest
import LyteWire
import LyteWireTestKit

// A delay spike is not loss. A Wi-Fi radio episode holds every datagram
// in both directions for ~200 ms and then releases them all; nothing is
// lost, so every retransmit the sender fires inside the hole arrives as a
// duplicate the receiver already holds (and re-ACKs). The PTO's 10 ms
// floor and two-segment probes are deliberate — a lost keystroke is
// repaired in one PTO — so a spike costs a bounded handful of probes as
// the backoff doubles (10, 30, 70, 150 ms), never an unbounded train, and
// delivery stays exactly once.

final class ArqDelaySpikeTests: XCTestCase {
    typealias Endpoint = ArqEndpoint<HostClock>

    private struct Flight {
        var at: UInt64
        var toB: Bool
        var bytes: [UInt8]
    }

    /// Runs `seconds` of one message every `intervalMicros` from A to B
    /// over a `oneWayMicros` path, with spikes that hold everything in
    /// flight or sent inside [start, start + length) until the spike
    /// ends; returns the duplicate segments B saw and the messages it
    /// delivered.
    private func run(
        seconds: UInt64, intervalMicros: UInt64, oneWayMicros: UInt64,
        spikes: [(start: UInt64, length: UInt64)],
        config: ArqConfig = ArqConfig()
    ) throws -> (duplicates: Int, delivered: Int, sent: Int) {
        var a = Endpoint(channel: .ctrl, config: config)
        var b = Endpoint(channel: .ctrl, config: config)
        var flights: [Flight] = []
        var duplicates = 0
        var delivered = 0
        var sent = 0
        func arrival(sentAt: UInt64) -> UInt64 {
            var at = sentAt + oneWayMicros
            for spike in spikes
            where at >= spike.start && at < spike.start + spike.length {
                at = spike.start + spike.length + oneWayMicros
            }
            return at
        }
        let end = seconds * 1_000_000
        var now: UInt64 = 0
        var nextMessage: UInt64 = 0
        while now <= end {
            let stamp = HostTimestamp(microseconds: now)
            if now >= nextMessage {
                try a.send(message: [0x20, UInt8(truncatingIfNeeded: sent)], now: stamp)
                sent += 1
                nextMessage += intervalMicros
            }
            // Deliver everything due.
            let due = flights.filter { $0.at <= now }
            flights.removeAll { $0.at <= now }
            for flight in due {
                if flight.toB {
                    for event in b.ingest(payload: flight.bytes, now: stamp) {
                        switch event {
                        case .message: delivered += 1
                        case .ignored(.duplicateSegment): duplicates += 1
                        default: break
                        }
                    }
                } else {
                    _ = a.ingest(payload: flight.bytes, now: stamp)
                }
            }
            for datagram in a.poll(now: stamp).datagrams {
                flights.append(Flight(
                    at: arrival(sentAt: now), toB: true, bytes: datagram))
            }
            for datagram in b.poll(now: stamp).datagrams {
                flights.append(Flight(
                    at: arrival(sentAt: now), toB: false, bytes: datagram))
            }
            now += 500
        }
        return (duplicates, delivered, sent)
    }

    /// Ten 200 ms spikes, one every 2 s, on a 5 ms-RTT path carrying a
    /// keystroke every 100 ms: at most six duplicate segments per spike,
    /// every message delivered once.
    func testDelaySpikeCostsABoundedHandfulOfProbes() throws {
        let spikes = (0..<10).map {
            (start: UInt64(1_500_000 + $0 * 2_000_000), length: UInt64(200_000))
        }
        let run = try run(
            seconds: 22, intervalMicros: 100_000, oneWayMicros: 2_500,
            spikes: spikes)
        XCTAssertGreaterThanOrEqual(run.delivered, run.sent - 1,
            "only the message sent at the last instant may still be in flight")
        XCTAssertLessThanOrEqual(run.duplicates, 6 * spikes.count,
            "\(run.duplicates) duplicate segments over \(spikes.count) spikes")
    }
}
