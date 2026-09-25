import XCTest
import LyteClientCore
import LyteClientTestKit
import LyteTransport
import LyteWire
import LyteWireTestKit

// Serial-arithmetic demux properties under seeded shuffles, including the
// 0xFFFF → 0x0000 wrap: every failure reproduces from its SplitMix64 seed.
// The tracker's own properties are LyteClientCore's (SeqGapTrackerTests).

final class SeqDemuxPropertyTests: XCTestCase {

    // MARK: Through ReceiveDemux with encoded datagrams

    /// The tracker's properties hold end-to-end through envelope encode → ingest,
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
            XCTAssertEqual(stats.seq.wrapEvents, 1, "chan \(channel)")
        }
        XCTAssertEqual(demux.snapshotTotals().accepted, 256)
    }
}
