// The W-G3 decode-evidence harness (`video-roundtrip`): packetize every
// access unit of an Annex-B file, subject each frame's shards to seeded
// shuffle plus loss at the parity limit, assemble, assert byte-exact
// recovery, and write the reassembled stream — which an external
// `ffmpeg -f null -` then decodes as the real-corpus half of the oracle.

import Foundation
import LyteCore
import LyteWire
import LyteWireTestKit

func runVideoRoundTrip(inputPath: String, outputPath: String) throws {
    let input = [UInt8](try Data(contentsOf: URL(fileURLWithPath: inputPath)))
    let ranges = AnnexBStream.accessUnitRanges(in: input)
    guard !ranges.isEmpty else { die("\(inputPath): no access units found") }

    var rng = SplitMix64(seed: 0x57_1D_0F_F0)
    var packetizer = VideoPacketizer(firstSeq: ChannelSeq(rawValue: 0xFF00))
    var assembler = VideoAssembler(config: VideoAssemblerConfig(
        holdbackFrameCount: 4,
        staleAfterMicroseconds: 1_000_000,
        maxTrackedGroups: 16,
        reorderThresholdPackets: 3
    ))

    var decoded: [DecodeUnit] = []
    var shardCount = 0
    var lostCount = 0
    var now = ClientTimestamp(microseconds: 0)

    for (index, range) in ranges.enumerated() {
        let frameBytes = input[range]
        let isIDR = AnnexBCheck.containsIrap(frameBytes)
        let regime: FecRegime = index % 2 == 0 ? .clean : .lossy
        var shards = try packetizer.packetize(
            frame: frameBytes,
            frameNumber: FrameNumber(rawValue: UInt32(index)),
            captureTimestamp: HostTimestamp(microseconds: UInt64(index) * 16_667),
            isIDR: isIDR,
            regime: regime
        )
        shardCount += shards.count

        // Loss at the parity limit: every m-th frame loses exactly its
        // parity budget in random positions; others lose a random count
        // up to m.
        let geometry = try FecGeometryTable.geometry(
            forGroupByteCount: frameBytes.count, regime: regime
        )
        let lossBudget = index % 3 == 0
            ? geometry.parityShards
            : Int.random(in: 0...geometry.parityShards, using: &rng)
        shards.shuffle(using: &rng)
        shards.removeLast(lossBudget)
        lostCount += lossBudget

        for shard in shards {
            now = now.advanced(byMicroseconds: 50)
            // Through the envelope codec both ways — the full wire path.
            let datagram = try shard.encodeDatagram()
            let (envelope, payload) = try Envelope.decode(datagram)
            for event in assembler.ingest(
                envelope: envelope, payload: payload, now: now
            ) {
                switch event {
                case .decoded(let unit): decoded.append(unit)
                case .framesSkipped(let from, let through, let reason):
                    die("frames \(from.rawValue)–\(through.rawValue) skipped: \(reason)")
                case .evicted(let frame, let reason):
                    die("frame \(frame.rawValue) evicted: \(reason)")
                case .shardDropped(.duplicateShard), .shardDropped(.staleFrame):
                    // Redundant parity landing after its frame already
                    // decoded/emitted — benign by design.
                    break
                case .shardDropped(let reason):
                    die("shard dropped: \(reason)")
                case .fecImpossible, .nackCandidates:
                    break // presumption noise while a group is in flight
                case .repairShardAccepted(let frame, let index):
                    die("repair accepted for \(frame.rawValue)/\(index) on a clean round trip")
                }
            }
        }
    }
    // Flush the holdback tail.
    now = now.advanced(byMicroseconds: 2_000_000)
    for event in assembler.evictStale(now: now) {
        if case .decoded(let unit) = event { decoded.append(unit) }
    }

    guard decoded.count == ranges.count else {
        die("decoded \(decoded.count) of \(ranges.count) frames")
    }
    var reassembled: [UInt8] = []
    reassembled.reserveCapacity(input.count)
    for (index, unit) in decoded.enumerated() {
        guard unit.frameNumber.rawValue == UInt32(index) else {
            die("frame order broken at \(index): got \(unit.frameNumber.rawValue)")
        }
        guard unit.annexB[...] == input[ranges[index]] else {
            die("frame \(index) is not byte-identical after round trip")
        }
        reassembled += unit.annexB
    }
    guard reassembled == input else { die("reassembled stream differs") }

    try Data(reassembled).write(to: URL(fileURLWithPath: outputPath))
    print("""
    round trip OK: \(ranges.count) frames, \(shardCount) shards, \
    \(lostCount) lost (\(String(format: "%.1f", 100.0 * Double(lostCount) / Double(shardCount)))%), \
    byte-exact; sha256 \(Hex.string(Sha256.digest(reassembled)))
    wrote \(reassembled.count) bytes to \(outputPath)
    """)
}
