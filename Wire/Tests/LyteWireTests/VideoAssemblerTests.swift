import XCTest
import LyteWire
import LyteWireTestKit

// Deterministic assembler coverage: every event, every drop reason, and
// every clause of the holdback policy exercised by hand-scripted
// deliveries with an injected clock.

final class VideoAssemblerTests: XCTestCase {

    private let t0 = ClientTimestamp(microseconds: 1_000_000)

    private func pFrame(_ totalByteCount: Int, fill: UInt8 = 0x33) -> [UInt8] {
        [0, 0, 0, 1, 0x02, 0x01]
            + Array(repeating: fill, count: totalByteCount - 6)
    }

    private func idrFrame(_ totalByteCount: Int) -> [UInt8] {
        [0, 0, 0, 1, 0x26, 0x01]
            + Array(repeating: 0x44, count: totalByteCount - 6)
    }

    private func packetize(
        _ frame: [UInt8], number: UInt32, firstSeq: UInt16,
        timestamp: UInt64 = 555, regime: FecRegime = .clean
    ) throws -> [VideoShard] {
        var packetizer = VideoPacketizer(firstSeq: ChannelSeq(rawValue: firstSeq))
        return try packetizer.packetize(
            frame: frame,
            frameNumber: FrameNumber(rawValue: number),
            captureTimestamp: HostTimestamp(microseconds: timestamp),
            isIDR: AnnexBCheck.containsIrap(frame),
            regime: regime
        )
    }

    private func decodedUnits(_ events: [VideoAssemblerEvent]) -> [DecodeUnit] {
        events.compactMap {
            if case .decoded(let unit) = $0 { return unit } else { return nil }
        }
    }

    // MARK: - Decode paths

