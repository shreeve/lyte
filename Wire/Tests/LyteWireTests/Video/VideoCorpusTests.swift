import XCTest
import Foundation
import LyteCore
import LyteWire
import LyteWireTestKit

// The real-HEVC half of gate W-G3: the committed corpus round-trips
// through packetizer → seeded damage → assembler byte-exact, per frame
// and as the reassembled decodable prefix (frames 000–009 are contiguous
// in the source capture; their concatenation is the stream ffmpeg
// decodes clean on the host — see the corpus README for the evidence line).

final class VideoCorpusTests: XCTestCase {

    private static let corpusDirectory =
        WireTestPaths.packageRoot + "/Vectors/video-corpus-v1"

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

    func testCorpusFilesAreFrameShapedAccessUnits() throws {
        let files = try corpusFiles()
        XCTAssertEqual(files.count, 13, "the corpus is a frozen artifact")
        for name in files {
            let bytes = try load(name)
            XCTAssertTrue(AnnexBCheck.isFrameShaped(bytes), name)
            XCTAssertEqual(
                AnnexBStream.accessUnitRanges(in: bytes).count, 1,
                "\(name): exactly one access unit per corpus file"
            )
            let isIdrFile = name.contains("idr")
            XCTAssertEqual(AnnexBCheck.containsIrap(bytes), isIdrFile, name)
        }
        // The IDR access unit carries the parameter sets, in order.
        let idr = try load("frame-000-idr.annexb")
        XCTAssertEqual(
            AnnexBCheck.nalUnits(in: idr).map(\.type).prefix(3), [32, 33, 34],
            "IDR frame must open VPS SPS PPS"
        )
    }

    func testEveryCorpusFrameRoundTripsUnderDamage() throws {
        var rng = SplitMix64(seed: 0x57_1D_C0_09)
        for (index, name) in try corpusFiles().enumerated() {
            let frame = try load(name)
            for regime in FecRegime.allCases {
                var packetizer = VideoPacketizer(
                    firstSeq: ChannelSeq(rawValue: UInt16(index * 64))
                )
                var shards = try packetizer.packetize(
                    frame: frame,
                    frameNumber: FrameNumber(rawValue: UInt32(index)),
                    captureTimestamp: HostTimestamp(microseconds: UInt64(index)),
                    isIDR: AnnexBCheck.containsIrap(frame),
                    regime: regime
                )
                let geometry = try FecGeometryTable.geometry(
                    forGroupByteCount: frame.count, regime: regime
                )
                shards.shuffle(using: &rng)
                shards.removeLast(geometry.parityShards) // loss at the limit
                var assembler = VideoAssembler()
                var units: [DecodeUnit] = []
                for shard in shards {
                    let datagram = try shard.encodeDatagram()
                    let (envelope, payload) = try Envelope.decode(datagram)
                    for event in assembler.ingest(
                        envelope: envelope, payload: payload,
                        now: ClientTimestamp(microseconds: 0)
                    ) {
                        if case .decoded(let unit) = event { units.append(unit) }
                    }
                }
                XCTAssertEqual(units.map(\.annexB), [frame], "\(name) \(regime)")
            }
        }
    }

    func testDecodablePrefixReassemblesAsOneStream() throws {
        // Frames 000–009 in order through one channel, shards shuffled
        // within a two-frame window, per-frame loss at the parity limit —
        // the reassembled concatenation must equal the source
        // concatenation byte-exact (what ffmpeg then decodes on the host).
        let files = try corpusFiles().filter { !$0.contains("small") }
        XCTAssertEqual(files.count, 10)
        let frames = try files.map(load)

        var rng = SplitMix64(seed: 0x57_1D_C0_0A)
        var packetizer = VideoPacketizer(firstSeq: ChannelSeq(rawValue: 0xFFF0))
        var assembler = VideoAssembler(config: VideoAssemblerConfig(
            holdbackFrameCount: 4,
            staleAfterMicroseconds: 1_000_000,
            maxTrackedGroups: 8,
            reorderThresholdPackets: 3
        ))
        var units: [DecodeUnit] = []
        var window: [VideoShard] = []
        var now = ClientTimestamp(microseconds: 0)

        func flush(_ shards: [VideoShard]) throws {
            for shard in shards {
                now = now.advanced(byMicroseconds: 25)
                let datagram = try shard.encodeDatagram()
                let (envelope, payload) = try Envelope.decode(datagram)
                for event in assembler.ingest(
                    envelope: envelope, payload: payload, now: now
                ) {
                    if case .decoded(let unit) = event { units.append(unit) }
                }
            }
        }

        for (index, frame) in frames.enumerated() {
            let regime: FecRegime = index % 2 == 0 ? .clean : .lossy
            var shards = try packetizer.packetize(
                frame: frame,
                frameNumber: FrameNumber(rawValue: UInt32(index)),
                captureTimestamp: HostTimestamp(microseconds: UInt64(index) * 16_667),
                isIDR: index == 0,
                regime: regime
            )
            let geometry = try FecGeometryTable.geometry(
                forGroupByteCount: frame.count, regime: regime
            )
            shards.shuffle(using: &rng)
            shards.removeLast(geometry.parityShards)
            window += shards
            if index % 2 == 1 {
                window.shuffle(using: &rng) // interleave the frame pair
                try flush(window)
                window = []
            }
        }
        try flush(window)
        for event in assembler.evictStale(
            now: now.advanced(byMicroseconds: 2_000_000)
        ) {
            if case .decoded(let unit) = event { units.append(unit) }
        }

        XCTAssertEqual(units.count, frames.count)
        XCTAssertEqual(
            units.map(\.frameNumber.rawValue), Array(0..<UInt32(10))
        )
        let reassembled = units.flatMap(\.annexB)
        XCTAssertEqual(reassembled, frames.flatMap { $0 }, "stream not byte-exact")
        XCTAssertTrue(units[0].isIDR)
        XCTAssertTrue(units.dropFirst().allSatisfy { !$0.isIDR })
    }
}
