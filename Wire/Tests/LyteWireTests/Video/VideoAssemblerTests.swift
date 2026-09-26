import XCTest
import LyteCore
import LyteWireTestKit
import LyteWire

// Deterministic assembler coverage: every event, every drop reason, and
// every clause of the holdback policy exercised by hand-scripted
// deliveries with an injected clock.

private let t0 = ClientTimestamp(microseconds: 1_000_000)

private extension VideoAssembler {
    /// Ingests `shards` in order at `t0`, returning every event.
    mutating func feed(_ shards: [VideoShard]) -> [VideoAssemblerEvent] {
        shards.flatMap {
            ingest(envelope: $0.envelope, payload: $0.payload, now: t0)
        }
    }

    mutating func feed(_ shard: VideoShard) -> [VideoAssemblerEvent] {
        feed([shard])
    }
}

final class VideoAssemblerTests: XCTestCase {

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

    /// A non-positive group capacity clamps to one: the frame in hand is
    /// always trackable, and the first shard never finds a "full" empty
    /// tracker.
    func testNonPositiveTrackedGroupCapacityTracksOneGroup() throws {
        for capacity in [0, -5] {
            let config = VideoAssemblerConfig(maxTrackedGroups: capacity)
            XCTAssertEqual(config.maxTrackedGroups, 1)
            var assembler = VideoAssembler(config: config)
            var units: [DecodeUnit] = []
            for (number, seq) in [(UInt32(0), UInt16(0)), (1, 20)] {
                let frame = number == 0 ? idrFrame(400) : pFrame(400)
                units += decodedUnits(assembler.feed(
                    try packetize(frame, number: number, firstSeq: seq)
                ))
            }
            XCTAssertEqual(units.map(\.frameNumber.rawValue), [0, 1])
        }
    }

    // MARK: - Decode paths

