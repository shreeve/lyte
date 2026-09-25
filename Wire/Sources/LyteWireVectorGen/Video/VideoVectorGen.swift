// Authors Vectors/video-v1.json: the packetized golden corpus and its
// assembly scenarios. Inline synthetic frames pin small geometries by
// full datagram hex; corpus frames pin real HEVC by sha256. Anchored by
// the hand-walked packetize case in VideoPacketizerTests.

import Foundation
import LyteCore
import LyteWire
import LyteWireTestKit

/// A synthetic Annex-B frame: 4-byte start code, HEVC NAL header for
/// `nalType`, then counting-byte filler (which never contains 00 00 —
/// no accidental start codes).
func syntheticFrame(nalType: UInt8, totalByteCount: Int) -> [UInt8] {
    precondition(totalByteCount >= 8)
    var out: [UInt8] = [0, 0, 0, 1, nalType << 1, 0x01]
    out += counting(from: 2, count: totalByteCount - out.count)
    return out
}

private struct FrameSpec {
    let name: String
    let description: String
    let bytes: [UInt8]
    let source: VideoFrameSource
    let frameNumber: UInt32
    let timestamp: UInt64
    let isIDR: Bool
    let regime: FecRegime
    let firstSeq: UInt16
    let includeHex: Bool
}

