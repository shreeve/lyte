import XCTest
import LyteWire
import LyteWireTestKit

// Gate W-G4(a): exhaustive small-case model checking. Five single-
// segment datagrams across two groups — the ordered stream (two
// messages, seqs i, i+1) and one-shot group 7 (one message in three
// segments) — enumerated over every combination of ≤2 losses, ≤2
// duplications, and every delivery order of the surviving multiset.
// For each of the ~166k scenarios (the whole space, twice: once at
// initial seq 0 and once crossing the u16 wrap):
//
//   - exactly-once, in-order, byte-exact delivery per group at every
//     step of the scripted phase;
//   - independence: a group whose datagrams all arrived has delivered
//     everything by the end of the scripted phase, no matter what
//     happened to the other group (no cross-group head-of-line);
//   - termination: a lossless recovery phase (fresh sender state, so
//     every segment is offered again — the receiver's dedupe is what
//     is under test) converges to full delivery and quiescence within
//     a bounded number of rounds.

final class ArqExhaustiveTests: XCTestCase {

    typealias Endpoint = ArqEndpoint<HostClock>

    private static let streamMessages: [[UInt8]] = [
        [0x11, 0x01, 0x02],          // datagram 0: stream seq i
        [0x11, 0x03, 0x04],          // datagram 1: stream seq i+1
    ]
    private static let oneShotGroup = ArqGroupId(rawValue: 7)
    private static let oneShotMessage: [UInt8] =
        [0x12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]  // datagrams 2–4

    private static func config(initialSeq: UInt16) -> ArqConfig {
        ArqConfig(
            maxSegmentBodyByteCount: 4,  // 12 B one-shot → 3 segments
            initialSegmentSeq: initialSeq
        )
    }

    /// A sender with the whole script queued (nothing polled yet).
    private static func makeSender(initialSeq: UInt16) throws -> Endpoint {
        var sender = Endpoint(
            channel: .ctrl, config: config(initialSeq: initialSeq)
        )
        let t0 = HostTimestamp(microseconds: 0)
        for message in streamMessages {
            try sender.send(message: message, now: t0)
        }
        try sender.sendOneShot(
            message: oneShotMessage, group: oneShotGroup, now: t0
        )
        return sender
    }

    /// The five scripted payloads, one segment frame each, with the
    /// index sets each group needs for full delivery.
    private static func makePayloads(
        initialSeq: UInt16
    ) throws -> (payloads: [[UInt8]], streamIndices: [Set<Int>], oneShotIndices: Set<Int>) {
        var sender = try makeSender(initialSeq: initialSeq)
        let (datagrams, _) = sender.poll(now: HostTimestamp(microseconds: 0))
        let frames = try datagrams.flatMap { try ArqFrame.decodeAll($0) }
        var payloads: [[UInt8]] = []
        var streamIdx: [Int] = []
        var oneShotIdx: Set<Int> = []
        for frame in frames {
            guard case .segment(let segment) = frame else {
                XCTFail("non-segment frame in the script")
                continue
            }
            if segment.group == .orderedStream {
                streamIdx.append(payloads.count)
            } else {
                oneShotIdx.insert(payloads.count)
            }
            payloads.append(segment.encode())
        }
        XCTAssertEqual(payloads.count, 5)
        XCTAssertEqual(streamIdx.count, 2)
        XCTAssertEqual(oneShotIdx.count, 3)
        // Message 0 needs stream segment 0; message 1 needs both.
        let streamNeeds: [Set<Int>] = [
            [streamIdx[0]], [streamIdx[0], streamIdx[1]],
        ]
        return (payloads, streamNeeds, oneShotIdx)
    }

    func testExhaustiveInterleavings() throws {
        var scenarios = 0
        for initialSeq in [UInt16(0), UInt16(0xFFFE)] {
            scenarios += try runEnumeration(initialSeq: initialSeq)
        }
        // The full space: Σ C(5,L)·C(5−L,D)·(5−L+D)! over L,D ≤ 2
        // = 82,620, run twice (plain + wrap-crossing).
        XCTAssertEqual(scenarios, 165_240)
    }

    private func runEnumeration(initialSeq: UInt16) throws -> Int {
        let (payloads, streamNeeds, oneShotNeeds) =
            try Self.makePayloads(initialSeq: initialSeq)
        var scenarios = 0

        for lossMask in subsets(of: Array(0..<5), maxCount: 2) {
            let survivors = (0..<5).filter { !lossMask.contains($0) }
            for dupSet in subsets(of: survivors, maxCount: 2) {
                let instances = survivors + dupSet
                forEachPermutation(instances) { order in
                    scenarios += 1
                    self.runScenario(
                        order: order,
                        payloads: payloads,
                        streamNeeds: streamNeeds,
                        oneShotNeeds: oneShotNeeds,
                        initialSeq: initialSeq
                    )
                }
            }
        }
        return scenarios
    }

