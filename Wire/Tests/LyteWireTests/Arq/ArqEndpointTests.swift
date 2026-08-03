import XCTest
import LyteWire
import LyteWireTestKit

// ArqEndpoint unit behaviors: the named mechanisms one at a time, on a
// hand-driven lossless (or hand-lossy) wire. The statistical and
// exhaustive gates live in ArqExhaustiveTests / ArqSimulationTests /
// ArqAdversarialTests; this file is where a regression names itself.

final class ArqEndpointTests: XCTestCase {

    typealias Endpoint = ArqEndpoint<HostClock>

    private func at(_ microseconds: UInt64) -> HostTimestamp {
        HostTimestamp(microseconds: microseconds)
    }

    /// Delivers every datagram of one poll to the peer, returning the
    /// peer's events.
    private func shuttle(
        from a: inout Endpoint, to b: inout Endpoint, now: HostTimestamp
    ) -> [ArqEvent] {
        let (datagrams, _) = a.poll(now: now)
        var events: [ArqEvent] = []
        for datagram in datagrams {
            XCTAssertLessThanOrEqual(
                datagram.count, WireBudget.maxPlaintextShardByteCount
            )
            events += b.ingest(payload: datagram, now: now)
        }
        return events
    }

    // MARK: Ordered stream

    func testSingleMessageRoundTripAndQuiescence() throws {
        var a = Endpoint(channel: .ctrl)
        var b = Endpoint(channel: .ctrl)
        let message: [UInt8] = [0x20, 1, 2, 3]

        try a.send(message: message, now: at(0))
        let events = shuttle(from: &a, to: &b, now: at(1_000))
        XCTAssertEqual(events, [.message(group: .orderedStream, bytes: message)])

        // The ACK flows back; both ends go quiescent.
        XCTAssertEqual(shuttle(from: &b, to: &a, now: at(2_000)), [])
        XCTAssertTrue(a.isQuiescent)
        XCTAssertTrue(b.isQuiescent)
        let (datagrams, deadline) = a.poll(now: at(3_000))
        XCTAssertEqual(datagrams, [])
        XCTAssertNil(deadline)
    }

    func testMultiSegmentReassemblyByteExact() throws {
        var a = Endpoint(channel: .ctrl)
        var b = Endpoint(channel: .ctrl)
        var rng = SplitMix64(seed: 7)
        let message = [0x21] + rng.bytes(3_000)

        try a.send(message: message, now: at(0))
        let events = shuttle(from: &a, to: &b, now: at(1_000))
        XCTAssertEqual(events, [.message(group: .orderedStream, bytes: message)])
    }

    func testOrderedDeliveryUnderReversedArrival() throws {
        var a = Endpoint(channel: .ctrl)
        var b = Endpoint(channel: .ctrl)
        let messages: [[UInt8]] = [[0x22, 1], [0x22, 2], [0x22, 3]]
        for message in messages {
            try a.send(message: message, now: at(0))
        }
        let (datagrams, _) = a.poll(now: at(1_000))
        var events: [ArqEvent] = []
        for datagram in datagrams.reversed() {
            events += b.ingest(payload: datagram, now: at(2_000))
        }
        XCTAssertEqual(
            events.compactMap { event -> [UInt8]? in
                if case .message(_, let bytes) = event { return bytes }
                return nil
            },
            messages
        )
    }

    // MARK: One-shot groups

