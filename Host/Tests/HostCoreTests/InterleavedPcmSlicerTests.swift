import HostCore
import XCTest

final class InterleavedPcmSlicerTests: XCTestCase {
    func testIrregularBuffersPreserveInterleavingAndGraphMarks() {
        let slicer = InterleavedPcmSlicer(
            sampleRate: 10, channels: 2, packetFrames: 3
        )
        var packets: [[Float]] = []
        var timestamps: [UInt64] = []

        ingest(
            [0, 1, 2, 3], graphUS: 1_000,
            into: slicer, packets: &packets, timestamps: &timestamps
        )
        ingest(
            [4, 5, 6, 7, 8, 9, 10, 11, 12, 13],
            graphUS: 901_000,
            into: slicer, packets: &packets, timestamps: &timestamps
        )

        XCTAssertEqual(packets, [
            [0, 1, 2, 3, 4, 5],
            [6, 7, 8, 9, 10, 11],
        ])
        XCTAssertEqual(timestamps, [1_000, 1_001_000])
    }

    func testChunkingDoesNotChangePacketsOrContinuousTimestamps() {
        let samples = (0..<34).map(Float.init)
        let whole = slice(
            chunks: [(samples, UInt64(40_000))]
        )
        let fragmented = slice(chunks: [
            (Array(samples[0..<4]), UInt64(40_000)),
            (Array(samples[4..<14]), UInt64(240_000)),
            (Array(samples[14..<34]), UInt64(740_000)),
        ])

        XCTAssertEqual(fragmented.packets, whole.packets)
        XCTAssertEqual(fragmented.timestamps, whole.timestamps)
        XCTAssertEqual(whole.timestamps, [40_000, 340_000, 640_000,
                                           940_000, 1_240_000])
    }

    func testFortyEightKilohertzOffsetMultipliesBeforeItDivides() {
        let slicer = InterleavedPcmSlicer(
            sampleRate: 48_000, channels: 1, packetFrames: 241
        )
        var timestamps: [UInt64] = []
        let samples = [Float](repeating: 0, count: 482)
        samples.withUnsafeBufferPointer {
            slicer.ingest(
                $0, graphStartMicroseconds: 10_000
            ) { _, timestamp in
                timestamps.append(timestamp)
            }
        }

        XCTAssertEqual(timestamps, [10_000, 15_020])
    }

    func testEmptyAndPartialBuffersInventNothing() {
        let slicer = InterleavedPcmSlicer(
            sampleRate: 10, channels: 1, packetFrames: 3
        )
        var packets: [[Float]] = []
        var timestamps: [UInt64] = []
        ingest(
            [], graphUS: 900_000,
            into: slicer, packets: &packets, timestamps: &timestamps
        )
        ingest(
            [0, 1], graphUS: 1_000,
            into: slicer, packets: &packets, timestamps: &timestamps
        )
        XCTAssertTrue(packets.isEmpty)
        ingest(
            [2], graphUS: 901_000,
            into: slicer, packets: &packets, timestamps: &timestamps
        )

        XCTAssertEqual(packets, [[0, 1, 2]])
        XCTAssertEqual(timestamps, [1_000])
    }

    func testThrowRetainsCurrentHeadAndStopsTheDrain() {
        enum Expected: Error { case stop }
        let slicer = InterleavedPcmSlicer(
            sampleRate: 10, channels: 1, packetFrames: 3
        )
        var committed: [Float] = []
        var retained: [Float] = []
        var attempt = 0

        let initial = (0..<6).map(Float.init)
        XCTAssertThrowsError(try initial.withUnsafeBufferPointer {
            try slicer.ingest(
                $0, graphStartMicroseconds: 7_000
            ) { pcm, timestamp in
                attempt += 1
                if attempt == 1 {
                    committed = Array(pcm)
                    XCTAssertEqual(timestamp, 7_000)
                } else {
                    retained = Array(pcm)
                    XCTAssertEqual(timestamp, 307_000)
                    throw Expected.stop
                }
            }
        })

        var retried: [[Float]] = []
        var timestamps: [UInt64] = []
        [Float(6)].withUnsafeBufferPointer {
            slicer.ingest(
                $0, graphStartMicroseconds: 607_000
            ) { pcm, timestamp in
                retried.append(Array(pcm))
                timestamps.append(timestamp)
            }
        }
        XCTAssertEqual(committed, [0, 1, 2])
        XCTAssertEqual(retained, [3, 4, 5])
        XCTAssertEqual(retried, [[3, 4, 5]])
        XCTAssertEqual(timestamps, [307_000])
    }

    func testConsumersCarryNoSecondSlicerState() throws {
        let hostRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let consumers = [
            "Sources/lyte-host/AudioWire.swift",
            "Sources/lyte-audio-check/main.swift",
        ]
        for path in consumers {
            let source = try String(
                contentsOf: hostRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            XCTAssertTrue(source.contains("InterleavedPcmSlicer"), path)
            XCTAssertFalse(source.contains("pendingStartFrame"), path)
            XCTAssertFalse(source.contains("marks.append"), path)
            XCTAssertFalse(source.contains("framesSeen"), path)
            XCTAssertFalse(source.contains("1_000_000 / UInt64"), path)
        }
    }

    private func slice(
        chunks: [([Float], UInt64)]
    ) -> (packets: [[Float]], timestamps: [UInt64]) {
        let slicer = InterleavedPcmSlicer(
            sampleRate: 10, channels: 2, packetFrames: 3
        )
        var packets: [[Float]] = []
        var timestamps: [UInt64] = []
        for (samples, graphUS) in chunks {
            ingest(
                samples, graphUS: graphUS,
                into: slicer, packets: &packets, timestamps: &timestamps
            )
        }
        return (packets, timestamps)
    }

    private func ingest(
        _ samples: [Float],
        graphUS: UInt64,
        into slicer: InterleavedPcmSlicer,
        packets: inout [[Float]],
        timestamps: inout [UInt64]
    ) {
        samples.withUnsafeBufferPointer {
            slicer.ingest(
                $0, graphStartMicroseconds: graphUS
            ) { pcm, timestamp in
                packets.append(Array(pcm))
                timestamps.append(timestamp)
            }
        }
    }
}
