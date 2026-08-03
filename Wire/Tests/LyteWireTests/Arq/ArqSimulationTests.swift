import XCTest
import Foundation
import LyteWire
import LyteWireTestKit

// Gate W-G4(b): seeded property simulation. Each trial derives a whole
// world from its seed — fault profile (loss to 30%, duplication, delay
// jitter to 5× the path RTT, displacement reordering falling out of the
// jitter), segment sizing, u16 wrap crossings, and a bidirectional
// workload of stream and one-shot messages with staggered send times —
// then runs both endpoints against SimNet under invariants checked at
// every delivery:
//
//   - per (direction, group): delivered messages are an in-order,
//     byte-exact prefix of the sent messages (exactly-once falls out);
//   - every emitted datagram respects the 1112 B shard budget;
//   - total datagrams stay under a retransmit-storm tripwire;
//   - the trial terminates: full delivery, one completion event per
//     one-shot group, both endpoints quiescent, inside simulated 240 s.
//
// Any failure names its seed; rerun with LYTE_ARQ_SEED=<seed> to
// reproduce a single trial. The in-tree default of 25k trials keeps
// `swift test` fast (the W-G1 precedent); the full W-G4 bar runs with
// LYTE_ARQ_TRIALS=1000000, recorded in the slice's gate evidence.

final class ArqSimulationTests: XCTestCase {

    typealias Endpoint = ArqEndpoint<HostClock>

    func testSeededRandomizedTrials() {
        let env = ProcessInfo.processInfo.environment
        if let single = env["LYTE_ARQ_SEED"].flatMap(UInt64.init) {
            runTrial(seed: single)
            return
        }
        let trials = env["LYTE_ARQ_TRIALS"].flatMap(Int.init) ?? 25_000
        let masterSeed: UInt64 = 0x57_33_A2_00 // stable base
        for trial in 0..<trials {
            runTrial(seed: masterSeed &+ UInt64(trial))
        }
    }

    private struct SentLedger {
        var stream: [[UInt8]] = []
        var oneShots: [UInt16: [UInt8]] = [:]
    }

    private struct DeliveredLedger {
        var stream: [[UInt8]] = []
        var oneShots: [UInt16: [[UInt8]]] = [:]
    }

