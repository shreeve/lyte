import XCTest
import LyteWire
import LyteWireTestKit

// Adversarial shapes. Lyte owns this flood surface with no RFC 9000
// lineage, so the bound is proven, not assumed: ACK forgery and ACK replay never induce livelock or
// unbounded retransmission, garbage never traps, and the protocol
// still completes underneath the attack. The mechanism under test is
// the fast-retransmit high-mark gate (only an ACK that ADVANCES the
// group's highest-ever acked seq may trigger retransmits) plus the
// unsent-data forgery bound and PTO backoff.

final class ArqAdversarialTests: XCTestCase {

    typealias Endpoint = ArqEndpoint<HostClock>

    private func at(_ microseconds: UInt64) -> HostTimestamp {
        HostTimestamp(microseconds: microseconds)
    }

    /// Runs a full A→B exchange over a lossless direct wire while an
    /// attacker injects `attack(step)` payloads into A before every
    /// poll. Returns the number of datagrams A emitted in total.
    @discardableResult
    private func runUnderAttack(
        messageCount: Int,
        rounds: Int = 40,
        attack: (Int, inout Endpoint) -> Void
    ) -> Int {
        var a = Endpoint(channel: .ctrl)
        var b = Endpoint(channel: .ctrl)
        let messages = (0..<messageCount).map { [0x50, UInt8($0)] }
        for message in messages {
            try? a.send(message: message, now: at(0))
        }
        var delivered: [[UInt8]] = []
        var sentByA = 0
        for round in 0..<rounds {
            let now = at(UInt64(round + 1) * 500_000)
            attack(round, &a)
            let (out, _) = a.poll(now: now)
            sentByA += out.count
            for datagram in out {
                for event in b.ingest(payload: datagram, now: now) {
                    if case .message(_, let bytes) = event {
                        delivered.append(bytes)
                    }
                }
            }
            let (acks, _) = b.poll(now: now)
            for datagram in acks {
                _ = a.ingest(payload: datagram, now: now)
            }
            if a.isQuiescent && b.isQuiescent { break }
        }
        // The attack never stops correct delivery.
        XCTAssertEqual(delivered, messages)
        XCTAssertTrue(a.isQuiescent)
        return sentByA
    }

    func testForgedRandomAcksNeverInduceRetransmitStorm() {
        var rng = SplitMix64(seed: 0xADD_001)
        let sent = runUnderAttack(messageCount: 8) { _, a in
            for _ in 0..<20 {
                let forged = try! ArqAck(blocks: [
                    ArqAck.Block(
                        channel: .ctrl,
                        group: ArqGroupId(
                            rawValue: UInt16.random(in: 0...8, using: &rng)
                        ),
                        cumulative: ArqSegmentSeq(
                            rawValue: UInt16.random(in: 0...400, using: &rng)
                        ),
                        receivedBitmap: Bool.random(using: &rng)
                            ? [UInt8.random(in: 1...255, using: &rng)] : []
                    )
                ])
                _ = a.ingest(payload: forged.encode(), now: at(1))
            }
        }
        // 8 segments + acks-driven noise: an unbounded storm would blow
        // far past this.
        XCTAssertLessThan(sent, 8 * 4)
    }

    func testGarbageFloodNeverTrapsAndNeverBlocksProgress() {
        var rng = SplitMix64(seed: 0xADD_002)
        runUnderAttack(messageCount: 4) { _, a in
            for _ in 0..<25 {
                var bytes = rng.bytes(rng.int(in: 0...600))
                if !bytes.isEmpty, Bool.random(using: &rng) {
                    bytes[0] = Bool.random(using: &rng)
                        ? CtrlMessageType.arqSegment
                        : CtrlMessageType.arqAck
                }
                _ = a.ingest(payload: bytes, now: at(1))
            }
        }
    }

