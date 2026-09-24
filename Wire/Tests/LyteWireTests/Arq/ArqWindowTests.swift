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
            XCTAssertEqual(
                block.bitmapSeqs.map(\.rawValue),
                (1...buffered).map { UInt16($0) }
            )
        }
    }

    // MARK: Wrap

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
}
