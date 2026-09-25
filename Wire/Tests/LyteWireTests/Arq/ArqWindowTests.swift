import XCTest
import LyteWire
import LyteWireTestKit

// ArqEndpoint window, ACK-shape, and bounded-memory behaviors: the
// properties that only show up past one bitmap byte, past one receive
// window, or past one tombstone FIFO. Each test drives the endpoints by
// hand at the frame level so a regression names the mechanism.

final class ArqWindowTests: XCTestCase {

    typealias Endpoint = ArqEndpoint<HostClock>

    private func at(_ microseconds: UInt64) -> HostTimestamp {
        HostTimestamp(microseconds: microseconds)
    }

    private func frames(_ datagrams: [[UInt8]]) throws -> [ArqFrame] {
        try datagrams.flatMap { try ArqFrame.decodeAll($0) }
    }

    private func messages(_ events: [ArqEvent]) -> [[UInt8]] {
        events.compactMap { event -> [UInt8]? in
            if case .message(_, let bytes) = event { return bytes }
            return nil
        }
    }

    private func message(_ index: Int) -> [UInt8] {
        [0x40, UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: index)]
    }

    // MARK: ACK shape

    /// The ACK bitmap must reach the serially highest buffered segment,
    /// whatever order the receiver's state yields them in — a short
    /// bitmap un-SACKs segments and under-reports the fast-retransmit
    /// high mark.
    func testAckBitmapReachesTheHighestBufferedSegment() throws {
        for buffered in [9, 40, 130, 255] {
            let config = ArqConfig(sendWindowSegments: 256)
            var a = Endpoint(channel: .ctrl, config: config)
            var b = Endpoint(channel: .ctrl, config: config)
            for index in 0...buffered {
                try a.send(message: message(index), now: at(0))
            }
            let sent = try frames(a.poll(now: at(0)).datagrams)
            XCTAssertEqual(sent.count, buffered + 1)
            // Lose seq 0; everything else buffers behind the hole.
            for frame in sent.dropFirst() {
                XCTAssertEqual(
                    b.ingest(payload: frame.encode(), now: at(1_000)), []
                )
            }
            let acks = try frames(b.poll(now: at(1_000)).datagrams)
            guard acks.count == 1, case .ack(let ack) = acks[0] else {
                return XCTFail("one ACK frame expected, got \(acks)")
            }
            let block = try XCTUnwrap(ack.blocks.first)
            XCTAssertEqual(block.cumulative.rawValue, 0xFFFF)
            XCTAssertEqual(
                block.highestReported.rawValue, UInt16(buffered),
                "\(buffered) buffered segments"
            )
            // Seqs 1…buffered sit at offsets 1…buffered past 0xFFFF.
            var expected = [UInt8](repeating: 0, count: buffered / 8 + 1)
            for offset in 1...buffered {
                expected[offset / 8] |= 1 << (offset % 8)
            }
            XCTAssertEqual(block.receivedBitmap, expected)
        }
    }

    // MARK: Send span

    /// An honest sender never puts a segment past the receiver's window,
    /// even while the window head is lost and SACKs retire everything
    /// behind it — the window bounds the span above the lowest
    /// unacknowledged seq, not only the in-flight count.
    func testSenderNeverOverrunsTheReceiveWindowWhileTheHeadIsLost() throws {
        var a = Endpoint(channel: .ctrl)
        var b = Endpoint(channel: .ctrl)
        let count = 600
        for index in 0..<count {
            try a.send(message: message(index), now: at(0))
        }
        var delivered: [[UInt8]] = []
        var overruns = 0
        var now: UInt64 = 0
        for _ in 0..<2_000 {
            for frame in try frames(a.poll(now: at(now)).datagrams) {
                if case .segment(let segment) = frame,
                   segment.seq.rawValue == 0, now < 400_000 {
                    continue // the head keeps getting lost
                }
                for event in b.ingest(payload: frame.encode(), now: at(now)) {
                    if case .ignored(.beyondReceiveWindow) = event {
                        overruns += 1
                    }
                    if case .message(_, let bytes) = event {
                        delivered.append(bytes)
                    }
                }
            }
            for datagram in b.poll(now: at(now)).datagrams {
                _ = a.ingest(payload: datagram, now: at(now))
            }
            if a.isQuiescent && b.isQuiescent { break }
            now += 5_000
        }
        XCTAssertEqual(overruns, 0, "segments sent past the receive window")
        XCTAssertEqual(delivered, (0..<count).map(message))
        XCTAssertTrue(a.isQuiescent)
    }

    // MARK: Queue bound

    /// A queue deeper than the u16 serial space can describe must push
    /// back at `send`, never wedge: past half the space every honest ACK
    /// would read as forged and the channel would stall for good.
    func testDeepQueuePushesBackInsteadOfWedging() throws {
        var a = Endpoint(channel: .bulkTransfer)
        var b = Endpoint(channel: .bulkTransfer)
        var accepted = 0
        var refusal: ArqSendError?
        while accepted < 40_000 {
            do {
                try a.send(message: message(accepted), now: at(0))
                accepted += 1
            } catch let error as ArqSendError {
                refusal = error
                break
            }
        }
        XCTAssertEqual(refusal, .queueFull)
        XCTAssertLessThan(accepted, 32_768)
        XCTAssertGreaterThan(accepted, 16_384)

        var delivered = 0
        var inOrder = true
        var now: UInt64 = 0
        for _ in 0..<2_000 where !(a.isQuiescent && b.isQuiescent) {
            for datagram in a.poll(now: at(now)).datagrams {
                for bytes in messages(b.ingest(payload: datagram, now: at(now))) {
                    inOrder = inOrder && bytes == message(delivered)
                    delivered += 1
                }
            }
            for datagram in b.poll(now: at(now)).datagrams {
                _ = a.ingest(payload: datagram, now: at(now))
            }
            now += 1_000
        }
        XCTAssertEqual(delivered, accepted)
        XCTAssertTrue(inOrder)
        XCTAssertTrue(a.isQuiescent)
        // Drained, the queue accepts again.
        XCTAssertNoThrow(try a.send(message: [0x40], now: at(now)))
    }

    /// Hundreds of queued segments crossing the u16 wrap under loss
    /// still deliver exactly once, in order.
    func testLossyDrainAcrossTheSeqWrap() throws {
        let config = ArqConfig(initialSegmentSeq: 0xFF00)
        var a = Endpoint(channel: .ctrl, config: config)
        var b = Endpoint(channel: .ctrl, config: config)
        var rng = SplitMix64(seed: 0xA11CE)
        let count = 1_000
        for index in 0..<count {
            try a.send(message: message(index), now: at(0))
        }
        var delivered: [[UInt8]] = []
        var now: UInt64 = 0
        for _ in 0..<10_000 where !(a.isQuiescent && b.isQuiescent) {
            for frame in try frames(a.poll(now: at(now)).datagrams)
            where rng.next() % 5 != 0 {
                delivered += messages(b.ingest(payload: frame.encode(), now: at(now)))
            }
            for datagram in b.poll(now: at(now)).datagrams
            where rng.next() % 5 != 0 {
                _ = a.ingest(payload: datagram, now: at(now))
            }
            now += 20_000
        }
        XCTAssertEqual(delivered, (0..<count).map(message))
        XCTAssertTrue(a.isQuiescent)
    }

    /// Draining a queue costs O(window) per operation: a 4× deeper
    /// queue takes about 4× as long, never the 16× a per-poll walk of the
    /// whole queue costs. (Scaling, not wall time, is the assertion.)
    func testQueueDrainScalesLinearly() throws {
        func drain(_ count: Int) throws -> Duration {
            var best = Duration.seconds(1_000)
            for _ in 0..<3 {
                var a = Endpoint(channel: .ctrl)
                var b = Endpoint(channel: .ctrl)
                let body = [UInt8](repeating: 0x41, count: 1_000)
                for _ in 0..<count { try a.send(message: body, now: at(0)) }
                var now: UInt64 = 0
                let elapsed = ContinuousClock().measure {
                    while !(a.isQuiescent && b.isQuiescent) {
                        for datagram in a.poll(now: at(now)).datagrams {
                            _ = b.ingest(payload: datagram, now: at(now))
                        }
                        for datagram in b.poll(now: at(now)).datagrams {
                            _ = a.ingest(payload: datagram, now: at(now))
                        }
                        now += 100
                    }
                }
                best = min(best, elapsed)
            }
            return best
        }
        let small = try drain(2_000)
        let large = try drain(8_000)
        XCTAssertLessThan(large / small, 8.0, "\(small) → \(large)")
    }

    // MARK: One-shot tombstones

    /// A late retransmit of a one-shot group whose tombstone was evicted
    /// is still closed: it re-ACKs and never delivers a second time.
    func testEvictedOneShotNeverDeliversTwice() throws {
        var a = Endpoint(channel: .videoIdle)
        var b = Endpoint(channel: .videoIdle)
        let tombstones = b.config.maxClosedGroupTombstones
        var firstSegment: [UInt8] = []
        for id in 1...(tombstones + 2) {
            let group = ArqGroupId(rawValue: UInt16(id))
            try a.sendOneShot(message: [0x30, UInt8(id & 0xFF)], group: group, now: at(0))
            let datagrams = a.poll(now: at(0)).datagrams
            if id == 1 { firstSegment = datagrams[0] }
            for datagram in datagrams {
                XCTAssertEqual(
                    messages(b.ingest(payload: datagram, now: at(0))).count, 1
                )
            }
        }
        _ = b.poll(now: at(0))

        let late = b.ingest(payload: firstSegment, now: at(1_000))
        XCTAssertEqual(messages(late), [], "group 1 delivered twice")
        XCTAssertEqual(late, [.ignored(.segmentOnClosedGroup(
            ArqGroupId(rawValue: 1), ArqSegmentSeq(rawValue: 0)
        ))])
        // The re-ACK still completes a sender that missed every ACK.
        let reAck = b.poll(now: at(1_000)).datagrams
        XCTAssertEqual(reAck.count, 1)
        var stale = Endpoint(channel: .videoIdle)
        try stale.sendOneShot(
            message: [0x30, 1], group: ArqGroupId(rawValue: 1), now: at(0)
        )
        _ = stale.poll(now: at(0))
        XCTAssertEqual(
            stale.ingest(payload: reAck[0], now: at(2_000)),
            [.oneShotAcknowledged(ArqGroupId(rawValue: 1))]
        )
    }
}
