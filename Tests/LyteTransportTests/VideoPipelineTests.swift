import XCTest
import CoreMedia
import Foundation
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE CL-2 GATE (corpus leg): the golden W2 corpus, packetized by the
// real VideoPacketizer, survives shuffle and parity-bounded loss through
// the full render pipeline — headless: LyteVideoPipeline emits
// CMSampleBuffers with no window or display layer anywhere. Asserts the
// DecodeUnit sequence, byte-exact Annex-B out vs corpus in, sample-buffer
// creation (format-description bootstrap from the corpus IDR's in-band
// VPS/SPS/PPS), FEC recovery at 5% seeded drop, and the fecImpossible
// seam CL-3's IDR request will hook.

final class VideoPipelineTests: XCTestCase {

    private static var corpusDirectory: String {
        var components = #filePath.split(separator: "/", omittingEmptySubsequences: false)
        components.removeLast(3)
        return components.joined(separator: "/") + "/Wire/Vectors/video-corpus-v1"
    }

    /// The decodable 10-frame prefix, in order (IDR first).
    private func loadPrefix() throws -> [[UInt8]] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: Self.corpusDirectory)
            .filter { $0.hasPrefix("frame-0") && $0.hasSuffix(".annexb") }
            .sorted()
        XCTAssertEqual(names.count, 10, "the corpus prefix is ten access units")
        return try names.map {
            [UInt8](try Data(contentsOf: URL(
                fileURLWithPath: Self.corpusDirectory + "/" + $0)))
        }
    }

    private func packetizePrefix(
        _ frames: [[UInt8]]
    ) throws -> [[VideoShard]] {
        var packetizer = VideoPacketizer()
        return try frames.enumerated().map { index, annexB in
            try packetizer.packetize(
                frame: annexB,
                frameNumber: FrameNumber(rawValue: UInt32(index)),
                captureTimestamp: HostTimestamp(microseconds: UInt64(index) * 16_667),
                isIDR: AnnexBCheck.containsIrap(annexB),
                regime: .clean)
        }
    }

    /// A pipeline collecting everything it emits; headless by
    /// construction — no display layer exists in this test target.
    /// @unchecked Sendable: tests drive the pipeline single-threaded.
    private final class Collector: @unchecked Sendable {
        var samples: [(CMSampleBuffer, DecodeUnit)] = []
        var fecImpossibleFrames: [FrameNumber] = []
        private(set) var pipeline: LyteVideoPipeline!

        init() {
            pipeline = LyteVideoPipeline(
                onSample: { [weak self] sample, unit in
                    self?.samples.append((sample, unit))
                },
                onFecImpossible: { [weak self] frame, _, _ in
                    self?.fecImpossibleFrames.append(frame)
                })
        }
    }

    // MARK: - The corpus renders, byte-exact, headless

    func testCorpusShuffledParityBoundedLossRendersByteExact() throws {
        let frames = try loadPrefix()
        let shardGroups = try packetizePrefix(frames)

        // Per frame: drop exactly the parity count (the recovery limit),
        // then reorder the survivors with displacement ≤ 4 — the G4
        // reorder model the assembler's holdback policy is calibrated
        // for (an unbounded shuffle would rightly trigger holdback
        // skips: bounded latency beats completeness).
        var rng = SplitMix64(seed: 0xC12)
        var surviving: [VideoShard] = []
        for group in shardGroups {
            guard case .reedSolomon(_, let geometry) =
                try FecField.decode(group[0].envelope.fec) else {
                return XCTFail("packetizer emitted a non-RS fec field")
            }
            let dropped = Set(
                (0..<group.count).shuffled(using: &rng).prefix(geometry.parityShards))
            surviving.append(contentsOf: group.enumerated()
                .filter { !dropped.contains($0.offset) }
                .map(\.element))
        }
        surviving = Reorder.bounded(surviving, maxDisplacement: 4, using: &rng)

        let collector = Collector()
        let now = ClientTimestamp(microseconds: 1_000)
        for shard in surviving {
            collector.pipeline.ingest(
                envelope: shard.envelope, payload: shard.payload, now: now)
        }

        let stats = collector.pipeline.snapshotStats()
        XCTAssertEqual(stats.framesDecoded, 10, "every frame recovers at the parity limit")
        XCTAssertEqual(stats.framesSkipped, 0)
        XCTAssertEqual(stats.samplesDelivered, 10, "IDR-first: every DecodeUnit renders")
        XCTAssertEqual(stats.sampleFailures, 0)
        XCTAssertEqual(stats.sampleBuildMicroseconds.count, 10)
        XCTAssertNotNil(stats.sampleBuildMicroseconds.p99)
        XCTAssertEqual(collector.samples.count, 10)

        // DecodeUnit sequence: frame order, byte-identical to the corpus.
        for (index, (_, unit)) in collector.samples.enumerated() {
            XCTAssertEqual(unit.frameNumber.rawValue, UInt32(index))
            XCTAssertEqual(unit.annexB, frames[index],
                           "frame \(index) must be byte-exact vs the corpus")
            XCTAssertEqual(unit.isIDR, index == 0)
        }
    }

    // MARK: - 5% drop recovers via FEC (the CL-2 gate's loss clause)

    func testFivePercentSeededDropRecoversEverything() throws {
        let frames = try loadPrefix()
        let shardGroups = try packetizePrefix(frames)

        var rng = SplitMix64(seed: 5)
        var delivered = 0, dropped = 0
        let collector = Collector()
        let now = ClientTimestamp(microseconds: 1_000)
        for shard in shardGroups.flatMap({ $0 }) {
            if Double.random(in: 0..<1, using: &rng) < 0.05 {
                dropped += 1
                continue
            }
            delivered += 1
            collector.pipeline.ingest(
                envelope: shard.envelope, payload: shard.payload, now: now)
        }
        XCTAssertGreaterThan(dropped, 0, "the seed must actually exercise loss")

        let stats = collector.pipeline.snapshotStats()
        XCTAssertEqual(stats.framesDecoded, 10,
                       "5% drop (seed 5: \(dropped)/\(dropped + delivered) shards) must recover via FEC")
        XCTAssertEqual(stats.framesSkipped, 0)
        XCTAssertEqual(stats.samplesDelivered, 10)
        for (index, (_, unit)) in collector.samples.enumerated() {
            XCTAssertEqual(unit.annexB, frames[index])
        }
        XCTAssertTrue(collector.fecImpossibleFrames.isEmpty,
                      "recoverable loss must not cry impossible")
    }

    // MARK: - fecImpossible fires the CL-3 seam

    func testFecImpossibleFiresSeamAndPipelineMovesOn() throws {
        let frames = try loadPrefix()
        let shardGroups = try packetizePrefix(Array(frames.prefix(3)))

        let collector = Collector()
        var now = ClientTimestamp(microseconds: 1_000)

        // Frame 0 arrives whole; frame 1 loses all but one shard (far
        // beyond parity); frames 2's arrivals push every missing frame-1
        // seq past the fec-impossible distance threshold.
        for shard in shardGroups[0] {
            collector.pipeline.ingest(envelope: shard.envelope, payload: shard.payload, now: now)
        }
        let lonely = shardGroups[1][0]
        collector.pipeline.ingest(envelope: lonely.envelope, payload: lonely.payload, now: now)
        for shard in shardGroups[2] {
            collector.pipeline.ingest(envelope: shard.envelope, payload: shard.payload, now: now)
        }

        XCTAssertEqual(collector.fecImpossibleFrames, [FrameNumber(rawValue: 1)],
                       "the seam callback names the unrecoverable frame exactly once")
        XCTAssertEqual(collector.pipeline.snapshotStats().fecImpossibleCount, 1)

        // The stale window expires: frame 1 is skipped, frame 2 renders —
        // the pipeline moves on without CL-3's feedback loop existing yet.
        now = now.advanced(byMicroseconds: 300_000)
        collector.pipeline.tick(now: now)

        let stats = collector.pipeline.snapshotStats()
        XCTAssertEqual(stats.framesDecoded, 2)
        XCTAssertEqual(stats.framesSkipped, 1)
        XCTAssertEqual(collector.samples.map { $0.1.frameNumber.rawValue }, [0, 2])
        XCTAssertEqual(collector.samples[1].1.annexB, frames[2])
    }

    // MARK: - Format-description bootstrap from the corpus IDR

    func testFormatDescriptionBootstrapsFromCorpusIdr() throws {
        let frames = try loadPrefix()

        // A P-frame ahead of any IDR is withheld: no format description
        // exists yet, and present-ASAP never shows garbage.
        let factory = VideoRenderFactory()
        XCTAssertFalse(factory.hasFormatDescription)
        let pFirst = try factory.makeSampleBuffer(from: DecodeUnit(
            frameNumber: FrameNumber(rawValue: 0),
            timestamp: HostTimestamp(microseconds: 0),
            isIDR: false,
            annexB: frames[1]))
        XCTAssertNil(pFirst, "P-frame before the first IDR must be withheld")

        // The corpus IDR carries in-band VPS/SPS/PPS: one unit bootstraps
        // the description and yields a renderable sample.
        let idrSample = try factory.makeSampleBuffer(from: DecodeUnit(
            frameNumber: FrameNumber(rawValue: 1),
            timestamp: HostTimestamp(microseconds: 16_667),
            isIDR: true,
            annexB: frames[0]))
        XCTAssertTrue(factory.hasFormatDescription)
        let sample = try XCTUnwrap(idrSample)

        let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_HEVC)
        // The capture ran at the client's default 2048×1280 stream size
        // (the README's "1080p" is shorthand for the H0a capture class).
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        XCTAssertEqual(dimensions.width, 2048)
        XCTAssertEqual(dimensions.height, 1280)

        // Present-ASAP: the DisplayImmediately attachment rides every sample.
        let attachments = try XCTUnwrap(
            CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]])
        XCTAssertEqual(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool,
                       true)

        // And the P-frame renders now that the description exists.
        let pSecond = try factory.makeSampleBuffer(from: DecodeUnit(
            frameNumber: FrameNumber(rawValue: 2),
            timestamp: HostTimestamp(microseconds: 33_334),
            isIDR: false,
            annexB: frames[1]))
        XCTAssertNotNil(pSecond)
    }

    /// Pipeline-level bootstrap: P-frames delivered before the IDR count
    /// as withheld, never as failures — CL-2 renders from the first IDR.
    func testPipelineWithholdsPreIdrFrames() throws {
        let frames = try loadPrefix()
        var packetizer = VideoPacketizer()
        // Stream starts mid-GOP: a P access unit as frame 0, the IDR as 1.
        let pShards = try packetizer.packetize(
            frame: frames[1], frameNumber: FrameNumber(rawValue: 0),
            captureTimestamp: HostTimestamp(microseconds: 0),
            isIDR: false, regime: .clean)
        let idrShards = try packetizer.packetize(
            frame: frames[0], frameNumber: FrameNumber(rawValue: 1),
            captureTimestamp: HostTimestamp(microseconds: 16_667),
            isIDR: true, regime: .clean)

        let collector = Collector()
        let now = ClientTimestamp(microseconds: 1_000)
        for shard in pShards + idrShards {
            collector.pipeline.ingest(envelope: shard.envelope, payload: shard.payload, now: now)
        }

        let stats = collector.pipeline.snapshotStats()
        XCTAssertEqual(stats.framesDecoded, 2)
        XCTAssertEqual(stats.samplesWithheld, 1, "the pre-IDR P-frame is withheld")
        XCTAssertEqual(stats.samplesDelivered, 1)
        XCTAssertEqual(stats.sampleFailures, 0)
        XCTAssertEqual(collector.samples.map { $0.1.frameNumber.rawValue }, [1])
        XCTAssertNotNil(stats.firstSampleMicroseconds)
    }

    // MARK: - The HS-22 quality window (the overlay/wire-view line)

    /// The receive-side quality snapshot derives entirely from decoded
    /// frames: cadence and bitrate over the frames' actual span,
    /// percentiles over their byte sizes — and the window forgets
    /// everything older than ~5 s (an idle stream reads as no
    /// evidence, not stale evidence).
    func testQualityWindowDerivesCadenceBitrateAndPercentiles() throws {
        let frames = try loadPrefix()
        let shardGroups = try packetizePrefix(frames)

        let collector = Collector()
        // One frame every 20 ms: ten frames spanning 180 µs×… (9 gaps
        // × 20 ms = 180 ms), well inside the window.
        for (index, group) in shardGroups.enumerated() {
            let at = ClientTimestamp(
                microseconds: 1_000 + UInt64(index) * 20_000)
            for shard in group {
                collector.pipeline.ingest(
                    envelope: shard.envelope, payload: shard.payload,
                    now: at)
            }
        }
        let lastAt = ClientTimestamp(microseconds: 1_000 + 9 * 20_000)
        let quality = try XCTUnwrap(
            collector.pipeline.snapshotStats(now: lastAt).quality)

        // Span floors at 1 s, so ten frames read as 10 fps and the
        // bitrate is the exact byte sum × 8 over that second.
        let totalBytes = frames.reduce(0) { $0 + $1.count }
        XCTAssertEqual(quality.framesPerSecond, 10, accuracy: 0.01)
        XCTAssertEqual(quality.bitsPerSecond, totalBytes * 8)

        // Percentiles over the corpus frame sizes themselves.
        let sorted = frames.map(\.count).sorted()
        XCTAssertEqual(quality.frameBytesP50, sorted[4])
        XCTAssertEqual(quality.frameBytesP95, sorted[9])
        XCTAssertEqual(quality.frameBytesMax, sorted[9])

        // Six seconds of silence later the window is empty — quality
        // reads nil, never a stale five-second-old story.
        let idleAt = lastAt.advanced(byMicroseconds: 6_000_000)
        XCTAssertNil(collector.pipeline.snapshotStats(now: idleAt).quality)
    }

    // MARK: - Annex-B → length-prefix conversion (the copy-adapted core)

    func testLengthPrefixedConversionRoundTripsNalPayloads() throws {
        let frames = try loadPrefix()
        let annexB = frames[0]
        let hvcc = VideoRenderFactory.lengthPrefixed(annexB: annexB)
        XCTAssertFalse(hvcc.isEmpty)

        // Walk the length-prefixed output and compare each NAL payload
        // (sans padding) against the AnnexBCheck walk of the input.
        var nals: [[UInt8]] = []
        var i = 0
        while i + 4 <= hvcc.count {
            var length = 0
            for byte in hvcc[i..<(i + 4)] {
                length = length << 8 | Int(byte)
            }
            nals.append(Array(hvcc[(i + 4)..<(i + 4 + length)]))
            i += 4 + length
        }
        XCTAssertEqual(i, hvcc.count, "no trailing bytes after the last NAL")

        let expected = AnnexBCheck.nalUnits(in: annexB).map { unit -> [UInt8] in
            var bytes = Array(annexB[unit.offset..<unit.offset + unit.length])
            while bytes.last == 0 { bytes.removeLast() }
            return bytes
        }
        XCTAssertEqual(nals, expected)
        XCTAssertEqual(nals.count, 5, "corpus IDR: VPS SPS PPS PREFIX_SEI IDR_W_RADL")
    }

    func testSamplePayloadIsByteExactWithOneOwnedCopy() throws {
        let frame = try loadPrefix()[0]
        let expected = VideoRenderFactory.lengthPrefixed(annexB: frame)
        let factory = VideoRenderFactory()
        let sample = try XCTUnwrap(factory.makeSampleBuffer(from: DecodeUnit(
            frameNumber: FrameNumber(rawValue: 0),
            timestamp: HostTimestamp(microseconds: 123_456),
            isIDR: true,
            annexB: frame)))

        XCTAssertEqual(try samplePayloadBytes(sample), expected,
            "CoreMedia storage must preserve every length prefix and NAL byte")
        XCTAssertEqual(factory.lastCopyMetrics, VideoRenderCopyMetrics(
            destinationBytes: expected.count,
            intermediateBytes: 0,
            payloadCopyPasses: 1),
            "conversion writes once into owned sample storage")
    }

    func testSampleStorageOutlivesFactoryAndAnnexBSource() throws {
        let frame = try loadPrefix()[0]
        let expected = VideoRenderFactory.lengthPrefixed(annexB: frame)
        let sample: CMSampleBuffer = try autoreleasepool {
            var source = frame
            let factory = VideoRenderFactory()
            let made = try XCTUnwrap(factory.makeSampleBuffer(from: DecodeUnit(
                frameNumber: FrameNumber(rawValue: 0),
                timestamp: HostTimestamp(microseconds: 1),
                isIDR: true,
                annexB: source)))
            // Attempt to reuse the caller's source storage before both
            // source and factory leave scope.
            _ = source.withUnsafeMutableBytes { bytes in
                bytes.initializeMemory(as: UInt8.self, repeating: 0xDD)
            }
            return made
        }

        // Churn similarly-sized allocations after every Swift owner of
        // the Annex-B input has gone away. The sample must remain exact.
        for _ in 0..<64 {
            _ = [UInt8](repeating: 0xEE, count: frame.count)
        }
        XCTAssertEqual(try samplePayloadBytes(sample), expected)
    }

    private func samplePayloadBytes(
        _ sample: CMSampleBuffer
    ) throws -> [UInt8] {
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        let count = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { destination in
            CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: count,
                destination: destination.baseAddress!)
        }
        XCTAssertEqual(status, noErr)
        return bytes
    }
}