    func testOneShotIndependenceAndAckEvent() throws {
        var a = Endpoint(channel: .videoIdle)
        var b = Endpoint(channel: .videoIdle)
        let frame1: [UInt8] = [0x30, 1]
        let frame2: [UInt8] = [0x30, 2]
        try a.sendOneShot(message: frame1, group: ArqGroupId(rawValue: 1), now: at(0))
        try a.sendOneShot(message: frame2, group: ArqGroupId(rawValue: 2), now: at(0))

        let (datagrams, _) = a.poll(now: at(1_000))
        // Small frames coalesce; deliver only what belongs to group 2 by
        // filtering at the frame level: drop group 1's segments.
        var group2Events: [ArqEvent] = []
        for datagram in datagrams {
            let frames = try ArqFrame.decodeAll(datagram)
            for frame in frames {
                guard case .segment(let segment) = frame,
                      segment.group == ArqGroupId(rawValue: 2)
                else { continue }
                group2Events += b.ingest(
                    payload: segment.encode(), now: at(2_000)
                )
            }
        }
        // Group 2 delivers even though group 1 is entirely lost —
        // the no-cross-group-HOL property at its smallest.
        XCTAssertEqual(
            group2Events,
            [.message(group: ArqGroupId(rawValue: 2), bytes: frame2)]
        )

        // The ACK for group 2 comes back; the sender raises the
        // completion event for group 2 only.
        let ackEvents = shuttle(from: &b, to: &a, now: at(3_000))
        XCTAssertEqual(
            ackEvents, [.oneShotAcknowledged(ArqGroupId(rawValue: 2))]
        )
        XCTAssertFalse(a.isQuiescent) // group 1 still owes delivery
    }

    func testOneShotGroupIdDiscipline() throws {
        var a = Endpoint(channel: .videoIdle)
        try a.sendOneShot(message: [1], group: ArqGroupId(rawValue: 5), now: at(0))
        XCTAssertThrowsError(
            try a.sendOneShot(message: [1], group: ArqGroupId(rawValue: 5), now: at(0))
        ) {
            XCTAssertEqual(
                $0 as? ArqSendError,
                .oneShotGroupNotAscending(ArqGroupId(rawValue: 5))
            )
        }
        XCTAssertThrowsError(
            try a.sendOneShot(message: [1], group: ArqGroupId(rawValue: 4), now: at(0))
        )
        XCTAssertThrowsError(
            try a.sendOneShot(message: [1], group: .orderedStream, now: at(0))
        ) {
            XCTAssertEqual($0 as? ArqSendError, .orderedStreamGroupId)
        }
        XCTAssertNoThrow(
            try a.sendOneShot(message: [1], group: ArqGroupId(rawValue: 6), now: at(0))
        )
    }

    func testSendRefusesEmptyAndOversized() {
        var a = Endpoint(channel: .ctrl)
        XCTAssertThrowsError(try a.send(message: [], now: at(0))) {
            XCTAssertEqual($0 as? ArqSendError, .emptyMessage)
        }
        let oversized = [UInt8](
            repeating: 0, count: a.config.maxMessageByteCount + 1
        )
        XCTAssertThrowsError(try a.send(message: oversized, now: at(0))) {
            XCTAssertEqual(
                $0 as? ArqSendError,
                .messageOverBudget(oversized.count)
            )
        }
    }

    // MARK: Duplicates and closed groups

    func testDuplicateSegmentReportsAndReAcks() throws {
        var a = Endpoint(channel: .ctrl)
        var b = Endpoint(channel: .ctrl)
        try a.send(message: [0x23, 9], now: at(0))
        let (datagrams, _) = a.poll(now: at(1_000))
        XCTAssertEqual(datagrams.count, 1)

        _ = b.ingest(payload: datagrams[0], now: at(2_000))
        _ = b.poll(now: at(2_000)) // drain the first ACK
        let duplicate = b.ingest(payload: datagrams[0], now: at(3_000))
        XCTAssertEqual(duplicate, [.ignored(.duplicateSegment(
            .orderedStream, ArqSegmentSeq(rawValue: 0)
        ))])
        // The duplicate re-arms an ACK so a lost ACK is repaired.
        let (ackDatagrams, _) = b.poll(now: at(3_000))
        XCTAssertEqual(ackDatagrams.count, 1)
    }

    func testClosedOneShotLateRetransmitReAcked() throws {
        var a = Endpoint(channel: .videoIdle)
        var b = Endpoint(channel: .videoIdle)
        let group = ArqGroupId(rawValue: 3)
        try a.sendOneShot(message: [0x31, 7], group: group, now: at(0))
        let (datagrams, _) = a.poll(now: at(1_000))
        _ = b.ingest(payload: datagrams[0], now: at(2_000))
        _ = b.poll(now: at(2_000)) // ACK emitted (and dropped here)

        // The retransmit of the already-delivered segment.
        let late = b.ingest(payload: datagrams[0], now: at(300_000))
        XCTAssertEqual(late, [.ignored(.segmentOnClosedGroup(
            group, ArqSegmentSeq(rawValue: 0)
        ))])
        let (reAck, _) = b.poll(now: at(300_000))
        XCTAssertEqual(reAck.count, 1)
        // That re-ACK completes the sender.
        let events = a.ingest(payload: reAck[0], now: at(301_000))
        XCTAssertEqual(events, [.oneShotAcknowledged(group)])
        XCTAssertTrue(a.isQuiescent)
    }

