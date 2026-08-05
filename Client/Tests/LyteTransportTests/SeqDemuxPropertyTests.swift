import XCTest
import LyteClientTestKit
import LyteTransport
import LyteWire
import LyteWireTestKit

// Serial-arithmetic demux properties under seeded shuffles, including the
// 0xFFFF → 0x0000 wrap: every failure reproduces from its SplitMix64 seed.

final class SeqDemuxPropertyTests: XCTestCase {

    // MARK: SeqGapTracker directly

    func testInOrderAcrossWrap() {
        var tracker = SeqGapTracker()
        var seq = ChannelSeq(rawValue: 0xFFF0)
        for _ in 0..<32 {
            tracker.record(seq)
            seq = seq.next
        }
        XCTAssertEqual(tracker.received, 32)
        XCTAssertEqual(tracker.datagramsMissing, 0)
        XCTAssertEqual(tracker.duplicates, 0)
        XCTAssertEqual(tracker.wrapEvents, 1)
        XCTAssertEqual(tracker.highest?.rawValue, 0x000F)
    }

    /// Shuffled delivery with bounded displacement: once everything arrives,
    /// every detected gap must have been late-filled — zero missing, zero
    /// duplicates, and the wrap still counted exactly once.
    func testBoundedShuffleAcrossWrapLeavesNothingMissing() {
        for seed: UInt64 in [1, 42, 0xDEAD_BEEF, 20260720] {
            var rng = SplitMix64(seed: seed)
            let count = 2000
            let start = ChannelSeq(rawValue: 0xFF00)   // crosses the wrap
            var seqs = (0..<count).map { start.advanced(by: Int16($0)) }

            // Chunked shuffle: displacement bounded by 2×chunk ≪ the
            // tracker's window, the realistic reorder shape.
            let chunk = 32
            for lower in stride(from: 0, to: count, by: chunk) {
                let upper = min(lower + chunk, count)
                seqs[lower..<upper].shuffle(using: &rng)
            }

            var tracker = SeqGapTracker()
            for seq in seqs {
                tracker.record(seq)
            }
            XCTAssertEqual(tracker.received, UInt64(count), "seed \(seed)")
            XCTAssertEqual(tracker.datagramsMissing, 0, "seed \(seed)")
            XCTAssertEqual(tracker.duplicates, 0, "seed \(seed)")
            XCTAssertEqual(tracker.wrapEvents, 1, "seed \(seed)")
            XCTAssertEqual(tracker.gapsDetected, tracker.lateFilled, "seed \(seed)")
        }
    }

    /// Seeded drops on top of the shuffle: missing must equal exactly the
    /// number of dropped datagrams.
    func testShuffledDeliveryWithDropsCountsExactLoss() {
        for seed: UInt64 in [7, 99, 0xC0FFEE] {
            var rng = SplitMix64(seed: seed)
            let count = 1500
            let start = ChannelSeq(rawValue: 0xFFA0)
            let all = (0..<count).map { start.advanced(by: Int16($0)) }

            // Drop ~5%, but never the first or last: edge drops are gaps no
            // receiver can see (nothing ever brackets them).
            var delivered = all.enumerated().filter { index, _ in
                index == 0 || index == count - 1 || rng.next() % 100 >= 5
            }.map(\.element)
            let dropped = count - delivered.count

            let chunk = 24
            for lower in stride(from: 0, to: delivered.count, by: chunk) {
                let upper = min(lower + chunk, delivered.count)
                delivered[lower..<upper].shuffle(using: &rng)
            }

            var tracker = SeqGapTracker()
            for seq in delivered {
                tracker.record(seq)
            }
            XCTAssertEqual(tracker.received, UInt64(delivered.count), "seed \(seed)")
            XCTAssertEqual(tracker.datagramsMissing, UInt64(dropped), "seed \(seed)")
            XCTAssertEqual(tracker.duplicates, 0, "seed \(seed)")
        }
    }

    func testDuplicatesAndLateFillsClassified() {
        var tracker = SeqGapTracker()
        let s0 = ChannelSeq(rawValue: 10)
        tracker.record(s0)                      // first
        tracker.record(s0.advanced(by: 3))      // gap: 11, 12 skipped
        XCTAssertEqual(tracker.datagramsMissing, 2)

        XCTAssertEqual(tracker.record(ChannelSeq(rawValue: 11)), .lateFill)
        XCTAssertEqual(tracker.datagramsMissing, 1)
        XCTAssertEqual(tracker.record(ChannelSeq(rawValue: 11)), .duplicate)
        XCTAssertEqual(tracker.record(ChannelSeq(rawValue: 13)), .duplicate)
        XCTAssertEqual(tracker.record(ChannelSeq(rawValue: 12)), .lateFill)
        XCTAssertEqual(tracker.datagramsMissing, 0)
        XCTAssertEqual(tracker.duplicates, 2)
    }

    /// The unordered 0x8000-apart case must classify beyond-window, never trap.
    func testHalfSpaceDistanceIsBeyondWindow() {
        var tracker = SeqGapTracker()
        tracker.record(ChannelSeq(rawValue: 0x0000))
        XCTAssertEqual(tracker.record(ChannelSeq(rawValue: 0x8000)), .beyondWindow)
        XCTAssertEqual(tracker.beyondWindow, 1)
    }

    // MARK: Through ReceiveDemux with encoded datagrams

    /// The same property holds end-to-end through envelope encode → ingest,
    /// with the per-channel isolation the demux owes us: interleaved
    /// channels never see each other's seqs.
    func testDemuxIsolatesChannelsUnderShuffle() throws {
        var rng = SplitMix64(seed: 0x51CE_C1E1)
        let demux = ReceiveDemux(crypto: PassthroughTransportCrypto())

        var datagrams: [[UInt8]] = []
        for channel in [ChannelId.videoActive, ChannelId.audio] {
            let start = ChannelSeq(rawValue: 0xFFE0)   // both cross the wrap
            for i in 0..<128 {
                let envelope = Envelope(
                    channel: channel,
                    seq: start.advanced(by: Int16(i)),
                    frame: FrameNumber(rawValue: UInt32(i / 4)),
                    timestamp: UInt64(i) * 16_667,
                    fec: 0
                )
                datagrams.append(try envelope.encode(payload: rng.bytes(64)))
            }
        }
        let chunk = 16
        for lower in stride(from: 0, to: datagrams.count, by: chunk) {
            let upper = min(lower + chunk, datagrams.count)
            datagrams[lower..<upper].shuffle(using: &rng)
        }

        for (i, datagram) in datagrams.enumerated() {
            demux.ingest(datagram: datagram[...], arrivalMicroseconds: UInt64(i))
        }

        for channel in [ChannelId.videoActive.rawValue, ChannelId.audio.rawValue] {
            guard let stats = demux.stats(forChannel: channel) else {
                return XCTFail("chan \(channel): no stats")
            }
            XCTAssertEqual(stats.datagrams, 128, "chan \(channel)")
            XCTAssertEqual(stats.payloadBytes, 128 * 64, "chan \(channel)")
            XCTAssertEqual(stats.seqMissing, 0, "chan \(channel)")
            XCTAssertEqual(stats.seqDuplicates, 0, "chan \(channel)")
            XCTAssertEqual(stats.seqWrapEvents, 1, "chan \(channel)")
            XCTAssertEqual(stats.maxFrame, 31, "chan \(channel)")
        }
        XCTAssertEqual(demux.snapshotTotals().accepted, 256)
    }
}
