import XCTest
import Foundation
import HostCore
import HostSession
import HostWire
import LyteWire
import LyteWireTestKit

// THE GATE (the fall-repricing purge, REMAINING #6): bytes admitted to
// the pacer at 50 Mbps and repriced by a crash to 5 Mbps used to
// serialize at the crashed rate — 80–895 ms of stale wire the glass
// rendered late or never. The purge drops queued video at the fall
// moment and re-anchors with a fresh IDR through the coalesced latch.
// Three rungs: the pacer's dropClass mechanics, the channel's census
// settlement, and the whole session driven to a genuine loss fall
// with real chan-3 FeedbackReports.

final class FallPurgeGateTests: XCTestCase {

    // MARK: Pacer.dropClass

    func testDropClassRemovesOnlyItsClassAndKeepsTheBucketWhole() {
        let pacer = Pacer(rateBitsPerSecond: 20_000_000, now: 0)
        pacer.enqueue(.control, bytes: 100, now: 0)
        pacer.enqueue(.audio, bytes: 200, now: 0)
        pacer.enqueue(.freshVideo, bytes: 1_000, urgent: true, tag: 1, now: 0)
        pacer.enqueue(.freshVideo, bytes: 1_100, tag: 2, now: 0)
        pacer.enqueue(.videoTail, bytes: 900, tag: 3, now: 0)

        let dropped = pacer.dropClass(.freshVideo)
        XCTAssertEqual(Set(dropped.map(\.tag)), [1, 2],
                       "both urgent and normal tokens return to the caller")
        XCTAssertEqual(pacer.queuedBytes(.freshVideo), 0)
        XCTAssertEqual(pacer.queuedCount(.freshVideo), 0)
        XCTAssertEqual(pacer.queuedBytes(.control), 100,
                       "other classes keep their place")
        XCTAssertEqual(pacer.queuedBytes(.audio), 200)
        XCTAssertEqual(pacer.queuedBytes(.videoTail), 900)
        XCTAssertTrue(pacer.dropClass(.freshVideo).isEmpty,
                      "a second drop finds nothing")

        // The bucket was untouched: control and audio emit immediately.
        let batch = pacer.nextBatch(now: 0)
        XCTAssertEqual(batch?.tokens.map(\.priorityClass),
                       [.control, .audio, .videoTail],
                       "the surviving classes drain in strict priority")
    }

    // MARK: VideoChannel.purgeQueuedVideo

    func testPurgeSettlesPendingStoreAndPerFrameCensus() throws {
        var sent = 0
        // 2 Mbps: a corpus-scale frame cannot drain in test time, so
        // the queue is genuinely deep when the purge lands.
        let channel = VideoChannel(
            config: VideoChannelConfig(rateBitsPerSecond: 2_000_000),
            now: 0
        ) { _ in sent += 1 }

        let frame = [UInt8](repeating: 0x42, count: 40_000)
        // A raw payload blob fails Annex-B checks, so build shards via
        // the plain-payload seam the audio/control paths use — no:
        // video needs the packetizer. Use a synthetic Annex-B P-frame
        // shape instead: start code + non-IRAP NAL header + payload.
        var annexB: [UInt8] = [0, 0, 0, 1, 0x02, 0x01]
        annexB += frame
        try channel.ingest(
            frame: annexB,
            frameNumber: FrameNumber(rawValue: 7),
            captureTimestampMicroseconds: 1_000,
            isKeyframe: false,
            now: 0
        )
        let queuedBefore = channel.queuedBytes(.freshVideo)
        XCTAssertGreaterThan(queuedBefore, 40_000,
                             "the frame is queued, not sent")
        XCTAssertEqual(channel.framesWithQueuedShards(), [7])
        channel.annotateFrameTelemetry(
            frame: FrameNumber(rawValue: 7), averageQP: 24,
            idrCauses: []
        )

        let purged = channel.purgeQueuedVideo()
        XCTAssertGreaterThan(purged.datagrams, 30)
        XCTAssertEqual(purged.bytes, queuedBefore,
                       "the purge accounts for every queued byte")
        XCTAssertEqual(channel.queuedBytes(.freshVideo), 0)
        XCTAssertEqual(channel.queuedBytes(.videoTail), 0)
        XCTAssertTrue(channel.framesWithQueuedShards().isEmpty,
                      "the census settles with the drop")
        XCTAssertNil(channel.repairAnchor(for: FrameNumber(rawValue: 7)),
                     "purge must invalidate the matching repair-store frame")
        XCTAssertTrue(channel.wasPurged(FrameNumber(rawValue: 7)))
        XCTAssertEqual(try channel.enqueueRepair(
            frame: FrameNumber(rawValue: 7), shardIndices: [0], now: 1
        ), 0, "a NACK cannot resurrect a purged frame as videoTail")
        let telemetryBatch = channel.takeFrameTransmitTelemetry()
        XCTAssertEqual(telemetryBatch.count, 1)
        let telemetry = try XCTUnwrap(telemetryBatch.first)
        XCTAssertEqual(telemetry.frameNumber, 7)
        XCTAssertEqual(telemetry.captureTimestampMicroseconds, 1_000)
        XCTAssertEqual(telemetry.admittedAtNS, 0)
        XCTAssertNil(telemetry.firstTransmitAtNS)
        XCTAssertNil(telemetry.lastTransmitAtNS)
        XCTAssertEqual(telemetry.averageQP, 24)
        XCTAssertEqual(telemetry.pacerRateBitsPerSecond, 2_000_000)
        XCTAssertEqual(telemetry.fecRegime, .clean)
        XCTAssertEqual(telemetry.queuedWireTimeBeforeAdmissionNS, 0)
        XCTAssertTrue(telemetry.purged)
        XCTAssertEqual(sent, 0)

        // Nothing ghost-drains afterwards.
        channel.pump(now: 10_000_000_000)
        XCTAssertEqual(sent, 0, "purged datagrams must never reach the wire")
        XCTAssertTrue(channel.isIdle)
    }