    // MARK: Loss recovery

    func testPtoRetransmitWithBackoffAndReset() throws {
        var a = Endpoint(channel: .ctrl)
        var b = Endpoint(channel: .ctrl)
        try a.send(message: [0x24, 1], now: at(0))

        let (first, deadline1) = a.poll(now: at(0))
        XCTAssertEqual(first.count, 1)
        // No RTT sample yet: PTO = 2 × initialRtt.
        let pto = UInt64(2 * a.config.initialRttMicroseconds)
        XCTAssertEqual(deadline1, at(pto))

        // Nothing to do before the deadline.
        let (quiet, _) = a.poll(now: at(pto - 1))
        XCTAssertEqual(quiet, [])

        // At the deadline: byte-identical segment retransmit, doubled
        // next interval.
        let (retx, deadline2) = a.poll(now: at(pto))
        XCTAssertEqual(retx, first)
        XCTAssertEqual(deadline2, at(pto + 2 * pto))

        // The retransmit lands; the ACK resets backoff and retires the
        // segment — quiescent, no timer.
        _ = b.ingest(payload: retx[0], now: at(pto + 1_000))
        let events = shuttle(from: &b, to: &a, now: at(pto + 2_000))
        XCTAssertEqual(events, [])
        let (_, deadline3) = a.poll(now: at(pto + 3_000))
        XCTAssertNil(deadline3)
        XCTAssertTrue(a.isQuiescent)
    }

    func testFastRetransmitAtPacketThreshold() throws {
        var a = Endpoint(channel: .ctrl)
        var b = Endpoint(channel: .ctrl)
        // Five single-segment messages: seqs 0…4.
        for i in 0..<5 {
            try a.send(message: [0x25, UInt8(i)], now: at(0))
        }
        let (datagrams, _) = a.poll(now: at(0))
        let segments = try datagrams.flatMap { try ArqFrame.decodeAll($0) }
        XCTAssertEqual(segments.count, 5)

        // Deliver 1…4, losing 0. Nothing delivers (in-order hold), and
        // the ACK names the hole.
        for frame in segments.dropFirst() {
            let events = b.ingest(payload: frame.encode(), now: at(1_000))
            XCTAssertTrue(events.isEmpty)
        }
        let (acks, _) = b.poll(now: at(1_000))
        XCTAssertEqual(acks.count, 1)

        // seq 0 sits packetThreshold (3) behind the acked high mark →
        // immediate retransmit, well before the PTO.
        _ = a.ingest(payload: acks[0], now: at(2_000))
        let (retx, _) = a.poll(now: at(2_000))
        XCTAssertEqual(retx.count, 1)
        XCTAssertEqual(
            try ArqFrame.decodeAll(retx[0]), [segments[0]]
        )

        // Its arrival releases all five messages in order.
        let events = b.ingest(payload: retx[0], now: at(3_000))
        XCTAssertEqual(
            events.compactMap { event -> [UInt8]? in
                if case .message(_, let bytes) = event { return bytes }
                return nil
            },
            (0..<5).map { [0x25, UInt8($0)] }
        )
    }

    func testReplayedAckNeverRetriggersFastRetransmit() throws {
        var a = Endpoint(channel: .ctrl)
        var b = Endpoint(channel: .ctrl)
        for i in 0..<5 {
            try a.send(message: [0x26, UInt8(i)], now: at(0))
        }
        let (datagrams, _) = a.poll(now: at(0))
        let segments = try datagrams.flatMap { try ArqFrame.decodeAll($0) }
        for frame in segments.dropFirst() {
            _ = b.ingest(payload: frame.encode(), now: at(1_000))
        }
        let (acks, _) = b.poll(now: at(1_000))

        _ = a.ingest(payload: acks[0], now: at(2_000))
        let (retx, _) = a.poll(now: at(2_000))
        XCTAssertEqual(retx.count, 1)

        // The same ACK replayed a hundred times buys the attacker
        // nothing: no new high mark, no retransmit.
        for _ in 0..<100 {
            _ = a.ingest(payload: acks[0], now: at(3_000))
        }
        let (nothing, _) = a.poll(now: at(3_000))
        XCTAssertEqual(nothing, [])
    }