    func testInOrderDeliveryEmitsByteExactUnit() throws {
        let frame = idrFrame(500)
        let shards = try packetize(frame, number: 0, firstSeq: 10, timestamp: 777)
        var assembler = VideoAssembler()

        var units: [DecodeUnit] = []
        for shard in shards {
            units += decodedUnits(assembler.ingest(
                envelope: shard.envelope, payload: shard.payload, now: t0
            ))
        }
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].annexB, frame)
        XCTAssertEqual(units[0].frameNumber.rawValue, 0)
        XCTAssertEqual(units[0].timestamp.microseconds, 777)
        XCTAssertTrue(units[0].isIDR)
        XCTAssertNil(assembler.status(of: FrameNumber(rawValue: 0)), "emitted = untracked")
    }

    func testDecodesFromDataShardsOnlyBeforeParityArrives() throws {
        let frame = pFrame(2000) // k=2 m=1
        let shards = try packetize(frame, number: 0, firstSeq: 0)
        var assembler = VideoAssembler()
        var units = decodedUnits(assembler.ingest(
            envelope: shards[0].envelope, payload: shards[0].payload, now: t0
        ))
        XCTAssertTrue(units.isEmpty)
        XCTAssertEqual(
            assembler.status(of: FrameNumber(rawValue: 0)),
            .recoverablePending(receivedShards: 1, dataShards: 2, parityShards: 1)
        )
        units += decodedUnits(assembler.ingest(
            envelope: shards[1].envelope, payload: shards[1].payload, now: t0
        ))
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].annexB, frame)
        XCTAssertFalse(units[0].isIDR)
    }

    func testRecoversFromLossAtParityLimitShuffled() throws {
        let frame = pFrame(3000) // k=3 m=2
        let shards = try packetize(frame, number: 5, firstSeq: 100)
        var assembler = VideoAssembler()
        // Lose data shards 0 and 2 (= m), deliver the rest reversed.
        var units: [DecodeUnit] = []
        for shard in [shards[4], shards[3], shards[1]] {
            units += decodedUnits(assembler.ingest(
                envelope: shard.envelope, payload: shard.payload, now: t0
            ))
        }
        XCTAssertEqual(units.map(\.annexB), [frame])
    }

    func testDuplicatesAreReportedAndHarmless() throws {
        let frame = pFrame(1500) // k=2 m=1
        let shards = try packetize(frame, number: 0, firstSeq: 0)
        var assembler = VideoAssembler()
        _ = assembler.ingest(envelope: shards[0].envelope, payload: shards[0].payload, now: t0)
        let dupEvents = assembler.ingest(
            envelope: shards[0].envelope, payload: shards[0].payload, now: t0
        )
        XCTAssertEqual(dupEvents, [.shardDropped(
            .duplicateShard(FrameNumber(rawValue: 0), shardIndex: 0)
        )])
        let units = decodedUnits(assembler.ingest(
            envelope: shards[1].envelope, payload: shards[1].payload, now: t0
        ))
        XCTAssertEqual(units.map(\.annexB), [frame])
    }

    // MARK: - Drop reasons

    func testDropReasons() throws {
        var assembler = VideoAssembler()
        let shards = try packetize(pFrame(100), number: 0, firstSeq: 0)

        // Wrong channel.
        var envelope = shards[0].envelope
        envelope.channel = .audio
        XCTAssertEqual(
            assembler.ingest(envelope: envelope, payload: shards[0].payload, now: t0),
            [.shardDropped(.wrongChannel(.audio))]
        )

        // Malformed fec field: scheme none carries no shard place.
        envelope = shards[0].envelope
        envelope.fec = 0
        XCTAssertEqual(
            assembler.ingest(envelope: envelope, payload: shards[0].payload, now: t0),
            [.shardDropped(.malformedFecField)]
        )

        // Payload length disagrees with the geometry.
        XCTAssertEqual(
            assembler.ingest(
                envelope: shards[0].envelope,
                payload: Array(shards[0].payload.dropLast()),
                now: t0
            ),
            [.shardDropped(.payloadLengthMismatch(
                shardIndex: 0, expected: 100, actual: 99
            ))]
        )

        // Inconsistent group: same frame number, different seq base —
        // on a k=2 frame so the group is still pending when the liar
        // arrives.
        let pending = try packetize(pFrame(2000), number: 0, firstSeq: 0)
        _ = assembler.ingest(
            envelope: pending[0].envelope, payload: pending[0].payload, now: t0
        )
        var moved = pending[1].envelope
        moved.seq = ChannelSeq(rawValue: 40)
        XCTAssertEqual(
            assembler.ingest(envelope: moved, payload: pending[1].payload, now: t0),
            [.shardDropped(.inconsistentGroup(FrameNumber(rawValue: 0)))]
        )
    }

    func testLateShardForEmittedFrameDropsAsStale() throws {
        let shards = try packetize(pFrame(100), number: 3, firstSeq: 0)
        var assembler = VideoAssembler()
        for shard in shards.prefix(1) {
            _ = assembler.ingest(envelope: shard.envelope, payload: shard.payload, now: t0)
        }
        // k=1: the frame emitted from its single data shard. A parity
        // straggler must not reopen it.
        XCTAssertEqual(
            assembler.ingest(
                envelope: shards[1].envelope, payload: shards[1].payload, now: t0
            ),
            [.shardDropped(.staleFrame(FrameNumber(rawValue: 3)))]
        )
    }

    // MARK: - Decision outputs (§4.7 NACK candidates, fec-impossible)

    func testNackCandidatesAndFecImpossibleProgression() throws {
        // Frame 0: k=2 m=1, seqs 0 1 2 — only shard 0 arrives.
        // Frames 1 and 2 (k=1 m=1) advance the channel's highest seq.
        // The write-off threshold is tightened to 4 so the verdict lands
        // within this little scripted window (default 10 needs more
        // follow-on traffic than the scenario carries).
        let frame0 = pFrame(2000, fill: 0x51)
        let frame1 = pFrame(100, fill: 0x52)
        let frame2 = pFrame(100, fill: 0x53)
        let shards0 = try packetize(frame0, number: 0, firstSeq: 0)
        let shards1 = try packetize(frame1, number: 1, firstSeq: 3)
        let shards2 = try packetize(frame2, number: 2, firstSeq: 5)
        var assembler = VideoAssembler(config: VideoAssemblerConfig(
            fecImpossibleThresholdPackets: 4
        ))

        _ = assembler.ingest(envelope: shards0[0].envelope, payload: shards0[0].payload, now: t0)

        // Frame 1's first shard: highest=3, frame 0's seqs 1,2 are only
        // 2 and 1 behind — below the reorder threshold, nothing presumed.
        var events = assembler.ingest(
            envelope: shards1[0].envelope, payload: shards1[0].payload, now: t0
        )
        XCTAssertFalse(events.contains { if case .nackCandidates = $0 { true } else { false } })

        // Frame 1's parity: highest=4, seq 1 is 3 behind → NACK candidate.
        events = assembler.ingest(
            envelope: shards1[1].envelope, payload: shards1[1].payload, now: t0
        )
        XCTAssertTrue(events.contains(.nackCandidates(
            FrameNumber(rawValue: 0), missingSeqs: [ChannelSeq(rawValue: 1)]
        )))
        // Not fec-impossible yet: seq 2 (the parity) could still arrive.
        XCTAssertFalse(events.contains { if case .fecImpossible = $0 { true } else { false } })
        XCTAssertEqual(
            assembler.status(of: FrameNumber(rawValue: 0)),
            .recoverablePending(receivedShards: 1, dataShards: 2, parityShards: 1)
        )

        // Frame 2 pushes highest to 6: seq 2 is presumed lost too — now
        // one data shard is gone with no parity plausibly in flight.
        events = []
        for shard in shards2 {
            events += assembler.ingest(
                envelope: shard.envelope, payload: shard.payload, now: t0
            )
        }
        XCTAssertTrue(events.contains(.nackCandidates(
            FrameNumber(rawValue: 0), missingSeqs: [ChannelSeq(rawValue: 2)]
        )))
        XCTAssertTrue(events.contains(.fecImpossible(
            FrameNumber(rawValue: 0),
            presumedLostDataShards: 1, bestCaseParityShards: 0
        )))
        XCTAssertEqual(
            assembler.status(of: FrameNumber(rawValue: 0)), .fecImpossible
        )
        // Frames 1 and 2 decoded but held behind frame 0.
        XCTAssertTrue(decodedUnits(events).isEmpty)

        // Presumption is not truth: the missing shard arrives after all,
        // frame 0 completes, and everything emits in frame order.
        events = assembler.ingest(
            envelope: shards0[1].envelope, payload: shards0[1].payload, now: t0
        )
        XCTAssertEqual(decodedUnits(events).map(\.annexB), [frame0, frame1, frame2])
    }

    // MARK: - Holdback policy

    func testGapSkipsWhenHoldbackCountExceeded() throws {
        // Emit frame 0; frame 1 is lost entirely; frames 2, 3, 4 decode
        // and pile up to the holdback limit — the gap is skipped.
        var assembler = VideoAssembler(config: VideoAssemblerConfig(
            holdbackFrameCount: 3, staleAfterMicroseconds: 1_000_000,
            maxTrackedGroups: 64, reorderThresholdPackets: 3
        ))
        var events: [VideoAssemblerEvent] = []
        var seq: UInt16 = 0
        var frames: [UInt32: [UInt8]] = [:]
        for number in [0 as UInt32, 2, 3, 4] {
            let frame = pFrame(100, fill: UInt8(0x60 + number))
            frames[number] = frame
            let shards = try packetize(frame, number: number, firstSeq: seq)
            seq += UInt16(shards.count)
            if number == 1 { continue }
            for shard in shards {
                events += assembler.ingest(
                    envelope: shard.envelope, payload: shard.payload, now: t0
                )
            }
        }
        XCTAssertTrue(events.contains(.framesSkipped(
            from: FrameNumber(rawValue: 1), through: FrameNumber(rawValue: 1),
            reason: .holdbackExceeded
        )))
        XCTAssertEqual(
            decodedUnits(events).map(\.frameNumber.rawValue), [0, 2, 3, 4]
        )
    }

    func testGapSkipsWhenHeldFrameGoesStale() throws {
        // Emit frame 0, lose frame 1 entirely, decode frame 2 — then a
        // stale tick expires the wait and frame 2 emits.
        var assembler = VideoAssembler()
        var events: [VideoAssemblerEvent] = []
        let frame0 = pFrame(100, fill: 0x70)
        let frame2 = pFrame(100, fill: 0x72)
        for shard in try packetize(frame0, number: 0, firstSeq: 0) {
            events += assembler.ingest(envelope: shard.envelope, payload: shard.payload, now: t0)
        }
        for shard in try packetize(frame2, number: 2, firstSeq: 4) {
            events += assembler.ingest(envelope: shard.envelope, payload: shard.payload, now: t0)
        }
        XCTAssertEqual(decodedUnits(events).map(\.annexB), [frame0])

        let tick = assembler.evictStale(
            now: t0.advanced(byMicroseconds: 250_000)
        )
        XCTAssertTrue(tick.contains(.framesSkipped(
            from: FrameNumber(rawValue: 1), through: FrameNumber(rawValue: 1),
            reason: .staleGaveUp
        )))
        XCTAssertEqual(decodedUnits(tick).map(\.annexB), [frame2])
    }

    func testStaleUndecodedGroupIsEvicted() throws {
        var assembler = VideoAssembler()
        let shards = try packetize(pFrame(2000), number: 0, firstSeq: 0) // k=2
        _ = assembler.ingest(
            envelope: shards[0].envelope, payload: shards[0].payload, now: t0
        )
        let events = assembler.evictStale(
            now: t0.advanced(byMicroseconds: 250_000)
        )
        XCTAssertEqual(events, [.evicted(FrameNumber(rawValue: 0), reason: .stale)])
        XCTAssertNil(assembler.status(of: FrameNumber(rawValue: 0)))
    }

    func testCapacityEvictionPrefersTheOldestFrame() throws {
        var assembler = VideoAssembler(config: VideoAssemblerConfig(
            holdbackFrameCount: 3, staleAfterMicroseconds: 1_000_000,
            maxTrackedGroups: 2, reorderThresholdPackets: 3
        ))
        // Two pending groups fill the tracker.
        let a = try packetize(pFrame(2000, fill: 0x41), number: 10, firstSeq: 0)
        let b = try packetize(pFrame(2000, fill: 0x42), number: 11, firstSeq: 3)
        let c = try packetize(pFrame(2000, fill: 0x43), number: 12, firstSeq: 6)
        _ = assembler.ingest(envelope: a[0].envelope, payload: a[0].payload, now: t0)
        _ = assembler.ingest(envelope: b[0].envelope, payload: b[0].payload, now: t0)

        // A third, newer frame evicts the lowest-numbered group.
        let events = assembler.ingest(
            envelope: c[0].envelope, payload: c[0].payload, now: t0
        )
        XCTAssertTrue(events.contains(
            .evicted(FrameNumber(rawValue: 10), reason: .capacity)
        ))

        // A frame older than everything tracked bounces instead.
        let old = try packetize(pFrame(100, fill: 0x40), number: 5, firstSeq: 30)
        XCTAssertEqual(
            assembler.ingest(envelope: old[0].envelope, payload: old[0].payload, now: t0),
            [.shardDropped(.staleFrame(FrameNumber(rawValue: 5)))]
        )
    }

    // MARK: - Integrity (W-G3: correct bytes or nothing)

    func testRecoveredGarbageIsSuppressedNeverEmitted() throws {
        // Hand-built shards that FEC-decode fine but whose group bytes
        // are not a frame (no start code) — the assembler must skip,
        // never deliver.
        let garbage: [UInt8] = (0..<200).map { UInt8(($0 &* 7 &+ 13) & 0xFF) }
        XCTAssertFalse(AnnexBCheck.isFrameShaped(garbage))
        let geometry = try FecGeometry(
            dataShards: 2, parityShards: 1, groupByteCount: garbage.count
        )
        let payloads = try FecEncoder.encode(group: garbage, geometry: geometry)
        var assembler = VideoAssembler()
        var events: [VideoAssemblerEvent] = []
        for (index, payload) in payloads.enumerated() {
            let envelope = Envelope(
                channel: .videoActive,
                seq: ChannelSeq(rawValue: UInt16(index)),
                frame: FrameNumber(rawValue: 0),
                timestamp: 0,
                fec: try FecField.reedSolomonShard(index, of: geometry).encoded
            )
            events += assembler.ingest(envelope: envelope, payload: payload, now: t0)
        }
        XCTAssertTrue(decodedUnits(events).isEmpty)
        XCTAssertTrue(events.contains(.framesSkipped(
            from: FrameNumber(rawValue: 0), through: FrameNumber(rawValue: 0),
            reason: .corruptSuppressed
        )))
    }
}