    func testHostileSegmentSprayIsBoundedAndDoesNotCorrupt() throws {
        // A hostile sender sprays segments across many groups and far
        // seqs at a victim receiver: state must stay bounded and the
        // legitimate exchange must still complete exactly once.
        var rng = SplitMix64(seed: 0xADD_003)
        var a = Endpoint(channel: .ctrl)
        var b = Endpoint(channel: .ctrl)
        try a.send(message: [0x52, 1, 2, 3], now: at(0))
        let (legit, _) = a.poll(now: at(0))

        for _ in 0..<2_000 {
            let segment = try ArqSegment(
                group: ArqGroupId(
                    rawValue: UInt16.random(in: 0...9_999, using: &rng)
                ),
                seq: ArqSegmentSeq(
                    rawValue: UInt16.random(in: .min ... .max, using: &rng)
                ),
                endOfMessage: Bool.random(using: &rng),
                body: rng.bytes(rng.int(in: 1...32))
            )
            _ = b.ingest(payload: segment.encode(), now: at(500))
        }
        // The spray is capped at maxActiveReceiveGroups; the legitimate
        // message still lands intact.
        var delivered: [[UInt8]] = []
        for datagram in legit {
            for event in b.ingest(payload: datagram, now: at(1_000)) {
                if case .message(let group, let bytes) = event {
                    XCTAssertEqual(group, .orderedStream)
                    delivered.append(bytes)
                }
            }
        }
        XCTAssertEqual(delivered, [[0x52, 1, 2, 3]])
        // The victim's ACK output stays within one poll's frame bounds
        // rather than echoing the whole spray.
        let (acks, _) = b.poll(now: at(1_000))
        for datagram in acks {
            XCTAssertLessThanOrEqual(
                datagram.count, WireBudget.maxPlaintextShardByteCount
            )
        }
    }

    func testAbandonedOneShotGroupsExpireAndRestoreAdmission() throws {
        let config = ArqConfig(
            maxActiveReceiveGroups: 4,
            receiveGroupLifetimeMicroseconds: 100
        )
        var receiver = Endpoint(channel: .ctrl, config: config)
        for gid: UInt16 in 1...4 {
            let partial = try ArqSegment(
                group: ArqGroupId(rawValue: gid),
                seq: ArqSegmentSeq(rawValue: 0),
                endOfMessage: false,
                body: [UInt8(gid)]
            )
            _ = receiver.ingest(payload: partial.encode(), now: at(0))
        }

        let refused = try ArqSegment(
            group: ArqGroupId(rawValue: 5),
            seq: ArqSegmentSeq(rawValue: 0),
            endOfMessage: false,
            body: [5]
        )
        XCTAssertEqual(
            receiver.ingest(payload: refused.encode(), now: at(99)),
            [.ignored(.tooManyReceiveGroups(ArqGroupId(rawValue: 5)))]
        )

        let admitted = receiver.ingest(
            payload: refused.encode(), now: at(100)
        )
        XCTAssertFalse(admitted.contains {
            if case .ignored(.tooManyReceiveGroups) = $0 { return true }
            return false
        })
        let (acks, _) = receiver.poll(now: at(100))
        let blocks = try acks
            .flatMap { try ArqFrame.decodeAll($0) }
            .flatMap { frame -> [ArqAck.Block] in
                if case .ack(let ack) = frame { return ack.blocks }
                return []
            }
        XCTAssertEqual(blocks.map(\.group), [ArqGroupId(rawValue: 5)])
    }

    func testPoisonedOneShotIsReclaimedWithoutWaitingForLifetime() throws {
        let config = ArqConfig(
            maxMessageByteCount: 1,
            maxActiveReceiveGroups: 1,
            receiveGroupLifetimeMicroseconds: 1_000_000
        )
        var receiver = Endpoint(channel: .ctrl, config: config)
        let poisoned = try ArqSegment(
            group: ArqGroupId(rawValue: 1),
            seq: ArqSegmentSeq(rawValue: 0),
            endOfMessage: false,
            body: [1, 2]
        )
        XCTAssertTrue(
            receiver.ingest(payload: poisoned.encode(), now: at(0)).contains {
                if case .ignored(.messageOverBudget) = $0 { return true }
                return false
            }
        )
        _ = receiver.poll(now: at(0))

        let fresh = try ArqSegment(
            group: ArqGroupId(rawValue: 2),
            seq: ArqSegmentSeq(rawValue: 0),
            endOfMessage: false,
            body: [3]
        )
        XCTAssertFalse(
            receiver.ingest(payload: fresh.encode(), now: at(1)).contains {
                if case .ignored(.tooManyReceiveGroups) = $0 { return true }
                return false
            }
        )
    }

