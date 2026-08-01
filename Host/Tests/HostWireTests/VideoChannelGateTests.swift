import XCTest
import Foundation
import HostCore
import HostWire
import LyteWire
import LyteWireTestKit

// THE GATE (build plan HS-5 row): corpus frames → VideoChannel (simulated
// clock, pacer draining at exact nextWake instants) → emitted datagram
// blobs → envelope decode → seeded loss of ≤ m shards per group →
// LyteWire.VideoAssembler → DecodeUnits byte-exact against the input
// corpus. Along the way: every datagram within the 1152 B budget, the
// envelope timestamp carries the supplied capture µs verbatim, and the
// pacer telemetry shows exactly the class traffic this slice rules
// (everything freshVideo, keyframes urgent-fresh, nothing else).

final class VideoChannelGateTests: XCTestCase {

    // Host/Tests/HostWireTests/… → repo root → the frozen W2 corpus.
    private static var corpusDirectory: String {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false)
        components.removeLast(4)
        return components.joined(separator: "/")
            + "/Wire/Vectors/video-corpus-v1"
    }

    private func corpusFiles() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: Self.corpusDirectory)
            .filter { $0.hasSuffix(".annexb") }
            .sorted()
    }

    private func load(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: URL(
            fileURLWithPath: Self.corpusDirectory + "/" + name
        )))
    }

    private static let rateBPS = 20_000_000
    private static let frameIntervalNS: UInt64 = 16_666_667
    /// Distinct from the pacer clock on purpose: carriage of the capture
    /// stamp must be verbatim, not re-derived from anything.
    private static func captureMicros(_ frameIndex: Int) -> UInt64 {
        5_000_000 + UInt64(frameIndex) * 16_667
    }

    private struct Emitted {
        let datagram: VideoChannelDatagram
        let at: UInt64
    }

    /// Runs the whole corpus through a VideoChannel on a simulated clock,
    /// pumping at exact `nextWake` instants — the sans-IO event loop the
    /// Linux send path runs, minus the syscalls.
    private func driveCorpus(
        frames: [[UInt8]]
    ) throws -> (channel: VideoChannel, emitted: [Emitted]) {
        final class Clock { var now: UInt64 = 0 }
        let clock = Clock()
        var emitted: [Emitted] = []
        let channel = VideoChannel(
            config: VideoChannelConfig(rateBitsPerSecond: Self.rateBPS),
            now: 0
        ) { datagram in
            emitted.append(Emitted(datagram: datagram, at: clock.now))
        }

        for (i, frame) in frames.enumerated() {
            clock.now = max(clock.now, UInt64(i) * Self.frameIntervalNS)
            // The budgets ruling in action: at 20 Mbps every corpus frame
            // drains inside one 60 fps frame interval, so the queue is
            // empty when the next encode lands.
            XCTAssertTrue(channel.isIdle,
                          "frame \(i): previous frame still draining")
            try channel.ingest(
                frame: frame,
                frameNumber: FrameNumber(rawValue: UInt32(i)),
                captureTimestampMicroseconds: Self.captureMicros(i),
                isKeyframe: AnnexBCheck.containsIrap(frame),
                now: clock.now
            )
            let horizon = UInt64(i + 1) * Self.frameIntervalNS
            channel.pump(now: clock.now)
            while let wake = channel.nextWake(now: clock.now), wake < horizon {
                clock.now = max(clock.now &+ 1, wake)
                channel.pump(now: clock.now)
            }
        }
        while let wake = channel.nextWake(now: clock.now) {
            clock.now = max(clock.now &+ 1, wake)
            channel.pump(now: clock.now)
        }
        XCTAssertTrue(channel.isIdle)
        return (channel, emitted)
    }

    func testGateCorpusThroughChannelLossAndAssemblerByteExact() throws {
        let files = try corpusFiles()
        XCTAssertEqual(files.count, 13, "the corpus is a frozen artifact")
        let frames = try files.map(load)

        let (channel, emitted) = try driveCorpus(frames: frames)

        // Every emitted blob within budget, correct class tag.
        for e in emitted {
            XCTAssertLessThanOrEqual(
                e.datagram.bytes.count, WireBudget.maxDatagramByteCount,
                "datagram over the 1152 B budget"
            )
            XCTAssertEqual(e.datagram.pacerClass, .freshVideo)
        }

        // Envelope decode: channel, per-frame shard census, and the
        // capture timestamp carried verbatim in every shard.
        var perFrame: [UInt32: [(envelope: Envelope, payload: [UInt8])]] = [:]
        for e in emitted {
            let (envelope, payload) = try Envelope.decode(e.datagram.bytes)
            XCTAssertEqual(envelope.channel, .videoActive)
            XCTAssertEqual(
                envelope.timestamp,
                Self.captureMicros(Int(envelope.frame.rawValue)),
                "timestamp field must carry the supplied capture µs"
            )
            XCTAssertEqual(envelope.seq, e.datagram.seq)
            XCTAssertEqual(envelope.frame, e.datagram.frameNumber)
            perFrame[envelope.frame.rawValue, default: []]
                .append((envelope, Array(payload)))
        }
        XCTAssertEqual(perFrame.keys.count, frames.count)
        var expectedTotal = 0
        for (i, frame) in frames.enumerated() {
            let geometry = try FecGeometryTable.geometry(
                forGroupByteCount: frame.count, regime: .clean
            )
            expectedTotal += geometry.totalShards
            XCTAssertEqual(
                perFrame[UInt32(i)]?.count, geometry.totalShards,
                "frame \(i): expected k+m = \(geometry.totalShards) shards"
            )
        }
        XCTAssertEqual(emitted.count, expectedTotal)

        // Seeded loss at the parity limit: drop exactly m shards per
        // group, chosen at random, then reassemble from what survives in
        // emission order.
        var rng = SplitMix64(seed: 0x5)
        var dropped: Set<ChannelSeq> = []
        var droppedCount = 0
        for (i, frame) in frames.enumerated() {
            let geometry = try FecGeometryTable.geometry(
                forGroupByteCount: frame.count, regime: .clean
            )
            var seqs = perFrame[UInt32(i)]!.map(\.envelope.seq)
            seqs.shuffle(using: &rng)
            for seq in seqs.prefix(geometry.parityShards) {
                dropped.insert(seq)
                droppedCount += 1
            }
        }

        var assembler = VideoAssembler()
        var units: [DecodeUnit] = []
        var rxNow = ClientTimestamp(microseconds: 0)
        for e in emitted {
            guard !dropped.contains(e.datagram.seq) else { continue }
            rxNow = rxNow.advanced(byMicroseconds: 25)
            let (envelope, payload) = try Envelope.decode(e.datagram.bytes)
            for event in assembler.ingest(
                envelope: envelope, payload: payload, now: rxNow
            ) {
                if case .decoded(let unit) = event { units.append(unit) }
            }
        }
        for event in assembler.evictStale(
            now: rxNow.advanced(byMicroseconds: 2_000_000)
        ) {
            if case .decoded(let unit) = event { units.append(unit) }
        }

        XCTAssertEqual(units.count, frames.count)
        XCTAssertEqual(
            units.map(\.frameNumber.rawValue),
            Array(0..<UInt32(frames.count))
        )
        XCTAssertEqual(
            units.map(\.annexB), frames,
            "assembled frames are not byte-exact against the corpus"
        )
        XCTAssertTrue(units[0].isIDR)
        XCTAssertTrue(units.dropFirst().allSatisfy { !$0.isIDR })
        for unit in units {
            XCTAssertEqual(
                unit.timestamp.microseconds,
                Self.captureMicros(Int(unit.frameNumber.rawValue)),
                "capture µs must survive the whole pipeline"
            )
        }

        // Pacer telemetry: exactly the ruled class traffic, batch bound
        // honored, everything that entered left.
        let telemetry = channel.pacerTelemetry
        XCTAssertEqual(telemetry[.freshVideo].tokensSent, expectedTotal)
        XCTAssertEqual(telemetry[.freshVideo].tokensEnqueued, expectedTotal)
        for cls in PacerClass.allCases where cls != .freshVideo {
            XCTAssertEqual(telemetry[cls].tokensEnqueued, 0,
                           "\(cls.name): unexpected traffic")
        }
        XCTAssertLessThanOrEqual(
            telemetry.maxBatchWireTimeNS, 1_000_000,
            "a batch exceeded the 1 ms quantum"
        )
        XCTAssertEqual(telemetry.bytesSent, channel.counters.bytesSent)
        XCTAssertEqual(channel.counters.framesIngested, frames.count)
        XCTAssertEqual(channel.counters.keyframesIngested, 1)
        XCTAssertEqual(channel.counters.datagramsSent, expectedTotal)

        let lossPercent = 100.0 * Double(droppedCount) / Double(expectedTotal)
        print("HS-5 gate: \(frames.count) corpus frames → \(expectedTotal) "
            + "datagrams (\(channel.counters.bytesSent) B), dropped "
            + "\(droppedCount) (\(String(format: "%.1f", lossPercent))% — "
            + "parity limit per group), \(units.count) frames reassembled "
            + "byte-exact; max batch wire time "
            + "\(telemetry.maxBatchWireTimeNS) ns")
    }

    func testSealedDatagramsAssembleInPlaceByteEquivalent() throws {
        let frame = try load("frame-001-p.annexb")
        var emitted: [VideoChannelDatagram] = []
        var expected: [[UInt8]] = []
        let channel = VideoChannel(
            config: VideoChannelConfig(
                rateBitsPerSecond: Self.rateBPS,
                connectionId: try ConnectionId(
                    bytes: [1, 2, 3, 4, 5, 6, 7, 8]
                )
            ),
            now: 0,
            seal: { plaintext, aad, envelope in
                XCTAssertEqual(Array(aad), try envelope.encode(payload: []),
                    "the authenticated header changed")
                let sealed = plaintext.map { $0 ^ 0xA5 }
                    + [UInt8](repeating: 0x5A,
                              count: WireBudget.aeadTagByteCount)
                expected.append(try envelope.encode(payload: sealed))
                return sealed
            }
        ) { emitted.append($0) }

        let count = try channel.ingest(
            frame: frame, frameNumber: FrameNumber(rawValue: 77),
            captureTimestampMicroseconds: 123_456,
            isKeyframe: false, lastInputSeq: 42, now: 0
        )
        var now: UInt64 = 0
        channel.pump(now: now)
        while let wake = channel.nextWake(now: now) {
            now = max(now &+ 1, wake)
            channel.pump(now: now)
        }
        XCTAssertEqual(emitted.map(\.bytes), expected,
            "pre-sized AAD-buffer assembly must be byte-identical to "
                + "the canonical envelope encoder")
        XCTAssertEqual(channel.counters.sealedDatagramsAssembledInPlace,
                       count,
            "every sealed shard must use the two-buffer assembly path")
    }

    func testSinglePassClassificationPreservesLegacyResults() throws {
        let corpus = try corpusFiles().map(load)
        let malformedAndIrap: [[UInt8]] = [
            [],
            [0, 0, 1],
            [0, 0, 0, 1, 0x40, 0x01], // VPS only: no VCL
            [0xAA, 0, 0, 1, 0x26, 0x01], // prefixed IRAP: not frame-shaped
            [0, 0, 1, 0x26, 0x01], // IDR_W_RADL
            [0, 0, 0, 1, 0x2A, 0x01], // CRA_NUT
        ]
        for (index, bytes) in (corpus + malformedAndIrap).enumerated() {
            let classification = AnnexBCheck.classifyFrame(bytes)
            XCTAssertEqual(
                classification.isFrameShaped,
                AnnexBCheck.isFrameShaped(bytes),
                "shape changed for classification case \(index)"
            )
            XCTAssertEqual(
                classification.containsIrap,
                AnnexBCheck.containsIrap(bytes),
                "IRAP result changed for classification case \(index)"
            )
        }

        let prefixedIrap = malformedAndIrap[3]
        let prefixed = AnnexBCheck.classifyFrame(prefixedIrap)
        XCTAssertFalse(prefixed.isFrameShaped)
        XCTAssertTrue(
            prefixed.containsIrap,
            "malformed-prefix IRAP classification is intentionally independent"
        )
        XCTAssertEqual(
            AnnexBCheck.classifyFrame(malformedAndIrap[4]),
            AnnexBFrameClassification(
                isFrameShaped: true, containsIrap: true
            )
        )
    }

    func testKeyframeShardsJumpTheVideoQueue() throws {
        // A queued P-frame, then an IDR before anything drains: the IDR's
        // shards are urgent-fresh and must leave first — the Pacer's
        // within-class jump, never crossing classes (HS-6 semantics).
        let pFrame = try load("frame-100-p-small.annexb")
        let idr = try load("frame-000-idr.annexb")

        var order: [VideoChannelDatagram] = []
        let channel = VideoChannel(
            config: VideoChannelConfig(rateBitsPerSecond: Self.rateBPS),
            now: 0
        ) { order.append($0) }

        try channel.ingest(
            frame: pFrame, frameNumber: FrameNumber(rawValue: 0),
            captureTimestampMicroseconds: 1, isKeyframe: false, now: 0
        )
        let idrShards = try channel.ingest(
            frame: idr, frameNumber: FrameNumber(rawValue: 1),
            captureTimestampMicroseconds: 2, isKeyframe: true, now: 0
        )

        var now: UInt64 = 0
        channel.pump(now: now)
        while let wake = channel.nextWake(now: now) {
            now = max(now &+ 1, wake)
            channel.pump(now: now)
        }

        XCTAssertTrue(order.prefix(idrShards).allSatisfy(\.isKeyframe),
                      "IDR shards must drain before the queued P-frame")
        XCTAssertTrue(order.dropFirst(idrShards).allSatisfy { !$0.isKeyframe })
    }

    /// HS-28: the queued-shard books behind the NACK recusal — a frame
    /// reads as "still draining" exactly while any of its video-class
    /// shards wait in the pacer (repairs re-open it), and drops off
    /// the moment its last shard leaves. This is what lets the
    /// estimator recuse NACKs that measure our own drain speed.
    func testQueuedShardBooksTrackTheDrain() throws {
        let frame = try load("frame-000-idr.annexb")
        let channel = VideoChannel(
            config: VideoChannelConfig(rateBitsPerSecond: Self.rateBPS),
            now: 0
        ) { _ in }

        XCTAssertTrue(channel.framesWithQueuedShards().isEmpty)
        try channel.ingest(
            frame: frame, frameNumber: FrameNumber(rawValue: 7),
            captureTimestampMicroseconds: 1, isKeyframe: true, now: 0
        )
        XCTAssertEqual(channel.framesWithQueuedShards(), [7],
            "a NACK against this frame right now would measure our "
            + "pacer, not the path — it must read as draining")

        var now: UInt64 = 0
        channel.pump(now: now)
        while let wake = channel.nextWake(now: now) {
            now = max(now &+ 1, wake)
            channel.pump(now: now)
        }
        XCTAssertTrue(channel.framesWithQueuedShards().isEmpty,
            "fully drained — NACKs against it are path evidence again")

        // A repair retransmit re-opens the books until it leaves too.
        try channel.enqueueRepair(
            frame: FrameNumber(rawValue: 7), shardIndices: [0], now: now
        )
        XCTAssertEqual(channel.framesWithQueuedShards(), [7])
        channel.pump(now: now)
        while let wake = channel.nextWake(now: now) {
            now = max(now &+ 1, wake)
            channel.pump(now: now)
        }
        XCTAssertTrue(channel.framesWithQueuedShards().isEmpty)
    }

    func testLyingKeyframeFlagIsLoud() throws {
        // The packetizer's isIDR cross-check surfaces through the wiring
        // unmuted — a lying encoder flag is a bug, not a datagram.
        let pFrame = try load("frame-100-p-small.annexb")
        let channel = VideoChannel(
            config: VideoChannelConfig(rateBitsPerSecond: Self.rateBPS),
            now: 0
        ) { _ in XCTFail("nothing may be enqueued from a rejected frame") }
        XCTAssertThrowsError(try channel.ingest(
            frame: pFrame, frameNumber: FrameNumber(rawValue: 0),
            captureTimestampMicroseconds: 1, isKeyframe: true, now: 0
        ))
        XCTAssertTrue(channel.isIdle)
        XCTAssertEqual(channel.counters.framesIngested, 0)
    }
}