    func testInOrderDeliveryEmitsByteExactUnit() throws {
        let frame = idrFrame(500)
        let shards = try packetize(frame, number: 0, firstSeq: 10, timestamp: 777)
        var assembler = VideoAssembler()
        let units = decodedUnits(assembler.feed(shards))
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].annexB, frame)
        XCTAssertEqual(units[0].frameNumber.rawValue, 0)
        XCTAssertEqual(units[0].timestamp.microseconds, 777)
        XCTAssertTrue(units[0].isIDR)
        XCTAssertEqual(assembler.trackedGroupCount, 0, "emitted = untracked")
    }

    func testDecodesFromDataShardsOnlyBeforeParityArrives() throws {
        let frame = pFrame(2000) // k=2 m=1
        let shards = try packetize(frame, number: 0, firstSeq: 0)
        var assembler = VideoAssembler()
        var units = decodedUnits(assembler.feed(shards[0]))
        XCTAssertTrue(units.isEmpty)
        XCTAssertEqual(assembler.trackedGroupCount, 1)
        units += decodedUnits(assembler.feed(shards[1]))
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].annexB, frame)
        XCTAssertFalse(units[0].isIDR)
    }

    func testRecoversFromLossAtParityLimitShuffled() throws {
        let frame = pFrame(3000) // k=3 m=2
        let shards = try packetize(frame, number: 5, firstSeq: 100)
        var assembler = VideoAssembler()
        // Lose data shards 0 and 2 (= m), deliver the rest reversed.
        let units = decodedUnits(assembler.feed([shards[4], shards[3], shards[1]]))
        XCTAssertEqual(units.map(\.annexB), [frame])
    }

    func testDuplicatesAreReportedAndHarmless() throws {
        let frame = pFrame(1500) // k=2 m=1
        let shards = try packetize(frame, number: 0, firstSeq: 0)
        var assembler = VideoAssembler()
        _ = assembler.feed(shards[0])
        let dupEvents = assembler.feed(shards[0])
        XCTAssertEqual(dupEvents, [.shardDropped(
            .duplicateShard(FrameNumber(rawValue: 0), shardIndex: 0)
        )])
        let units = decodedUnits(assembler.feed(shards[1]))
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

        // Inconsistent group: same frame number, different GEOMETRY —
        // on a k=2 frame so the group is still pending when the liar
        // arrives. (A moved seq with MATCHING geometry is the repair
        // lane now — see the repair tests below.)
        let pending = try packetize(pFrame(2000), number: 0, firstSeq: 0)
        _ = assembler.feed(pending[0])
        let liar = try packetize(pFrame(3000), number: 0, firstSeq: 10)
        XCTAssertEqual(
            assembler.feed(liar[1]),
            [.shardDropped(.inconsistentGroup(FrameNumber(rawValue: 0)))]
        )
    }

    func testLateShardForEmittedFrameDropsAsStale() throws {
        let shards = try packetize(pFrame(100), number: 3, firstSeq: 0)
        var assembler = VideoAssembler()
        _ = assembler.feed(shards[0])
        // k=1: the frame emitted from its single data shard. A parity
        // straggler must not reopen it.
        XCTAssertEqual(
            assembler.feed(shards[1]),
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

        _ = assembler.feed(shards0[0])

        // Frame 1's first shard: highest=3, frame 0's seqs 1,2 are only
        // 2 and 1 behind — below the reorder threshold, nothing presumed.
        var events = assembler.feed(shards1[0])
        XCTAssertFalse(events.contains { if case .nackCandidates = $0 { true } else { false } })

        // Frame 1's parity: highest=4, seq 1 is 3 behind → NACK candidate.
        // The enriched fields carry the frame's whole picture: shard
        // index 1 missing, one parity shard, ingested this same instant.
        events = assembler.feed(shards1[1])
        XCTAssertTrue(events.contains(.nackCandidates(
            FrameNumber(rawValue: 0),
            missingSeqs: [ChannelSeq(rawValue: 1)],
            missingShardIndices: [1],
            parityShards: 1,
            frameAgeMicroseconds: 0
        )))
        // Not fec-impossible yet: seq 2 (the parity) could still arrive.
        XCTAssertFalse(events.contains { if case .fecImpossible = $0 { true } else { false } })

        // Frame 2 pushes highest to 6: seq 2 is presumed lost too — now
        // one data shard is gone with no parity plausibly in flight.
        events = assembler.feed(shards2)
        // Both of frame 0's tail seqs are now presumed lost — 2 missing
        // against 1 parity shard is PAST PARITY (the repair-ask trigger).
        XCTAssertTrue(events.contains(.nackCandidates(
            FrameNumber(rawValue: 0),
            missingSeqs: [ChannelSeq(rawValue: 2)],
            missingShardIndices: [1, 2],
            parityShards: 1,
            frameAgeMicroseconds: 0
        )))
        XCTAssertTrue(events.contains(.fecImpossible(
            FrameNumber(rawValue: 0),
            presumedLostDataShards: 1, bestCaseParityShards: 0
        )))
        // Frames 1 and 2 decoded but held behind frame 0.
        XCTAssertTrue(decodedUnits(events).isEmpty)

        // Presumption is not truth: the missing shard arrives after all,
        // frame 0 completes, and everything emits in frame order.
        events = assembler.feed(shards0[1])
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
        for number in [0 as UInt32, 2, 3, 4] {
            let frame = pFrame(100, fill: UInt8(0x60 + number))
            let shards = try packetize(frame, number: number, firstSeq: seq)
            seq += UInt16(shards.count)
            events += assembler.feed(shards)
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
        let frame0 = pFrame(100, fill: 0x70)
        let frame2 = pFrame(100, fill: 0x72)
        let events = assembler.feed(
            try packetize(frame0, number: 0, firstSeq: 0)
                + packetize(frame2, number: 2, firstSeq: 4)
        )
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
        _ = assembler.feed(shards[0])
        let events = assembler.evictStale(
            now: t0.advanced(byMicroseconds: 250_000)
        )
        XCTAssertEqual(events, [.evicted(FrameNumber(rawValue: 0), reason: .stale)])
        XCTAssertEqual(assembler.trackedGroupCount, 0)
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
        _ = assembler.feed(a[0])
        _ = assembler.feed(b[0])

        // A third, newer frame evicts the lowest-numbered group.
        let events = assembler.feed(c[0])
        XCTAssertTrue(events.contains(
            .evicted(FrameNumber(rawValue: 10), reason: .capacity)
        ))

        // A frame older than everything tracked bounces instead.
        let old = try packetize(pFrame(100, fill: 0x40), number: 5, firstSeq: 30)
        XCTAssertEqual(
            assembler.feed(old[0]),
            [.shardDropped(.staleFrame(FrameNumber(rawValue: 5)))]
        )
    }

    // MARK: - Integrity (correct bytes or nothing)

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

    // MARK: - Repair shards (the receive half of the host's repair lane)

    /// Builds the host's enqueueRepair datagram shape from an original
    /// shard: same frame number, fec field, and timestamp — a FRESH seq.
    private func repairShard(
        of shard: VideoShard, freshSeq: UInt16
    ) -> VideoShard {
        var envelope = shard.envelope
        envelope.seq = ChannelSeq(rawValue: freshSeq)
        return VideoShard(envelope: envelope, payload: shard.payload)
    }

    func testRepairShardsUnderFreshSeqsCompleteTheGroupByteExact() throws {
        // k=3 m=2: only shard 1 survives (4 lost — well past parity) —
        // then repairs of 0 and 2 arrive under fresh seqs far outside
        // the original allocation, exactly the host's enqueueRepair
        // shape.
        let frame = pFrame(3000, fill: 0x77)
        let shards = try packetize(frame, number: 0, firstSeq: 100)
        var assembler = VideoAssembler()
        var events: [VideoAssemblerEvent] = assembler.feed(shards[1])
        XCTAssertTrue(decodedUnits(events).isEmpty)

        events = assembler.feed(repairShard(of: shards[0], freshSeq: 900))
        XCTAssertTrue(events.contains(.repairShardAccepted(
            FrameNumber(rawValue: 0), shardIndex: 0
        )))
        XCTAssertTrue(decodedUnits(events).isEmpty)

        events = assembler.feed(repairShard(of: shards[2], freshSeq: 901))
        XCTAssertTrue(events.contains(.repairShardAccepted(
            FrameNumber(rawValue: 0), shardIndex: 2
        )))
        XCTAssertEqual(decodedUnits(events).map(\.annexB), [frame],
                       "the repaired group must complete byte-exact")
    }

    func testRepairCompletesAFrameAlreadyWrittenOffAsFecImpossible() throws {
        // The progression test's shape, healed by the repair lane
        // instead of a late original: presumption is not truth, and the
        // repair arrives under a seq the group never owned.
        let frame0 = pFrame(2000, fill: 0x81)
        let shards0 = try packetize(frame0, number: 0, firstSeq: 0)
        var assembler = VideoAssembler(config: VideoAssemblerConfig(
            fecImpossibleThresholdPackets: 4
        ))
        var events = assembler.feed(shards0[0])
        for number in 1...2 {   // k=1 m=1 traffic pushes highest past the write-off
            let filler = pFrame(100, fill: UInt8(0x90 + number))
            events += assembler.feed(try packetize(
                filler, number: UInt32(number), firstSeq: UInt16(1 + 2 * number)
            ))
        }
        XCTAssertTrue(events.contains {
            if case .fecImpossible(FrameNumber(rawValue: 0), _, _) = $0 { true } else { false }
        })

        let heal = assembler.feed(repairShard(of: shards0[1], freshSeq: 500))
        XCTAssertTrue(heal.contains(.repairShardAccepted(
            FrameNumber(rawValue: 0), shardIndex: 1
        )))
        XCTAssertEqual(decodedUnits(heal).first?.annexB, frame0)
    }

    func testDuplicateRepairShardReportsDuplicateAndStaysHarmless() throws {
        let frame = pFrame(2000, fill: 0x83) // k=2 m=1
        let shards = try packetize(frame, number: 0, firstSeq: 0)
        var assembler = VideoAssembler()
        _ = assembler.feed(shards[0])
        // A repair of a shard already present duplicates, never mutates
        // (its fresh seq still advances loss presumption — honest signal
        // — so presumption events may follow the duplicate report).
        let events = assembler.feed(repairShard(of: shards[0], freshSeq: 700))
        XCTAssertEqual(events.first, .shardDropped(
            .duplicateShard(FrameNumber(rawValue: 0), shardIndex: 0)
        ))
        XCTAssertFalse(events.contains(.repairShardAccepted(
            FrameNumber(rawValue: 0), shardIndex: 0
        )))
        let done = assembler.feed(shards[1])
        XCTAssertEqual(decodedUnits(done).map(\.annexB), [frame])
    }

    func testRepairForAnEmittedFrameDropsAsStale() throws {
        let frame = pFrame(100, fill: 0x84) // k=1 m=1: emits from shard 0
        let shards = try packetize(frame, number: 0, firstSeq: 0)
        var assembler = VideoAssembler()
        let emitted = assembler.feed(shards[0])
        XCTAssertEqual(decodedUnits(emitted).count, 1)
        XCTAssertEqual(
            assembler.feed(repairShard(of: shards[1], freshSeq: 800)),
            [.shardDropped(.staleFrame(FrameNumber(rawValue: 0)))]
        )
    }

    func testRepairShardsAloneCanOpenAndCompleteAGroup() throws {
        // Every original shard died; only repairs arrive. The first one
        // opens the group (its derived base is the best knowledge
        // available); the rest slot in by index and the frame still
        // completes byte-exact — k=3 m=2 healed from shards 0, 3, 4.
        let frame = pFrame(3000, fill: 0x85)
        let shards = try packetize(frame, number: 7, firstSeq: 40)
        var assembler = VideoAssembler()
        let events = assembler.feed([
            repairShard(of: shards[0], freshSeq: 200),
            repairShard(of: shards[3], freshSeq: 201),
            repairShard(of: shards[4], freshSeq: 202),
        ])
        XCTAssertEqual(decodedUnits(events).map(\.annexB), [frame])
        XCTAssertEqual(decodedUnits(events).first?.frameNumber.rawValue, 7)
    }

    func testRepairGeometryLieStillDropsInconsistent() throws {
        // The repair lane must not have widened the door for actual
        // sender bugs: matching frame number, foreign geometry, fresh
        // seq — still refused loud.
        let shards = try packetize(pFrame(2000, fill: 0x86), number: 0, firstSeq: 0)
        var assembler = VideoAssembler()
        _ = assembler.feed(shards[0])
        let alien = try packetize(pFrame(3000, fill: 0x87), number: 0, firstSeq: 60)
        XCTAssertEqual(
            assembler.feed(repairShard(of: alien[1], freshSeq: 300)),
            [.shardDropped(.inconsistentGroup(FrameNumber(rawValue: 0)))]
        )
    }

    // MARK: - Threshold invariant and sweep bookkeeping pins

    func testFecImpossibleThresholdIsAtLeastReorderThreshold() {
        let config = VideoAssemblerConfig(
            reorderThresholdPackets: 5,
            fecImpossibleThresholdPackets: 2
        )
        XCTAssertEqual(config.reorderThresholdPackets, 5)
        XCTAssertEqual(
            config.fecImpossibleThresholdPackets, 5,
            "write-off must never be looser than NACK presumption")
        let alreadyOrdered = VideoAssemblerConfig(
            reorderThresholdPackets: 3,
            fecImpossibleThresholdPackets: 10
        )
        XCTAssertEqual(alreadyOrdered.fecImpossibleThresholdPackets, 10)
    }

    func testOutOfOrderFillWaitsOnTheHoleThenDecodes() throws {
        // k=3 m=2: shards 0 and 2 leave a hole at 1 — pending, nothing
        // emitted; closing the hole completes the frame byte-exact.
        let frame = pFrame(3000, fill: 0x91)
        let shards = try packetize(frame, number: 0, firstSeq: 0)
        var assembler = VideoAssembler()
        for index in [0, 2] {
            XCTAssertTrue(decodedUnits(assembler.feed(shards[index])).isEmpty)
        }
        XCTAssertEqual(assembler.trackedGroupCount, 1)
        let units = decodedUnits(assembler.feed(shards[1]))
        XCTAssertEqual(units.map(\.annexB), [frame])
        XCTAssertEqual(assembler.trackedGroupCount, 0, "decoded group leaves the tracker")
    }

    func testSweepSettlesOnceAbsentSeqsAreWrittenOff() throws {
        let frame0 = pFrame(2000, fill: 0x92)
        let shards0 = try packetize(frame0, number: 0, firstSeq: 0)
        let shards1 = try packetize(pFrame(100, fill: 0x93), number: 1, firstSeq: 3)
        let shards2 = try packetize(pFrame(100, fill: 0x94), number: 2, firstSeq: 5)
        var assembler = VideoAssembler(config: VideoAssemblerConfig(
            fecImpossibleThresholdPackets: 4
        ))
        let written = assembler.feed([shards0[0]] + shards1 + shards2)
        XCTAssertTrue(written.contains {
            if case .fecImpossible(FrameNumber(rawValue: 0), _, _) = $0 { true } else { false }
        })

        // Further channel advance must not re-mint NACK/fec events for
        // a settled group — the latch is the early-out.
        let filler = try packetize(pFrame(100, fill: 0x95), number: 3, firstSeq: 7)
        let events = assembler.feed(filler)
        XCTAssertFalse(events.contains {
            if case .nackCandidates(let frame, _, _, _, _) = $0 {
                return frame.rawValue == 0
            }
            return false
        })
        XCTAssertFalse(events.contains {
            if case .fecImpossible(let frame, _, _) = $0 {
                return frame.rawValue == 0
            }
            return false
        })
    }

    func testLossSweepSkippedWhenNeitherSeqNorGroupAdvances() throws {
        // After a NACK has fired, a duplicate of an already-seen shard
        // neither opens a group nor advances highestSeq — the gate must
        // skip the whole sweep (no re-minted candidates).
        let frame0 = pFrame(2000, fill: 0x96)
        let shards0 = try packetize(frame0, number: 0, firstSeq: 0)
        let shards1 = try packetize(pFrame(100, fill: 0x97), number: 1, firstSeq: 3)
        var assembler = VideoAssembler(config: VideoAssemblerConfig(
            fecImpossibleThresholdPackets: 4
        ))
        _ = assembler.feed(shards0[0])
        _ = assembler.feed(shards1[0])
        let nackPass = assembler.feed(shards1[1])
        XCTAssertTrue(nackPass.contains {
            if case .nackCandidates = $0 { return true }
            return false
        })

        let dup = assembler.feed(shards0[0])
        XCTAssertEqual(dup, [
            .shardDropped(.duplicateShard(FrameNumber(rawValue: 0), shardIndex: 0))
        ])
    }
}