    private func segment(
        _ gid: UInt16, seq: UInt16, end: Bool = false, count: Int,
        fill: UInt8 = 0xAB
    ) throws -> [UInt8] {
        let body = [UInt8](repeating: fill, count: count)
        return try ArqSegment(
            group: ArqGroupId(rawValue: gid),
            seq: ArqSegmentSeq(rawValue: seq),
            endOfMessage: end,
            body: body
        ).encode()
    }

    /// The groups the next poll acknowledges, with each block.
    private func ackBlocks(_ endpoint: inout Endpoint, now: UInt64) throws
        -> [ArqGroupId: ArqAck.Block] {
        let (datagrams, _) = endpoint.poll(now: at(now))
        var blocks: [ArqGroupId: ArqAck.Block] = [:]
        for datagram in datagrams {
            for case .ack(let ack) in try ArqFrame.decodeAll(datagram) {
                for block in ack.blocks { blocks[block.group] = block }
            }
        }
        return blocks
    }

    /// Each open one-shot group reserves a whole message's bytes, so the
    /// budget admits budget / maxMessageByteCount groups. Refusal happens
    /// only when a group would open — unacknowledged, retried later — and
    /// never to an admitted group: its duplicates are still classified
    /// and re-ACKed with the budget full, and completing it frees its
    /// reservation. The ordered stream is outside the budget.
    func testOneShotAdmissionReservesWholeMessages() throws {
        let config = ArqConfig(
            maxMessageByteCount: 2_000, maxOneShotReceiveByteCount: 5_000
        )
        var receiver = Endpoint(channel: .ctrl, config: config)
        for gid: UInt16 in 1...2 {
            XCTAssertEqual(receiver.ingest(
                payload: try segment(gid, seq: 1, end: true, count: 1_000),
                now: at(0)), [])
        }
        let refused = ArqGroupId(rawValue: 3)
        XCTAssertEqual(
            receiver.ingest(
                payload: try segment(3, seq: 1, end: true, count: 1),
                now: at(0)),
            [.ignored(.oneShotReceiveBudgetExhausted(refused))]
        )
        XCTAssertNil(try ackBlocks(&receiver, now: 0)[refused],
                     "refused means unacknowledged")

        XCTAssertEqual(
            receiver.ingest(
                payload: try segment(0, seq: 0, end: true, count: 1_000,
                                     fill: 0x55),
                now: at(1)),
            [.message(group: .orderedStream,
                      bytes: [UInt8](repeating: 0x55, count: 1_000))]
        )

        let admitted = ArqGroupId(rawValue: 1)
        XCTAssertEqual(
            receiver.ingest(
                payload: try segment(1, seq: 1, end: true, count: 1_000),
                now: at(2)),
            [.ignored(.duplicateSegment(admitted, ArqSegmentSeq(rawValue: 1)))]
        )
        XCTAssertEqual(
            try ackBlocks(&receiver, now: 2)[admitted]?.receivedBitmap, [0x02],
            "a duplicate on an admitted group is re-ACKed at a full budget")

        let head = [UInt8](repeating: 0xAB, count: 1_000)
        XCTAssertEqual(
            receiver.ingest(payload: try segment(1, seq: 0, count: 1_000),
                            now: at(3)),
            [.message(group: admitted, bytes: head + head)]
        )
        XCTAssertEqual(receiver.ingest(
            payload: try segment(3, seq: 1, end: true, count: 1),
            now: at(4)), [])
    }