    // MARK: Windows and wrap

    func testSendWindowHoldsFreshSegments() throws {
        let config = ArqConfig(sendWindowSegments: 4)
        var a = Endpoint(channel: .ctrl, config: config)
        var b = Endpoint(channel: .ctrl, config: config)
        for i in 0..<10 {
            try a.send(message: [0x27, UInt8(i)], now: at(0))
        }
        let (burst1, _) = a.poll(now: at(0))
        let sent1 = try burst1.flatMap { try ArqFrame.decodeAll($0) }
        XCTAssertEqual(sent1.count, 4)

        for frame in sent1 {
            _ = b.ingest(payload: frame.encode(), now: at(1_000))
        }
        _ = shuttle(from: &b, to: &a, now: at(2_000))
        let (burst2, _) = a.poll(now: at(2_000))
        let sent2 = try burst2.flatMap { try ArqFrame.decodeAll($0) }
        XCTAssertEqual(sent2.count, 4)
    }

    func testSeqWrapCrossing() throws {
        let config = ArqConfig(initialSegmentSeq: 0xFFFE)
        var a = Endpoint(channel: .ctrl, config: config)
        var b = Endpoint(channel: .ctrl, config: config)
        let messages: [[UInt8]] = (0..<4).map { [0x28, UInt8($0)] }
        for message in messages {
            try a.send(message: message, now: at(0)) // seqs FFFE FFFF 0 1
        }
        let (datagrams, _) = a.poll(now: at(0))
        let segments = try datagrams.flatMap { try ArqFrame.decodeAll($0) }
        var events: [ArqEvent] = []
        for frame in segments.reversed() {
            events += b.ingest(payload: frame.encode(), now: at(1_000))
        }
        XCTAssertEqual(
            events.compactMap { event -> [UInt8]? in
                if case .message(_, let bytes) = event { return bytes }
                return nil
            },
            messages
        )
        // And the wrap-spanning ACK retires everything.
        _ = shuttle(from: &b, to: &a, now: at(2_000))
        XCTAssertTrue(a.isQuiescent)
    }

    // MARK: Hostile shapes (unit-sized; the storm versions live in
    // ArqAdversarialTests)

    func testAckOfUnsentDataIgnored() throws {
        var a = Endpoint(channel: .ctrl)
        try a.send(message: [0x29, 0], now: at(0))
        _ = a.poll(now: at(0))
        let forged = try ArqAck(blocks: [
            ArqAck.Block(
                channel: .ctrl, group: .orderedStream,
                cumulative: ArqSegmentSeq(rawValue: 100)
            )
        ])
        let events = a.ingest(payload: forged.encode(), now: at(1_000))
        XCTAssertEqual(
            events, [.ignored(.ackForUnsentData(.orderedStream))]
        )
        XCTAssertFalse(a.isQuiescent) // the real segment is still owed
    }

    func testForeignChannelAckIgnored() throws {
        var a = Endpoint(channel: .ctrl)
        try a.send(message: [0x2A, 0], now: at(0))
        _ = a.poll(now: at(0))
        let foreign = try ArqAck(blocks: [
            ArqAck.Block(
                channel: .videoIdle, group: .orderedStream,
                cumulative: ArqSegmentSeq(rawValue: 0)
            )
        ])
        let events = a.ingest(payload: foreign.encode(), now: at(1_000))
        XCTAssertEqual(events, [.ignored(.foreignChannelAck(.videoIdle))])
    }

    func testMalformedPayloadReported() {
        var a = Endpoint(channel: .ctrl)
        let events = a.ingest(payload: [0x7F, 1, 2], now: at(0))
        XCTAssertEqual(events, [.ignored(.malformedPayload(
            .unknownFrameType(0x7F)
        ))])
    }
}
