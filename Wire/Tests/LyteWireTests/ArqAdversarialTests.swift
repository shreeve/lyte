import XCTest
import LyteWire
import LyteWireTestKit

// Gate W-G4(c): adversarial shapes. We own this flood surface with no
// RFC 9000 lineage (Lyte-UDP decision §7), so the bound is proven, not
// assumed: ACK forgery and ACK replay never induce livelock or
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

    func testReplayedAckStormIsBounded() throws {
        // Capture a legitimate early ACK, then replay it relentlessly.
        var a = Endpoint(channel: .ctrl)
        var b = Endpoint(channel: .ctrl)
        for i in 0..<6 {
            try a.send(message: [0x51, UInt8(i)], now: at(0))
        }
        let (datagrams, _) = a.poll(now: at(0))
        let segments = try datagrams.flatMap { try ArqFrame.decodeAll($0) }
        // Deliver only the first two segments; capture that partial ACK.
        for frame in segments.prefix(2) {
            _ = b.ingest(payload: frame.encode(), now: at(1_000))
        }
        let (captured, _) = b.poll(now: at(1_000))
        XCTAssertEqual(captured.count, 1)

        _ = a.ingest(payload: captured[0], now: at(2_000))
        var extraSends = 0
        for round in 0..<200 {
            _ = a.ingest(payload: captured[0], now: at(3_000 + UInt64(round)))
            let (out, _) = a.poll(now: at(3_000 + UInt64(round)))
            extraSends += out.count
        }
        // Replays carry no new information: zero retransmits before the
        // PTO, no matter how many arrive.
        XCTAssertEqual(extraSends, 0)
    }

    func testGarbageFloodNeverTrapsAndNeverBlocksProgress() {
        var rng = SplitMix64(seed: 0xADD_002)
        runUnderAttack(messageCount: 4) { _, a in
            for _ in 0..<25 {
                var bytes = rng.bytes(Int.random(in: 0...600, using: &rng))
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
                body: rng.bytes(Int.random(in: 1...32, using: &rng))
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

    func testHostileEndlessMessagePoisonsInsteadOfConsuming() throws {
        // A hostile stream that never ends a message must not grow
        // memory past maxMessageByteCount: the group poisons loudly.
        let config = ArqConfig(
            maxSegmentBodyByteCount: 64, maxMessageByteCount: 256
        )
        var b = Endpoint(channel: .ctrl, config: config)
        var poisoned = false
        var seq: UInt16 = 0
        for _ in 0..<50 {
            let segment = try ArqSegment(
                group: .orderedStream,
                seq: ArqSegmentSeq(rawValue: seq),
                endOfMessage: false,
                body: [UInt8](repeating: 0xEE, count: 64)
            )
            seq &+= 1
            for event in b.ingest(payload: segment.encode(), now: at(1)) {
                if case .ignored(.messageOverBudget) = event {
                    poisoned = true
                }
                if case .message = event {
                    XCTFail("an unterminated message must never deliver")
                }
            }
        }
        XCTAssertTrue(poisoned)
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
}
