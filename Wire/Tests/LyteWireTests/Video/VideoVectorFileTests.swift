import XCTest
import LyteCore
import LyteWire
import LyteWireTestKit

// Verifies the committed Vectors/video-v1.json and the corpus it pins —
// the packetized golden corpus of gate W-G3. The datagram hashes being
// identical on macOS and Linux is what makes the packetizer's output
// (envelope bytes, balanced split, nanors parity) a cross-platform wire
// contract that client CL-2 can code against before the host exists.

final class VideoVectorFileTests: XCTestCase {

    private static let corpusDirectory = WireVectors.path("video-corpus-v1")

    private func loadFile() throws -> VideoVectorFile {
        try VideoVectorFile.loadCommitted()
    }

    func testFrameVectorsPacketizeByteExact() throws {
        for vector in try loadFile().frames {
            let bytes = try vector.source.loadBytes(
                corpusDirectory: Self.corpusDirectory
            )
            let regime = try XCTUnwrap(FecRegime(rawValue: vector.regime))
            var packetizer = VideoPacketizer(
                firstSeq: ChannelSeq(rawValue: vector.firstSeq)
            )
            let shards = try packetizer.packetize(
                frame: bytes,
                frameNumber: FrameNumber(rawValue: vector.frameNumber),
                captureTimestamp: HostTimestamp(
                    microseconds: try XCTUnwrap(Hex.uint64(vector.timestampHex))
                ),
                isIDR: vector.isIDR,
                regime: regime
            )
            XCTAssertEqual(shards.count, vector.shards.count, vector.name)

            let geometry = try FecGeometry(
                dataShards: vector.dataShards,
                parityShards: vector.parityShards,
                groupByteCount: vector.groupByteCount
            )
            XCTAssertEqual(geometry.groupByteCount, bytes.count, vector.name)

            for (shard, frozen) in zip(shards, vector.shards) {
                XCTAssertEqual(shard.envelope.seq.rawValue, frozen.seq, vector.name)
                XCTAssertEqual(
                    shard.envelope.fec,
                    try XCTUnwrap(Hex.uint64(frozen.fecHex)),
                    vector.name
                )
                let datagram = try shard.encodeDatagram()
                XCTAssertEqual(
                    Hex.string(Sha256.digest(datagram)), frozen.datagramSha256,
                    "\(vector.name): datagram hash — the packetized corpus has drifted"
                )
                if let hex = frozen.datagramHex {
                    XCTAssertEqual(Hex.string(datagram), hex, vector.name)
                }
            }
        }
    }

    func testScenariosAssembleAsFrozen() throws {
        let file = try loadFile()
        var framesByName: [String: (vector: VideoFrameVector, bytes: [UInt8])] = [:]
        for vector in file.frames {
            framesByName[vector.name] = (vector, try vector.source.loadBytes(
                corpusDirectory: Self.corpusDirectory
            ))
        }

        for (scenario, events) in try replayVideoScenarios(
            file, corpusDirectory: Self.corpusDirectory
        ) {
            var decoded: [DecodeUnit] = []
            var impossible: [UInt32] = []
            for event in events {
                switch event {
                case .decoded(let unit): decoded.append(unit)
                case .fecImpossible(let frame, _, _): impossible.append(frame.rawValue)
                default: break
                }
            }

            XCTAssertEqual(
                decoded.map(\.frameNumber.rawValue),
                scenario.expectDecoded.map { framesByName[$0]!.vector.frameNumber },
                "\(scenario.name): decode order"
            )
            for (unit, name) in zip(decoded, scenario.expectDecoded) {
                let frame = framesByName[name]!
                XCTAssertEqual(
                    unit.annexB, frame.bytes,
                    "\(scenario.name): \(name) not byte-identical"
                )
                XCTAssertEqual(unit.isIDR, frame.vector.isIDR, scenario.name)
                XCTAssertEqual(
                    unit.timestamp.microseconds,
                    Hex.uint64(frame.vector.timestampHex),
                    scenario.name
                )
            }
            XCTAssertEqual(
                impossible.sorted(),
                scenario.expectFecImpossible
                    .map { framesByName[$0]!.vector.frameNumber }.sorted(),
                "\(scenario.name): fec-impossible set"
            )
        }
    }
}