public func makeVideoVectorFile(corpusDirectory: String) throws -> VideoVectorFile {
    var specs: [FrameSpec] = []

    // Inline synthetic frames — every geometry bucket edge the vectors
    // can afford to carry as full hex.
    let idr = HevcNalType.idrWRadl, p = HevcNalType.trailR
    let inlines: [(String, String, UInt8, Int, UInt32, UInt64, FecRegime, UInt16)] = [
        ("inline-tiny-idr",
         "48 B synthetic IDR: k=1 m=1 clean, the smallest group shape",
         idr, 48, 0, 0x0001_0000, .clean, 0),
        ("inline-p-k3",
         "2500 B synthetic P: k=3 m=2 clean, balanced split with a short trailing shard",
         p, 2500, 1, 0x0001_4144, .clean, 2),
        ("inline-p-k3-lossy",
         "the same 2500 B P under the lossy regime: k=3 m=2 (percentCeil 50)",
         p, 2500, 2, 0x0001_8288, .lossy, 7),
        ("inline-p-tail",
         "2500 B P continuing the inline channel (seqs 12–16): the follow-on traffic that renders loss verdicts",
         p, 2500, 3, 0x0001_C3CC, .clean, 12),
        ("inline-p-seq-wrap",
         "1500 B P allocated across the u16 seq wrap: k=2 m=1, seqs 0xFFFF 0x0000 0x0001",
         p, 1500, 4, 0x0002_0510, .clean, 0xFFFF),
    ]
    for (name, description, nalType, size, frameNumber, timestamp, regime, firstSeq) in inlines {
        let bytes = syntheticFrame(nalType: nalType, totalByteCount: size)
        specs.append(FrameSpec(
            name: name, description: description,
            bytes: bytes, source: .inline(bytes),
            frameNumber: frameNumber, timestamp: timestamp,
            isIDR: nalType == idr, regime: regime, firstSeq: firstSeq,
            includeHex: true
        ))
    }

    // Corpus frames — real HEVC (see the corpus README for provenance),
    // hash-pinned.
    let corpusPicks: [(file: String, name: String, description: String, isIDR: Bool, regime: FecRegime, frameNumber: UInt32, firstSeq: UInt16)] = [
        // firstSeqs are contiguous across the four frames (20 + 22 + 6
        // shards), the same allocation one packetizer would produce.
        ("frame-000-idr.annexb", "corpus-idr",
         "the IDR access unit carrying VPS/SPS/PPS", true, .clean, 100, 1000),
        ("frame-001-p.annexb", "corpus-p-large",
         "the largest P-frame in the corpus prefix", false, .clean, 101, 1020),
        ("frame-100-p-small.annexb", "corpus-p-small",
         "a small steady-state P-frame", false, .clean, 102, 1042),
        ("frame-100-p-small.annexb", "corpus-p-small-lossy",
         "the small P-frame under the lossy regime", false, .lossy, 103, 1048),
    ]
    for pick in corpusPicks {
        let data = try Data(contentsOf: URL(
            fileURLWithPath: corpusDirectory + "/" + pick.file
        ))
        let bytes = [UInt8](data)
        specs.append(FrameSpec(
            name: pick.name, description: pick.description,
            bytes: bytes, source: .corpus(file: pick.file, bytes: bytes),
            frameNumber: pick.frameNumber,
            timestamp: 0x1_0000_0000 + UInt64(pick.frameNumber) * 16_667,
            isIDR: pick.isIDR, regime: pick.regime,
            firstSeq: pick.firstSeq, includeHex: false
        ))
    }

    var frames: [VideoFrameVector] = []
    var geometries: [String: FecGeometry] = [:]
    for spec in specs {
        var packetizer = VideoPacketizer(
            firstSeq: ChannelSeq(rawValue: spec.firstSeq)
        )
        let shards = try packetizer.packetize(
            frame: spec.bytes,
            frameNumber: FrameNumber(rawValue: spec.frameNumber),
            captureTimestamp: HostTimestamp(microseconds: spec.timestamp),
            isIDR: spec.isIDR,
            regime: spec.regime
        )
        let geometry = try FecGeometryTable.geometry(
            forGroupByteCount: spec.bytes.count, regime: spec.regime
        )
        geometries[spec.name] = geometry
        frames.append(VideoFrameVector(
            name: spec.name,
            description: spec.description,
            source: spec.source,
            frameNumber: FrameNumber(rawValue: spec.frameNumber),
            timestamp: HostTimestamp(microseconds: spec.timestamp),
            isIDR: spec.isIDR,
            regime: spec.regime,
            firstSeq: ChannelSeq(rawValue: spec.firstSeq),
            geometry: geometry,
            shards: try shards.map { shard in
                VideoShardVector(
                    seq: shard.envelope.seq,
                    fecHex: Hex.uint64String(shard.envelope.fec),
                    datagram: try shard.encodeDatagram(),
                    includeHex: spec.includeHex
                )
            }
        ))
    }

    func steps(_ frame: String, _ indices: some Sequence<Int>) -> [VideoDeliveryStep] {
        indices.map { VideoDeliveryStep(frame: frame, shardIndex: $0) }
    }
    func allShards(_ name: String) -> [VideoDeliveryStep] {
        steps(name, 0..<geometries[name]!.totalShards)
    }
    let corpusIdr = geometries["corpus-idr"]!
    let corpusP = geometries["corpus-p-large"]!
    var rng = SplitMix64(seed: 0x57_1D_00_02)

    let scenarios = [
        VideoScenario(
            name: "in-order-tiny-idr",
            description: "single k=1 m=1 frame, in order, no loss",
            steps: allShards("inline-tiny-idr"),
            expectDecoded: ["inline-tiny-idr"]
        ),
        VideoScenario(
            name: "shuffled-k3",
            description: "k=3 m=2 frame with every shard reordered",
            steps: steps("inline-p-k3", [4, 1, 3, 0, 2]),
            expectDecoded: ["inline-p-k3"]
        ),
        VideoScenario(
            name: "loss-at-parity-limit-k3",
            description: "k=3 m=2 with both data shards 0 and 2 lost — exactly m erasures, recovered",
            steps: steps("inline-p-k3", [1, 3, 4]),
            expectDecoded: ["inline-p-k3"]
        ),
        VideoScenario(
            name: "duplicates-k3",
            description: "duplicate datagrams are dropped, single decode",
            steps: steps("inline-p-k3", [0, 0, 1, 1, 2, 2, 0]),
            expectDecoded: ["inline-p-k3"]
        ),
        VideoScenario(
            name: "seq-wrap-loss",
            description: "shard at seq 0x0000 (index 1) lost across the u16 wrap, parity recovers",
            steps: steps("inline-p-seq-wrap", [0, 2]),
            expectDecoded: ["inline-p-seq-wrap"]
        ),
        VideoScenario(
            name: "interleaved-frames-emit-in-order",
            description: "frame 1 opens, frame 2 fully arrives (held for order), frame 1 completes late — decode order is frame order, and the stragglers must NOT have drawn a fec-impossible verdict (NACK candidates yes, write-off no)",
            steps: steps("inline-p-k3", [0]) + allShards("inline-p-k3-lossy")
                + steps("inline-p-k3", [1, 2]),
            expectDecoded: ["inline-p-k3", "inline-p-k3-lossy"]
        ),
        VideoScenario(
            name: "fec-impossible-then-eviction",
            description: "frame 1 keeps only one parity shard; two full frames of follow-on traffic push every missing seq past the write-off distance — fec-impossible reported, stale tick evicts, later frames emit",
            steps: steps("inline-p-k3", [3]) + allShards("inline-p-k3-lossy")
                + allShards("inline-p-tail"),
            finalTickMicroseconds: 300_000,
            expectDecoded: ["inline-p-k3-lossy", "inline-p-tail"],
            expectFecImpossible: ["inline-p-k3"]
        ),
        VideoScenario(
            name: "corpus-idr-in-order",
            description: "the real IDR access unit, in order, no loss",
            steps: allShards("corpus-idr"),
            expectDecoded: ["corpus-idr"]
        ),
        VideoScenario(
            name: "corpus-sequence-with-loss",
            description: "IDR then large P, each losing its full parity budget in data shards, reordered within the G4 displacement model (≤3) so the loss presumption stays quiet",
            steps: Reorder.bounded(
                steps("corpus-idr", corpusIdr.parityShards..<corpusIdr.totalShards)
                    + steps("corpus-p-large", corpusP.parityShards..<corpusP.totalShards),
                maxDisplacement: 3, using: &rng
            ),
            expectDecoded: ["corpus-idr", "corpus-p-large"]
        ),
        VideoScenario(
            name: "corpus-small-p-lossy-regime",
            description: "small P under lossy regime survives losing both of its first two shards",
            steps: steps(
                "corpus-p-small-lossy",
                2..<geometries["corpus-p-small-lossy"]!.totalShards
            ),
            expectDecoded: ["corpus-p-small-lossy"]
        ),
    ]

    return VideoVectorFile(frames: frames, scenarios: scenarios)
}