    private func runTrial(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let label = "seed \(seed)"
        let horizon: UInt64 = 240_000_000

        // Fault profile.
        let baseDelay = Int64.random(in: 1_000...25_000, using: &rng)
        let net = SimNetConfig(
            lossRate: Double.random(in: 0...0.30, using: &rng),
            duplicateRate: Double.random(in: 0...0.10, using: &rng),
            baseDelayMicroseconds: baseDelay,
            // Up to 5× the nominal RTT (2 × one-way base) of extra
            // delay — the reorder source.
            jitterMicroseconds: Int64.random(
                in: 0...(10 * baseDelay), using: &rng
            )
        )
        var pipe = SimNet(config: net, seed: rng.next())

        // Endpoint config: shared knobs, occasional wrap crossing,
        // small segment bodies so multi-segment paths exercise cheaply.
        let initialSeq: UInt16 = Int.random(in: 0..<4, using: &rng) == 0
            ? 0xFFF0 &+ UInt16.random(in: 0...31, using: &rng)
            : 0
        let bodyCeiling = [16, 64, 256].randomElement(using: &rng)!
        let config = ArqConfig(
            maxSegmentBodyByteCount: bodyCeiling,
            // This gate promises reliable convergence throughout its
            // 240-second world. Keep the independent abandoned-group
            // admission policy from expiring an honest in-flight group
            // before the property horizon; adversarial tests pin that
            // policy separately.
            receiveGroupLifetimeMicroseconds: Int64(horizon) + 1,
            initialSegmentSeq: initialSeq
        )
        var endpoints = [
            Endpoint(channel: .ctrl, config: config),
            Endpoint(channel: .ctrl, config: config),
        ]

        // Workload: staggered sends, both directions, both shapes.
        struct PendingSend {
            var time: UInt64
            var source: Int
            var isOneShot: Bool
            var group: ArqGroupId? // assigned after time-sorting
            var bytes: [UInt8]
        }
        var sent = [SentLedger(), SentLedger()]
        var pending: [PendingSend] = []
        let streamCounts = [
            Int.random(in: 0...3, using: &rng),
            Int.random(in: 0...2, using: &rng),
        ]
        let oneShotCounts = [
            Int.random(in: 0...2, using: &rng),
            Int.random(in: 0...1, using: &rng),
        ]
        for source in 0...1 {
            for _ in 0..<streamCounts[source] {
                pending.append(PendingSend(
                    time: UInt64.random(in: 0...400_000, using: &rng),
                    source: source,
                    isOneShot: false,
                    group: nil,
                    bytes: rng.bytes(
                        Int.random(in: 1...(3 * bodyCeiling), using: &rng)
                    )
                ))
            }
            for _ in 0..<oneShotCounts[source] {
                pending.append(PendingSend(
                    time: UInt64.random(in: 0...400_000, using: &rng),
                    source: source,
                    isOneShot: true,
                    group: nil,
                    bytes: rng.bytes(
                        Int.random(in: 1...(3 * bodyCeiling), using: &rng)
                    )
                ))
            }
        }
        if pending.isEmpty {
            pending.append(PendingSend(
                time: 0, source: 0, isOneShot: false, group: nil,
                bytes: [0x42]
            ))
        }
        // Stream order per direction = send-time order; one-shot ids
        // must ascend per endpoint, so number them after time-sorting.
        pending.sort { ($0.time, $0.source) < ($1.time, $1.source) }
        var nextOneShotId: [UInt16] = [1, 1]
        for index in pending.indices where pending[index].isOneShot {
            let source = pending[index].source
            pending[index].group =
                ArqGroupId(rawValue: nextOneShotId[source])
            nextOneShotId[source] += 1
        }
        var delivered = [DeliveredLedger(), DeliveredLedger()]
        var oneShotAcks = [Set<UInt16>(), Set<UInt16>()]
        var totalSegments = 0

        func checkInvariants(destination: Int, step: String) {
            let sentLedger = sent[1 - destination]
            let got = delivered[destination]
            XCTAssertEqual(
                got.stream,
                Array(sentLedger.stream.prefix(got.stream.count)),
                "\(label) [\(step)]: stream not an in-order prefix"
            )
            for (group, messages) in got.oneShots {
                XCTAssertLessThanOrEqual(
                    messages.count, 1,
                    "\(label) [\(step)]: one-shot \(group) delivered twice"
                )
                if let message = messages.first {
                    XCTAssertEqual(
                        message, sentLedger.oneShots[group],
                        "\(label) [\(step)]: one-shot \(group) bytes differ"
                    )
                }
            }
        }

        func absorb(_ events: [ArqEvent], destination: Int, step: String) {
            for event in events {
                switch event {
                case .message(let group, let bytes):
                    if group == .orderedStream {
                        delivered[destination].stream.append(bytes)
                    } else {
                        delivered[destination]
                            .oneShots[group.rawValue, default: []]
                            .append(bytes)
                    }
                case .oneShotAcknowledged(let group):
                    XCTAssertFalse(
                        oneShotAcks[destination].contains(group.rawValue),
                        "\(label) [\(step)]: duplicate completion for \(group)"
                    )
                    oneShotAcks[destination].insert(group.rawValue)
                case .ignored:
                    break
                }
            }
            checkInvariants(destination: destination, step: step)
        }

        // The event loop.
        var now: UInt64 = 0
        var steps = 0
        while now <= horizon {
            steps += 1
            if steps > 500_000 {
                return XCTFail("\(label): step bound exceeded — livelock")
            }

            // Application sends due at `now`.
            while let next = pending.first, next.time <= now {
                pending.removeFirst()
                let instant = HostTimestamp(microseconds: now)
                do {
                    if let group = next.group {
                        try endpoints[next.source].sendOneShot(
                            message: next.bytes, group: group, now: instant
                        )
                        sent[next.source].oneShots[group.rawValue] = next.bytes
                    } else {
                        try endpoints[next.source].send(
                            message: next.bytes, now: instant
                        )
                        sent[next.source].stream.append(next.bytes)
                    }
                    totalSegments +=
                        (next.bytes.count + bodyCeiling - 1) / bodyCeiling
                } catch {
                    return XCTFail("\(label): send refused: \(error)")
                }
            }

            // Network deliveries due at `now`.
            for delivery in pipe.deliveries(upTo: now) {
                absorb(
                    endpoints[delivery.destination].ingest(
                        payload: delivery.bytes,
                        now: HostTimestamp(microseconds: now)
                    ),
                    destination: delivery.destination,
                    step: "t=\(now)"
                )
            }

            // Poll both ends; their output enters the pipe.
            var deadlines: [UInt64] = []
            for index in 0...1 {
                let (datagrams, deadline) = endpoints[index].poll(
                    now: HostTimestamp(microseconds: now)
                )
                for datagram in datagrams {
                    XCTAssertLessThanOrEqual(
                        datagram.count,
                        WireBudget.maxPlaintextShardByteCount,
                        "\(label): datagram over shard budget"
                    )
                    pipe.send(from: index, bytes: datagram, now: now)
                }
                if let deadline {
                    deadlines.append(deadline.microseconds)
                }
            }

            // Retransmit-storm tripwire.
            XCTAssertLessThan(
                pipe.sentCount, 100 * max(totalSegments, 1) + 2_000,
                "\(label): datagram volume exploded"
            )

            // Done?
            let done = pending.isEmpty
                && pipe.nextArrivalTime == nil
                && endpoints[0].isQuiescent
                && endpoints[1].isQuiescent
                && deadlines.isEmpty
            if done { break }

            // Advance the virtual clock to the next event.
            var candidates = deadlines
            if let arrival = pipe.nextArrivalTime {
                candidates.append(arrival)
            }
            if let send = pending.first?.time {
                candidates.append(send)
            }
            let next = candidates.min() ?? (now + 10_000)
            now = max(next, now + 1)
        }

        XCTAssertLessThanOrEqual(
            now, horizon, "\(label): did not converge inside 240 s"
        )

        // Totality: everything sent was delivered, exactly once, and
        // every one-shot group raised exactly one completion.
        for destination in 0...1 {
            let sentLedger = sent[1 - destination]
            XCTAssertEqual(
                delivered[destination].stream, sentLedger.stream,
                "\(label): stream to \(destination) incomplete"
            )
            for (group, bytes) in sentLedger.oneShots {
                XCTAssertEqual(
                    delivered[destination].oneShots[group], [bytes],
                    "\(label): one-shot \(group) to \(destination) incomplete"
                )
                XCTAssertTrue(
                    oneShotAcks[1 - destination].contains(group),
                    "\(label): one-shot \(group) never acknowledged"
                )
            }
        }
    }
}