    // MARK: The whole session, driven to a genuine loss fall

    func testLossFallPurgesBacklogAndArmsIdrThroughTheSession() throws {
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .insecure,
                rateBitsPerSecond: 2_000_000,
                beaconIntervalNS: 1 << 62
            ),
            clientTuple: FourTuple(
                localAddress: "10.0.0.1", localPort: 41000,
                remoteAddress: "10.0.0.2", remotePort: 42000
            ),
            now: 0,
            rng: SplitMix64(seed: 0xFA11)
        ) { sent.append($0) }

        var received: UInt32 = 0
        var missing: UInt32 = 0
        func feedback(tMicros: UInt64, newReceived: UInt32,
                      newMissing: UInt32) -> [SessionEvent] {
            received += newReceived
            missing += newMissing
            let body = try! FeedbackReport(
                clientTimestamp: ClientTimestamp(microseconds: tMicros),
                channels: [FeedbackReport.ChannelStats(
                    channel: .videoActive,
                    highestSeq: ChannelSeq(rawValue: 0),
                    received: received, missing: missing, duplicates: 0
                )]
            ).encode()
            let envelope = Envelope(
                channel: .feedback,
                seq: ChannelSeq(
                    rawValue: UInt16(truncatingIfNeeded: tMicros / 25_000)),
                frame: FrameNumber(rawValue: 0),
                timestamp: tMicros,
                fec: 0
            )
            let datagram = try! envelope.encode(payload: body)
            return session.receive(
                datagram, from: FourTuple(
                    localAddress: "10.0.0.1", localPort: 41000,
                    remoteAddress: "10.0.0.2", remotePort: 42000
                ),
                now: tMicros * 1_000, hostMicroseconds: tMicros
            )
        }

        // Prime the ledger, then queue a video frame the 2 Mbps pacer
        // cannot drain (nothing pumps in this test): the standing
        // backlog a fall must reprice.
        _ = feedback(tMicros: 25_000, newReceived: 100, newMissing: 0)
        var annexB: [UInt8] = [0, 0, 0, 1, 0x02, 0x01]
        annexB += [UInt8](repeating: 0x42, count: 40_000)
        _ = try session.ingestVideoFrame(
            annexB, captureTimestampMicroseconds: 25_000,
            isKeyframe: false, now: 25_000_000
        )
        let backlog = session.queuedVideoBytes
        XCTAssertGreaterThan(backlog, 40_000)
        // Consume the demand ledger so the purge's arm stands alone.
        _ = session.takeFreshKeyframeDemand()

        // 20% loss at the 25 ms cadence until the rolling window
        // crosses the downshift band and the fall fires.
        var purgeEvents: [SessionEvent] = []
        var sawFall = false
        var t: UInt64 = 25_000
        for _ in 0..<80 {
            t += 25_000
            for event in feedback(tMicros: t, newReceived: 80,
                                  newMissing: 20) {
                if case .rateChanged(_, .loss) = event { sawFall = true }
                if case .videoBacklogPurged = event {
                    purgeEvents.append(event)
                }
            }
            if !purgeEvents.isEmpty { break }
        }
        XCTAssertTrue(sawFall, "the 20% burst must produce a loss fall")
        XCTAssertEqual(purgeEvents.count, 1)
        guard case let .videoBacklogPurged(datagrams, bytes, staleWireMs) =
            purgeEvents[0]
        else { return XCTFail("purge event shape") }
        XCTAssertGreaterThan(datagrams, 30)
        XCTAssertEqual(bytes, backlog,
                       "every queued video byte was repriced and dropped")
        XCTAssertGreaterThan(staleWireMs, 50,
                             "under-threshold backlog must never purge")
        XCTAssertEqual(session.queuedVideoBytes, 0)
        XCTAssertEqual(session.counters.fallPurges, 1)
        XCTAssertEqual(session.counters.fallPurgedVideoBytes, backlog)

        // The re-anchor: the next encoder poll owes an IDR, named.
        let demand = session.takeFreshKeyframeDemand()
        XCTAssertTrue(demand.contains(.fallPurge))
        XCTAssertTrue(demand.names.contains("fall-purge"))

        // A later NACK for the purged frame is superseded. It neither
        // re-enqueues repair bytes nor arms another IDR after the one
        // replacement demand above was consumed.
        let nacked = try FeedbackReport.NackEntry(
            frame: FrameNumber(rawValue: 0), missingShards: [0]
        )
        received += 1
        let body = try FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: t + 1),
            channels: [FeedbackReport.ChannelStats(
                channel: .videoActive,
                highestSeq: ChannelSeq(rawValue: 0),
                received: received, missing: missing, duplicates: 0
            )],
            nacks: [nacked]
        ).encode()
        let nackEvents = session.receive(
            try Envelope(
                channel: .feedback, seq: ChannelSeq(rawValue: 60_000),
                frame: FrameNumber(rawValue: 0), timestamp: t + 1, fec: 0
            ).encode(payload: body),
            from: FourTuple(
                localAddress: "10.0.0.1", localPort: 41000,
                remoteAddress: "10.0.0.2", remotePort: 42000
            ),
            now: (t + 1) * 1_000, hostMicroseconds: t + 1
        )
        XCTAssertTrue(nackEvents.contains(.nackJudgedStale(
            frame: FrameNumber(rawValue: 0), reason: .olderThanIdr
        )))
        XCTAssertFalse(session.takeFreshKeyframeRequest())
    }

    func testQueueBudgetDefaultsAndImpairedClamp() {
        let defaults = SessionConfig(
            crypto: .insecure, rateBitsPerSecond: 20_000_000
        )
        XCTAssertEqual(defaults.cleanVideoQueueBudgetNS, 50_000_000)
        XCTAssertEqual(defaults.impairedVideoQueueBudgetNS, 100_000_000)

        let clamped = SessionConfig(
            crypto: .insecure,
            rateBitsPerSecond: 20_000_000,
            cleanVideoQueueBudgetNS: 40_000_000,
            impairedVideoQueueBudgetNS: 500_000_000
        )
        XCTAssertEqual(clamped.impairedVideoQueueBudgetNS, 100_000_000,
                       "impaired mode must remain hard-bounded")
    }

    func testFrameFlightTelemetryJoinsStagesWithinCleanBudget() throws {
        let channel = VideoChannel(
            config: VideoChannelConfig(rateBitsPerSecond: 20_000_000),
            now: 0
        ) { _ in }
        var annexB: [UInt8] = [0, 0, 0, 1, 0x02, 0x01]
        annexB += [UInt8](repeating: 0x42, count: 8_000)
        try channel.ingest(
            frame: annexB, frameNumber: FrameNumber(rawValue: 11),
            captureTimestampMicroseconds: 777, isKeyframe: false, now: 0
        )
        channel.annotateFrameTelemetry(
            frame: FrameNumber(rawValue: 11), averageQP: 23,
            idrCauses: []
        )
        var now: UInt64 = 0
        while !channel.isIdle {
            channel.pump(now: now)
            guard let wake = channel.nextWake(now: now) else { break }
            now = max(now + 1, wake)
        }
        let telemetry = try XCTUnwrap(
            channel.takeFrameTransmitTelemetry().first
        )
        let first = try XCTUnwrap(telemetry.firstTransmitAtNS)
        let last = try XCTUnwrap(telemetry.lastTransmitAtNS)
        XCTAssertEqual(telemetry.captureTimestampMicroseconds, 777)
        XCTAssertEqual(telemetry.averageQP, 23)
        XCTAssertEqual(telemetry.pacerRateBitsPerSecond, 20_000_000)
        XCTAssertLessThanOrEqual(last - telemetry.admittedAtNS, 50_000_000)
        XCTAssertLessThanOrEqual(first, last)
        XCTAssertFalse(telemetry.purged)
    }

    func testQueuedRepairExpiresBeforeItCanBecomeStaleTail() throws {
        var sent: [VideoChannelDatagram] = []
        let channel = VideoChannel(
            config: VideoChannelConfig(
                rateBitsPerSecond: 20_000_000,
                repairQueueUsefulnessNS: 50_000_000
            ),
            now: 0
        ) { sent.append($0) }
        var annexB: [UInt8] = [0, 0, 0, 1, 0x02, 0x01]
        annexB += [UInt8](repeating: 0x42, count: 8_000)
        try channel.ingest(
            frame: annexB, frameNumber: FrameNumber(rawValue: 9),
            captureTimestampMicroseconds: 0, isKeyframe: false, now: 0
        )
        var now: UInt64 = 0
        while !channel.isIdle {
            channel.pump(now: now)
            guard let wake = channel.nextWake(now: now) else { break }
            now = max(now + 1, wake)
        }
        let freshCount = sent.count
        XCTAssertEqual(try channel.enqueueRepair(
            frame: FrameNumber(rawValue: 9), shardIndices: [0],
            now: now
        ), 1)

        channel.pump(now: now + 50_000_001)
        XCTAssertEqual(sent.count, freshCount,
                       "expired repair must not consume tail capacity")
        XCTAssertEqual(channel.counters.repairShardsExpiredQueued, 1)
        XCTAssertNil(channel.repairAnchor(for: FrameNumber(rawValue: 9)))
    }

    func testEvidenceDecayNeverPurges() throws {
        // The purge triggers on overuse/loss verdicts only — a plain
        // evidence move (climb or decay) must leave queued video alone
        // even when the backlog is over threshold.
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .insecure,
                rateBitsPerSecond: 2_000_000,
                beaconIntervalNS: 1 << 62
            ),
            clientTuple: FourTuple(
                localAddress: "10.0.0.1", localPort: 41000,
                remoteAddress: "10.0.0.2", remotePort: 42000
            ),
            now: 0,
            rng: SplitMix64(seed: 0xFA12)
        ) { sent.append($0) }

        var annexB: [UInt8] = [0, 0, 0, 1, 0x02, 0x01]
        annexB += [UInt8](repeating: 0x42, count: 40_000)
        _ = try session.ingestVideoFrame(
            annexB, captureTimestampMicroseconds: 1_000,
            isKeyframe: false, now: 1_000_000
        )
        let backlog = session.queuedVideoBytes
        XCTAssertGreaterThan(backlog, 40_000)

        // Clean reports at cadence: whatever evidence moves happen,
        // no purge event may surface and the backlog must survive.
        var received: UInt32 = 0
        var t: UInt64 = 1_000
        for _ in 0..<40 {
            t += 25_000
            received += 100
            let body = try! FeedbackReport(
                clientTimestamp: ClientTimestamp(microseconds: t),
                channels: [FeedbackReport.ChannelStats(
                    channel: .videoActive,
                    highestSeq: ChannelSeq(rawValue: 0),
                    received: received, missing: 0, duplicates: 0
                )]
            ).encode()
            let envelope = Envelope(
                channel: .feedback,
                seq: ChannelSeq(
                    rawValue: UInt16(truncatingIfNeeded: t / 25_000)),
                frame: FrameNumber(rawValue: 0),
                timestamp: t,
                fec: 0
            )
            let events = session.receive(
                try! envelope.encode(payload: body),
                from: FourTuple(
                    localAddress: "10.0.0.1", localPort: 41000,
                    remoteAddress: "10.0.0.2", remotePort: 42000
                ),
                now: t * 1_000, hostMicroseconds: t
            )
            for event in events {
                if case .videoBacklogPurged = event {
                    XCTFail("clean-path evidence must never purge")
                }
            }
        }
        XCTAssertEqual(session.queuedVideoBytes, backlog)
        XCTAssertEqual(session.counters.fallPurges, 0)
    }
}