    /// A budget smaller than one message still admits one group — an
    /// unclamped budget would refuse every multi-byte one-shot forever.
    func testOneShotBudgetAlwaysAdmitsOneGroup() throws {
        let config = ArqConfig(
            maxMessageByteCount: 4_000, maxOneShotReceiveByteCount: 10
        )
        var receiver = Endpoint(channel: .ctrl, config: config)
        XCTAssertEqual(receiver.config.maxOneShotReceiveByteCount, 4_000)
        XCTAssertEqual(
            receiver.ingest(
                payload: try segment(1, seq: 0, end: true, count: 100),
                now: at(0)),
            [.message(group: ArqGroupId(rawValue: 1),
                      bytes: [UInt8](repeating: 0xAB, count: 100))]
        )
    }

    /// The memory bound under a hostile peer: groups sprayed with
    /// window-filling out-of-order segments that never start their
    /// message. The receiver never holds more than its one-shot budget:
    /// at most budget / maxMessageByteCount groups are open, and a group
    /// whose buffered bytes would pass a message's ceiling is poisoned,
    /// dropping them.
    func testHostileOneShotSprayStaysWithinTheReceiveBudget() throws {
        var receiver = Endpoint(channel: .ctrl)
        let config = receiver.config
        let body = config.maxSegmentBodyByteCount
        var held: [UInt16: Int] = [:]
        var peak = 0
        var poisonedGroups = 0
        for seq: UInt16 in 1...255 {
            for gid: UInt16 in 1...64 {
                let events = receiver.ingest(
                    payload: try segment(gid, seq: seq, count: body),
                    now: at(UInt64(seq)))
                XCTAssertLessThanOrEqual(events.count, 1)
                switch events.first {
                case nil:
                    held[gid, default: 0] += body
                case .ignored(.messageOverBudget)?:
                    held[gid] = nil
                    poisonedGroups += 1
                case .ignored(.oneShotReceiveBudgetExhausted)?,
                     .ignored(.segmentOnClosedGroup)?:
                    break
                default:
                    XCTFail("unexpected \(events) for group \(gid) seq \(seq)")
                }
                peak = max(peak, held.values.reduce(0, +))
                XCTAssertLessThanOrEqual(
                    held.count,
                    config.maxOneShotReceiveByteCount
                        / config.maxMessageByteCount)
            }
        }
        XCTAssertLessThanOrEqual(peak, config.maxOneShotReceiveByteCount)
        XCTAssertGreaterThan(poisonedGroups, 0, "the spray reached a ceiling")
    }

    /// A group given up at its lifetime stays closed: its sender's later
    /// retransmits are re-ACKed at the cumulative the group reached, so
    /// a tail the receiver dropped with the group is never acknowledged
    /// and the sender never reads an undelivered one-shot as done.
    func testExpiredOneShotIsNeverAcknowledgedPastWhatItKept() throws {
        let config = ArqConfig(receiveGroupLifetimeMicroseconds: 1_000)
        var a = Endpoint(channel: .ctrl, config: config)
        var b = Endpoint(channel: .ctrl, config: config)
        let message = [UInt8](
            repeating: 0x5A, count: 3 * config.maxSegmentBodyByteCount)
        let group = try a.sendOneShot(message: message, now: at(0))
        let (first, _) = a.poll(now: at(0))
        XCTAssertEqual(first.count, 3)
        // Only the head arrives before the group expires.
        _ = b.ingest(payload: first[0], now: at(0))
        for datagram in b.poll(now: at(0)).datagrams {
            _ = a.ingest(payload: datagram, now: at(0))
        }

        var now: UInt64 = 1_000
        while now < 120_000_000 {
            var events: [ArqEvent] = []
            for datagram in a.poll(now: at(now)).datagrams {
                events += b.ingest(payload: datagram, now: at(now))
            }
            XCTAssertFalse(events.contains {
                if case .message = $0 { return true }
                return false
            }, "an expired group never delivers")
            for datagram in b.poll(now: at(now)).datagrams {
                for event in a.ingest(payload: datagram, now: at(now)) {
                    XCTAssertNotEqual(event, .oneShotAcknowledged(group))
                }
            }
            now += 250_000
        }
    }