    private func runScenario(
        order: [Int],
        payloads: [[UInt8]],
        streamNeeds: [Set<Int>],
        oneShotNeeds: Set<Int>,
        initialSeq: UInt16
    ) {
        let label = "seq \(initialSeq), order \(order)"
        var receiver = Endpoint(
            channel: .ctrl, config: Self.config(initialSeq: initialSeq)
        )
        var deliveredStream: [[UInt8]] = []
        var deliveredOneShot: [[UInt8]] = []

        func absorb(_ events: [ArqEvent], step: String) {
            for event in events {
                guard case .message(let group, let bytes) = event else {
                    continue
                }
                if group == .orderedStream {
                    deliveredStream.append(bytes)
                } else if group == Self.oneShotGroup {
                    deliveredOneShot.append(bytes)
                } else {
                    XCTFail("\(label) [\(step)]: message on foreign group")
                }
            }
            // Exactly-once + in-order + byte-exact, checked every step.
            XCTAssertEqual(
                deliveredStream,
                Array(Self.streamMessages.prefix(deliveredStream.count)),
                "\(label) [\(step)]: stream delivery is not an in-order prefix"
            )
            XCTAssertLessThanOrEqual(
                deliveredOneShot.count, 1,
                "\(label) [\(step)]: one-shot delivered twice"
            )
            if let delivered = deliveredOneShot.first {
                XCTAssertEqual(
                    delivered, Self.oneShotMessage,
                    "\(label) [\(step)]: one-shot bytes differ"
                )
            }
        }

        // Scripted phase: the chosen interleaving, no ACKs flowing back
        // (the all-ACKs-lost worst case).
        let scriptedTime = HostTimestamp(microseconds: 1_000)
        for instance in order {
            absorb(
                receiver.ingest(payload: payloads[instance], now: scriptedTime),
                step: "scripted \(instance)"
            )
        }

        // Independence: a group whose datagrams all arrived owes nothing.
        let present = Set(order)
        if oneShotNeeds.isSubset(of: present) {
            XCTAssertEqual(
                deliveredOneShot.count, 1,
                "\(label): complete one-shot group held back — cross-group HOL"
            )
        }
        for (index, needs) in streamNeeds.enumerated()
        where needs.isSubset(of: present) {
            XCTAssertGreaterThan(
                deliveredStream.count, index,
                "\(label): stream message \(index) complete but undelivered"
            )
        }

        // Recovery phase: a fresh sender offers every segment again over
        // a lossless in-order pipe; the receiver's dedupe and the ACK
        // machinery must converge to full delivery and quiescence.
        guard var sender = try? Self.makeSender(initialSeq: initialSeq) else {
            return XCTFail("\(label): sender rebuild failed")
        }
        var round = 0
        var oneShotAckSeen = false
        while round < 50 {
            round += 1
            let now = HostTimestamp(microseconds: 10_000 * UInt64(round))
            let (out, _) = sender.poll(now: now)
            for datagram in out {
                XCTAssertLessThanOrEqual(
                    datagram.count, WireBudget.maxPlaintextShardByteCount
                )
                absorb(
                    receiver.ingest(payload: datagram, now: now),
                    step: "recovery \(round)"
                )
            }
            let (acks, _) = receiver.poll(now: now)
            for datagram in acks {
                for event in sender.ingest(payload: datagram, now: now) {
                    if case .oneShotAcknowledged(let group) = event {
                        XCTAssertEqual(group, Self.oneShotGroup)
                        XCTAssertFalse(
                            oneShotAckSeen,
                            "\(label): one-shot acknowledged twice"
                        )
                        oneShotAckSeen = true
                    }
                }
            }
            if sender.isQuiescent && receiver.isQuiescent { break }
        }

        // Termination + totality.
        XCTAssertLessThan(round, 50, "\(label): recovery did not terminate")
        XCTAssertEqual(deliveredStream, Self.streamMessages, label)
        XCTAssertEqual(deliveredOneShot, [Self.oneShotMessage], label)
        XCTAssertTrue(oneShotAckSeen, label)
    }

    // MARK: Enumeration helpers

    /// All subsets of `items` with at most `maxCount` elements.
    private func subsets(of items: [Int], maxCount: Int) -> [[Int]] {
        var result: [[Int]] = [[]]
        for count in 1...maxCount {
            result += combinations(of: items, choosing: count)
        }
        return result
    }

    private func combinations(
        of items: [Int], choosing count: Int
    ) -> [[Int]] {
        guard count > 0 else { return [[]] }
        guard items.count >= count else { return [] }
        var result: [[Int]] = []
        for (offset, item) in items.enumerated() {
            for rest in combinations(
                of: Array(items[(offset + 1)...]), choosing: count - 1
            ) {
                result.append([item] + rest)
            }
        }
        return result
    }

    /// Heap's algorithm; duplicate instances yield repeated orders,
    /// which is harmless (the space stays exhaustive).
    private func forEachPermutation(
        _ items: [Int], _ body: ([Int]) -> Void
    ) {
        var a = items
        func heap(_ k: Int) {
            if k == 1 {
                body(a)
                return
            }
            for i in 0..<k {
                heap(k - 1)
                if k % 2 == 0 {
                    a.swapAt(i, k - 1)
                } else {
                    a.swapAt(0, k - 1)
                }
            }
        }
        if a.isEmpty {
            body(a)
        } else {
            heap(a.count)
        }
    }
}