    /// Honest concurrent one-shots each far from done must never hold
    /// the receive budget between them: at default configs on a
    /// lossless in-order wire, eight 200 KB one-shots sent at once all
    /// deliver, byte-exact, and every acknowledgement names a delivered
    /// group.
    func testConcurrentLargeOneShotsAllDeliverUnderTheReceiveBudget() throws {
        var a = Endpoint(channel: .ctrl)
        var b = Endpoint(channel: .ctrl)
        var rng = SplitMix64(seed: 0xB0D6_E7)
        var sent: [ArqGroupId: [UInt8]] = [:]
        for _ in 0..<8 {
            let message = rng.bytes(200_000)
            sent[try a.sendOneShot(message: message, now: at(0))] = message
        }
        var delivered: [ArqGroupId: [UInt8]] = [:]
        var acknowledged: Set<ArqGroupId> = []
        var now: UInt64 = 0
        while now < 60_000_000,
              acknowledged.count < sent.count || !a.isQuiescent
                  || !b.isQuiescent {
            now += 1_000
            let (out, _) = a.poll(now: at(now))
            for datagram in out {
                for event in b.ingest(payload: datagram, now: at(now)) {
                    if case .message(let group, let bytes) = event {
                        XCTAssertNil(delivered[group], "\(group) delivered twice")
                        delivered[group] = bytes
                    }
                }
            }
            let (acks, _) = b.poll(now: at(now))
            for datagram in acks {
                for event in a.ingest(payload: datagram, now: at(now)) {
                    if case .oneShotAcknowledged(let group) = event {
                        XCTAssertNotNil(
                            delivered[group],
                            "\(group) acknowledged but never delivered")
                        acknowledged.insert(group)
                    }
                }
            }
        }
        XCTAssertEqual(Set(delivered.keys), Set(sent.keys))
        XCTAssertTrue(delivered == sent, "delivered bytes differ from sent")
        XCTAssertEqual(acknowledged, Set(sent.keys))
        XCTAssertTrue(a.isQuiescent && b.isQuiescent)
    }

    /// A message over the ceiling on the ordered stream loses it for
    /// good: the crossing segment and every later stream segment name the
    /// poisoned stream — a shell that tears down on that one reason ends
    /// the session even when nothing follows the crossing. One-shot
    /// groups keep working.
    func testPoisonedOrderedStreamIsTypedAndPermanent() throws {
        let config = ArqConfig(
            maxSegmentBodyByteCount: 64, maxMessageByteCount: 100
        )
        var receiver = Endpoint(channel: .ctrl, config: config)
        func stream(_ seq: UInt16) throws -> [UInt8] {
            try ArqSegment(
                group: .orderedStream, seq: ArqSegmentSeq(rawValue: seq),
                endOfMessage: seq == 3,
                body: [UInt8](repeating: 0xEE, count: 64)
            ).encode()
        }
        XCTAssertEqual(receiver.ingest(payload: try stream(0), now: at(0)), [])
        XCTAssertEqual(
            receiver.ingest(payload: try stream(1), now: at(0)),
            [.ignored(.orderedStreamPoisoned)]
        )
        for seq: UInt16 in 2...3 {
            XCTAssertEqual(
                receiver.ingest(payload: try stream(seq), now: at(1)),
                [.ignored(.orderedStreamPoisoned)]
            )
        }
        // Still poisoned long after any one-shot lifetime.
        _ = receiver.poll(now: at(60_000_000))
        XCTAssertEqual(
            receiver.ingest(payload: try stream(3), now: at(60_000_000)),
            [.ignored(.orderedStreamPoisoned)]
        )
        let oneShot = try ArqSegment(
            group: ArqGroupId(rawValue: 1), seq: ArqSegmentSeq(rawValue: 0),
            endOfMessage: true, body: [7]
        )
        XCTAssertEqual(
            receiver.ingest(payload: oneShot.encode(), now: at(60_000_001)),
            [.message(group: ArqGroupId(rawValue: 1), bytes: [7])]
        )
    }
}
