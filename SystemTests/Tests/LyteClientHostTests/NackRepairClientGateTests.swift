import XCTest
import Foundation
import HostWire
import LyteClientSession
import LyteClientTestKit
import LyteCore
import LyteTransport
import LyteWire
import LyteWireTestKit

// Targeted repair end to end in virtual time, through the real parts of
// both roles: ReceiveDemux unseal → LyteVideoPipeline → VideoAssembler
// presumption → the core's NACK policy (past-parity trigger, staleness
// mirror, once-ever dedupe, IDR backstop) → FeedbackSender's NACK section
// on the wire → the HostWire Session's judgement → its VideoChannel
// responder (fresh-seq, fresh-seal repairs carrying the original frame
// number and fec field, one attempt per shard) → the repaired frame out of
// the same receive path, byte-exact. UDP IO and clocks are replaced by an
// in-memory pipe and one guarded virtual clock.

final class NackRepairClientGateTests: XCTestCase {

    // MARK: - Corpus

    private static var corpusDirectory: String {
        ClientTestPaths.videoCorpus
    }

    private func loadCorpus(_ count: Int) throws -> [[UInt8]] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: Self.corpusDirectory)
            .filter { $0.hasPrefix("frame-0") && $0.hasSuffix(".annexb") }
            .sorted()
            .prefix(count)
        return try names.map {
            [UInt8](try Data(contentsOf: URL(
                fileURLWithPath: Self.corpusDirectory + "/" + $0)))
        }
    }

    private func geometry(of datagrams: [[UInt8]]) throws -> FecGeometry {
        let first = try XCTUnwrap(datagrams.first)
        let (envelope, _) = try Envelope.decode(first)
        guard case .reedSolomon(_, let geometry) =
            try FecField.decode(envelope.fec) else {
            XCTFail("video frame did not use Reed-Solomon geometry")
            throw NSError(
                domain: "NackRepairClientGateTests",
                code: 1
            )
        }
        return geometry
    }

    /// A frame past parity: frame 1 (5 ms after `t`) loses its first
    /// parity+2 data shards, so FEC alone can never complete it.
    private struct Hole {
        let frame: [[UInt8]]
        let geometry: FecGeometry
        let dropped: Set<Int>
        /// The dropped shards, in order, for a leg that delivers them late.
        let held: [[UInt8]]
    }

    /// Startup, frame 0 whole (with `reportingFrame0`, its clean report
    /// reaches the host and ends the opening-IDR exemption), then frame 1
    /// holed past parity with only its survivors delivered.
    private func openHole(
        corpus: [[UInt8]], host: SystemHostSession, harness: SystemClient,
        t: inout UInt64, forwarded: inout Int, reportingFrame0: Bool = false
    ) throws -> Hole {
        try harness.settleStartup(forwarded: &forwarded, at: t)
        try harness.deliverFrame(corpus[0], number: 0, at: t)
        if reportingFrame0 {
            harness.core.feedback.tick(now: ClientTimestamp(microseconds: t))
            try harness.pumpOutboundToHost(forwarded: &forwarded)
        }
        t += 5_000
        let frame = try host.videoDatagrams(
            annexB: corpus[1], frameNumber: 1, hostMicros: t)
        let geometry = try self.geometry(of: frame)
        let dropped = Set(0..<(geometry.parityShards + 2))
        XCTAssertLessThan(dropped.count, geometry.dataShards,
                          "corpus frame must survive the drop plan")
        for (index, datagram) in frame.enumerated()
        where !dropped.contains(index) {
            harness.deliver(datagram, at: t)
        }
        return Hole(
            frame: frame, geometry: geometry, dropped: dropped,
            held: dropped.sorted().map { frame[$0] })
    }

    /// Frames `numbers` (from the corpus at the same index), 5 ms apart,
    /// each followed by a core beat.
    private func deliverFollowOns(
        _ numbers: ClosedRange<Int>, corpus: [[UInt8]],
        harness: SystemClient, t: inout UInt64
    ) throws {
        for number in numbers {
            t += 5_000
            try harness.deliverFrame(
                corpus[number], number: UInt32(number), at: t)
            harness.core.tick(now: ClientTimestamp(microseconds: t))
        }
    }

    // MARK: - Past-parity loss → NACK → repair → byte-exact

    func testNackDrawsRepairAndFrameCompletesByteExact() throws {
        let corpus = try loadCorpus(4)
        let host = SystemHostSession()
        let harness = try SystemClient(host: host)
        var t: UInt64 = 1_000
        var forwarded = 0
        // Frame 0's clean report ends the opening-IDR exemption, so frame
        // 1 must pass the normal SRTT + freeze-budget judgement.
        let hole = try openHole(
            corpus: corpus, host: host, harness: harness,
            t: &t, forwarded: &forwarded, reportingFrame0: true)
        XCTAssertGreaterThanOrEqual(
            host.session.counters.feedbackReportsParsed, 1)
        let (frame1, geometry1, dropped) =
            (hole.frame, hole.geometry, hole.dropped)
        let dropCount = dropped.count

        // Follow-on frames advance the channel's highest seq: the
        // presumption crosses packet-threshold 3, the verdict goes past
        // parity, and the ask leaves in an out-of-cadence report.
        try deliverFollowOns(2...3, corpus: corpus, harness: harness, t: &t)

        // The untouched sealed chan-3 report enters the shipping Session,
        // which parses and judges it before its own VideoChannel answers.
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        let repairEvents = host.events.compactMap { event -> Int? in
            guard case .repairEnqueued(let frame, let shards) = event,
                  frame.rawValue == 1 else { return nil }
            return shards
        }
        XCTAssertFalse(repairEvents.isEmpty,
                       "the real Session must honor the client report")
        XCTAssertEqual(repairEvents.reduce(0, +), dropCount)

        t += 8_000; harness.clock.advance(to: t)
        let repairs = host.takeRepairDatagrams()
        let originalEnvelopes = try Dictionary(
            uniqueKeysWithValues: frame1.map { datagram in
                let (envelope, _) = try Envelope.decode(datagram)
                guard case .reedSolomon(let index, _) =
                    try FecField.decode(envelope.fec) else {
                    throw NSError(
                        domain: "NackRepairClientGateTests",
                        code: 2
                    )
                }
                return (index, envelope)
            }
        )
        let maxOriginalSeq = try XCTUnwrap(
            originalEnvelopes.values.map(\.seq.rawValue).max()
        )
        for repair in repairs {
            let (envelope, _) = try Envelope.decode(repair)
            guard case .reedSolomon(let index, let repairGeometry) =
                try FecField.decode(envelope.fec) else {
                return XCTFail("repair did not retain RS geometry")
            }
            let original = try XCTUnwrap(originalEnvelopes[index])
            XCTAssertTrue(dropped.contains(Int(index)))
            XCTAssertEqual(envelope.frame.rawValue, 1)
            XCTAssertEqual(repairGeometry, geometry1)
            XCTAssertEqual(envelope.fec, original.fec)
            XCTAssertEqual(envelope.timestamp, original.timestamp)
            XCTAssertGreaterThan(envelope.seq.rawValue, maxOriginalSeq)
        }
        for datagram in repairs { harness.deliver(datagram, at: t) }
        harness.core.tick(now: ClientTimestamp(microseconds: t))

        // The frame healed byte-exact through the real receive path,
        // in frame order, and the IDR path never fired.
        XCTAssertEqual(harness.samples.map(\.frameNumber.rawValue),
                       [0, 1, 2, 3])
        XCTAssertEqual(harness.samples[1].annexB, corpus[1],
                       "the repaired frame must be byte-identical")
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertEqual(host.session.counters.idrRequests, 0,
                       "repair healed the frame — no IDR")

        let stats = harness.core.nackStats
        XCTAssertEqual(stats.pastParityFrames, 1)
        XCTAssertGreaterThanOrEqual(stats.shardsAsked, UInt64(dropCount))
        XCTAssertEqual(host.session.counters.repairDatagramsEnqueued, dropCount,
                       "every asked shard rode exactly one repair")
        XCTAssertEqual(repairs.count, dropCount)
        XCTAssertGreaterThanOrEqual(host.session.counters.nacksHonored, 1)
        XCTAssertEqual(host.session.counters.nacksJudgedStale, 0)
        XCTAssertEqual(
            host.session.counters.openingExemptRepairsHonored,
            0,
            "the clean opening report must force normal SRTT judgement"
        )
        // The group decodes the moment missing-data ≤ present-parity:
        // with parity+2 data shards dropped and all parity in hand,
        // exactly TWO repairs slot in before RS completes and the frame
        // emits — the REST of the batch lands after the frame's turn
        // has passed, and the books call those answers LATE (the frame
        // decoded; they were unneeded), never a corruption.
        let needed = UInt64(dropCount - geometry1.parityShards)
        XCTAssertEqual(stats.repairShardsReceived, needed)
        XCTAssertEqual(stats.framesCompletedByRepair, 1)
        XCTAssertEqual(stats.asksSuppressedStale, 0)
        XCTAssertEqual(stats.framesEscalatedToIdr, 0)
        XCTAssertEqual(stats.repairsLate, UInt64(geometry1.parityShards))
        XCTAssertEqual(stats.repairsDuplicate, 0)
        XCTAssertEqual(stats.repairsSuperseded, 0)
        let pipeline = harness.core.pipeline.snapshotStats()
        XCTAssertEqual(pipeline.repairShardsAccepted, needed)
    }

    // MARK: - Stale frame → no NACK, IDR instead

    func testStaleFrameDrawsNoNackAndFallsBackToIdr() throws {
        let corpus = try loadCorpus(4)
        let host = SystemHostSession()
        // A tightened budget stands in for a slow path: with the frame
        // 150 ms old at verdict time, the 100 ms budget refuses the ask.
        var config = LyteUdpSessionCoreConfig()
        config.nackPolicy = ClientNackPolicy.Config(
            staleBudgetMicroseconds: 100_000)
        let harness = try SystemClient(host: host, coreConfig: config)

        var t: UInt64 = 1_000
        try harness.deliverFrame(corpus[0], number: 0, at: t)

        // Frame 1 arrives holed (one survivor short of the geometry),
        // then the wire goes quiet: the frame AGES past the budget
        // before any follow-on traffic renders the verdict.
        t += 5_000
        let probe = try host.videoDatagrams(
            annexB: corpus[1], frameNumber: 1, hostMicros: t)
        // Deliver ONLY the first shard: the group opens, everything
        // else is in flight as far as presumption knows.
        harness.deliver(probe[0], at: t)

        // 150 ms of silence — under the assembler's 250 ms eviction,
        // over the policy's 100 ms budget.
        t += 150_000
        for number in 2...3 {
            try harness.deliverFrame(
                corpus[number], number: UInt32(number), at: t)
        }
        harness.core.tick(now: ClientTimestamp(microseconds: t))
        // The cadence beat flushes the coalesced IDR request.
        harness.core.feedback.tick(now: ClientTimestamp(microseconds: t))

        var forwarded = 0
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertEqual(host.session.counters.nackEntriesReceived, 0,
                       "a stale frame must not be asked for")
        XCTAssertGreaterThanOrEqual(host.session.counters.idrRequests, 1,
                                    "staleness is answered with the IDR")
        let stats = harness.core.nackStats
        XCTAssertEqual(stats.asksSuppressedStale, 1)
        XCTAssertEqual(stats.shardsAsked, 0)
        XCTAssertEqual(stats.fecImpossibleDeferred, 0,
                       "an unasked frame's verdict must not defer")
        XCTAssertTrue(harness.recoveryDemands.contains {
            $0.0 == .fecAssemblerDamage
        })
    }

    func testAcceptedIrapClosesOutstandingRecoveryEpisode() throws {
        let corpus = try loadCorpus(2)
        let host = SystemHostSession()
        let harness = try SystemClient(host: host)
        var forwarded = 0
        let base: UInt64 = 1_000

        // Establish the decoder before damage.
        try harness.deliverFrame(corpus[0], number: 0, at: base)
        XCTAssertEqual(harness.samples.count, 1)

        // Multiple independent damage exits converge on one request.
        harness.clock.advance(to: base)
        harness.core.requestVideoRecovery(
            after: FrameNumber(rawValue: 10), cause: .fecAssemblerDamage)
        harness.clock.advance(to: base + 100_000)
        harness.core.requestVideoRecovery(
            after: FrameNumber(rawValue: 11), cause: .fecAssemblerDamage)
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertEqual(host.session.counters.idrRequests, 1)
        XCTAssertTrue(harness.core.idrStats.recoveryOutstanding)

        // An already-built dependent P frame cannot cross the core's render
        // seam while that episode is outstanding.
        try harness.deliverFrame(corpus[1], number: 1, at: base + 150_000)
        XCTAssertEqual(harness.samples.count, 1)
        XCTAssertTrue(harness.recoveryTrace.contains {
            $0.kind == "coreRejectedNonIrap"
                && $0.frame.rawValue == 1
        })

        // Assembly alone cannot close the episode.
        try harness.deliverFrame(corpus[0], number: 2, at: base + 200_000)
        XCTAssertEqual(harness.samples.count, 2)
        XCTAssertTrue(harness.samples[1].isIDR)
        XCTAssertTrue(harness.recoveryTrace.contains {
            $0.kind == "coreForwardedIrap"
                && $0.frame.rawValue == 2
        })
        XCTAssertTrue(harness.core.idrStats.recoveryOutstanding)
        harness.core.noteVideoIrapEnqueued(
            frame: FrameNumber(rawValue: 2))
        XCTAssertFalse(harness.core.idrStats.recoveryOutstanding)
        XCTAssertTrue(harness.recoveryTrace.contains {
            $0.kind == "coreRecoveryClosedAfterIrapEnqueue"
                && $0.frame.rawValue == 2
        })

        // No retry survives the accepted IRAP. A later fresh break still
        // gets its first request immediately.
        harness.clock.advance(to: base + 800_000)
        harness.core.feedback.tick(
            now: ClientTimestamp(microseconds: base + 800_000))
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertEqual(host.session.counters.idrRequests, 1)
        harness.clock.advance(to: base + 800_001)
        harness.core.requestVideoRecovery(
            after: FrameNumber(rawValue: 12), cause: .fecAssemblerDamage)
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertEqual(host.session.counters.idrRequests, 2)
    }

    // MARK: - A seeded SimNet storm heals through the ask loop

    func testStormLossHealsThroughNackRepairLoop() throws {
        let corpus = try loadCorpus(5)
        let host = SystemHostSession()
        let harness = try SystemClient(host: host)
        var net = SimNet(
            config: SimNetConfig(
                lossRate: 0.12,
                baseDelayMicroseconds: 3_000,
                jitterMicroseconds: 1_500),
            seed: 0xC1_12
        )

        // 20 frames (corpus cycled, ascending numbers) at 12% loss;
        // the host honors every ask it can still see. Client→host
        // rides clean (the return path isn't under test here — the
        // report loss story is rule 4's, covered by Client's policy gates).
        var forwardedToHost = 0
        var frameBytes: [UInt32: [UInt8]] = [:]
        var nextFrame: UInt32 = 0
        var lastFeedbackAt: UInt64 = 0
        var t: UInt64 = 1_000
        try harness.settleStartup(forwarded: &forwardedToHost, at: t)

        while t <= 1_400_000 {
            harness.clock.advance(to: t)

            // A new frame every 16 ms until 20 are out.
            if nextFrame < 20, t >= 1_000 + UInt64(nextFrame) * 16_000 {
                let annexB = corpus[Int(nextFrame) % corpus.count]
                frameBytes[nextFrame] = annexB
                for datagram in try host.videoDatagrams(
                    annexB: annexB, frameNumber: nextFrame, hostMicros: t
                ) {
                    net.send(from: 1, bytes: datagram, now: t)
                }
                nextFrame += 1
            }

            for delivery in net.deliveries(upTo: t)
            where delivery.destination == 0 {
                harness.deliver(delivery.bytes, at: t)
            }

            // Feedback cadence (30 ms) + the policy's own flushes.
            if t - lastFeedbackAt >= 30_000 {
                lastFeedbackAt = t
                harness.core.feedback.tick(
                    now: ClientTimestamp(microseconds: t))
            }
            harness.core.tick(now: ClientTimestamp(microseconds: t))

            // The client's sealed sends reach the real Session directly;
            // its repairs and explicit refusals return through the same
            // lossy host→client network as fresh video.
            try harness.pumpOutboundToHost(forwarded: &forwardedToHost)
            for datagram in host.takeRepairDatagrams()
                + host.takeControlDatagrams(maxAdvanceNS: 1_000_000) {
                net.send(from: 1, bytes: datagram, now: t)
            }

            t += 2_000
        }

        // Every DELIVERED frame is byte-identical to its source: integrity
        // held through loss and repair.
        XCTAssertGreaterThan(harness.samples.count, 10)
        for unit in harness.samples {
            XCTAssertEqual(unit.annexB, frameBytes[unit.frameNumber.rawValue],
                           "frame \(unit.frameNumber.rawValue) corrupt")
        }
        // The storm produced past-parity frames and the loop healed at
        // least one of them via repair (seed-pinned).
        let stats = harness.core.nackStats
        XCTAssertGreaterThan(stats.pastParityFrames, 0,
                             "12% loss must push frames past parity")
        XCTAssertGreaterThan(stats.repairShardsReceived, 0)
        XCTAssertGreaterThan(stats.framesCompletedByRepair, 0,
                             "the ask loop must heal frames FEC couldn't")
        XCTAssertEqual(
            host.session.counters.nackEntriesReceived,
            Int(stats.nackEntriesEmitted),
            "every client NACK entry must reach the real Session once"
        )
        XCTAssertLessThanOrEqual(stats.framesCompletedByRepair,
                                 stats.pastParityFrames)
    }

    // MARK: - Answers after stragglers already fixed the frame

    /// The task the books exist for: the presumption goes past parity
    /// and the ask leaves, but the "lost" originals were merely
    /// reordered — they straggle in and complete the frame before any
    /// repair lands. Every answer the host then sends must be a clean
    /// no-op counted LATE: no double delivery, no corruption, no
    /// repair-acceptance bookkeeping.
    func testAnswersAfterStragglerHealAreCountedLateAndChangeNothing() throws {
        let corpus = try loadCorpus(3)
        let host = SystemHostSession()
        let harness = try SystemClient(host: host)

        var t: UInt64 = 1_000
        var forwarded = 0
        // Frame 1's parity+2 "lost" shards are only held for later.
        let hole = try openHole(
            corpus: corpus, host: host, harness: harness,
            t: &t, forwarded: &forwarded)

        // ONE follow-on frame renders the past-parity verdict; the ask
        // leaves. (Just one, deliberately: the ~23-shard corpus frames
        // mean a second would push the stragglers past the 64-seq
        // replay window and the demux — correctly — would eat them
        // before this test's seam is ever exercised.)
        try deliverFollowOns(2...2, corpus: corpus, harness: harness, t: &t)
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        let repairs = host.takeRepairDatagrams()
        XCTAssertFalse(repairs.isEmpty)

        // TWO stragglers arrive — exactly enough for RS to complete —
        // and the frame emits byte-exact before any repair shows up.
        t += 3_000
        for datagram in hole.held.prefix(2) { harness.deliver(datagram, at: t) }
        XCTAssertEqual(harness.samples.map(\.frameNumber.rawValue),
                       [0, 1, 2])
        XCTAssertEqual(harness.samples[1].annexB, corpus[1])

        // The host honors the full ask anyway; every answer lands after
        // the frame's turn has passed.
        t += 5_000
        for datagram in repairs { harness.deliver(datagram, at: t) }
        harness.core.tick(now: ClientTimestamp(microseconds: t))

        // No re-delivery, no corruption — and the books call every
        // answer late.
        XCTAssertEqual(harness.samples.map(\.frameNumber.rawValue),
                       [0, 1, 2], "a late answer must never re-deliver")
        let stats = harness.core.nackStats
        XCTAssertEqual(stats.pastParityFrames, 1)
        XCTAssertEqual(stats.repairsLate, UInt64(repairs.count))
        XCTAssertEqual(stats.repairsDuplicate, 0)
        XCTAssertEqual(stats.repairsSuperseded, 0)
        XCTAssertEqual(stats.repairShardsReceived, 0,
                       "nothing was ACCEPTED — the frame never needed it")
        XCTAssertEqual(stats.framesCompletedByRepair, 0)
        XCTAssertEqual(stats.framesEscalatedToIdr, 0,
                       "the frame completed — rule 4 must stay quiet")
        XCTAssertEqual(
            harness.core.pipeline.snapshotStats().repairShardsAccepted, 0)
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertEqual(host.session.counters.idrRequests, 0)
    }

    // MARK: - Answers for an abandoned frame count superseded

    /// The give-up story: an asked frame gets skipped by the holdback
    /// (newer decoded frames pile up behind it), rule 4 escalates it to
    /// the IDR requester, and every answer that still arrives is a
    /// counted no-op — SUPERSEDED, never rendered, never corrupting.
    func testAnswersForSupersededFrameCountAndAsksStop() throws {
        let corpus = try loadCorpus(5)
        let host = SystemHostSession()
        let harness = try SystemClient(host: host)

        var t: UInt64 = 1_000
        var forwarded = 0
        // Frame 1 holed past parity; the ask leaves on the follow-on
        // traffic.
        _ = try openHole(
            corpus: corpus, host: host, harness: harness,
            t: &t, forwarded: &forwarded)

        // Three decoded frames pile up behind the hole — the holdback
        // (3) skips frame 1 the moment frame 4 decodes, and the skip
        // escalates the asked frame to the IDR requester (rule 4 via
        // the frame's death, not the deadline).
        try deliverFollowOns(2...4, corpus: corpus, harness: harness, t: &t)
        harness.core.feedback.tick(now: ClientTimestamp(microseconds: t))
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        let repairs = host.takeRepairDatagrams()
        XCTAssertFalse(repairs.isEmpty,
                       "the ask must have left before the skip")
        XCTAssertEqual(harness.samples.map(\.frameNumber.rawValue),
                       [0],
                       "frame 1 skipped; dependent P frames stay fenced")
        XCTAssertGreaterThanOrEqual(host.session.counters.idrRequests, 1,
                                    "the abandoned ask escalates to IDR")

        // The host's answers arrive anyway — for a frame that no
        // longer exists anywhere in the client.
        t += 5_000
        for datagram in repairs { harness.deliver(datagram, at: t) }
        harness.core.tick(now: ClientTimestamp(microseconds: t))

        XCTAssertEqual(harness.samples.map(\.frameNumber.rawValue),
                       [0],
                       "an answer for a dead frame must change nothing")
        let stats = harness.core.nackStats
        XCTAssertEqual(stats.repairsSuperseded,
                       UInt64(repairs.count))
        XCTAssertGreaterThan(stats.repairsSuperseded, 0)
        XCTAssertEqual(stats.repairsLate, 0)
        XCTAssertEqual(stats.repairsDuplicate, 0)
        XCTAssertEqual(stats.repairShardsReceived, 0)
        XCTAssertEqual(stats.framesEscalatedToIdr, 1)
        XCTAssertEqual(
            harness.core.pipeline.snapshotStats().repairShardsAccepted, 0)
        // And the asking stopped after the frame's book settled.
        let entriesBefore = host.session.counters.nackEntriesReceived
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertEqual(
            host.session.counters.nackEntriesReceived,
            entriesBefore,
            "a settled frame must never be re-asked"
        )
    }

    // MARK: - An explicit refusal ends the wait now

    func testHostRefusalEndsRepairWaitImmediately() throws {
        let corpus = try loadCorpus(4)
        let host = SystemHostSession {
            $0.repairFreezeBudgetOverrideNS = 1_000_000
        }
        let harness = try SystemClient(host: host)

        var t: UInt64 = 1_000
        var forwarded = 0
        // Frame 1 goes past parity; follow-ons render the verdict and the
        // ask leaves in an out-of-cadence report.
        _ = try openHole(
            corpus: corpus, host: host, harness: harness,
            t: &t, forwarded: &forwarded, reportingFrame0: true)
        try deliverFollowOns(2...3, corpus: corpus, harness: harness, t: &t)
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertTrue(host.events.contains {
            guard case .nackJudgedStale(let frame, let reason) = $0 else {
                return false
            }
            return frame.rawValue == 1 && reason == .budgetExceeded
        }, "the real Session must judge the delayed ask stale")
        let refusalCount = host.session.counters.repairRefusalsSent
        XCTAssertGreaterThan(refusalCount, 0)
        XCTAssertEqual(
            host.session.counters.nackEntriesReceived,
            refusalCount,
            "each split ask is judged and explicitly refused"
        )
        XCTAssertTrue(host.takeRepairDatagrams().isEmpty)
        XCTAssertEqual(host.session.counters.idrRequests, 0)

        // The Session's real sealed 0x23 lands 5 ms later, far inside
        // the 250 ms deadline the client used to burn whole.
        t += 5_000; harness.clock.advance(to: t)
        let controlFlight = host.takeControlDatagrams(
            maxAdvanceNS: 1_000_000
        )
        XCTAssertGreaterThanOrEqual(controlFlight.count, refusalCount)
        for datagram in controlFlight { harness.deliver(datagram, at: t) }
        harness.core.feedback.tick(now: ClientTimestamp(microseconds: t))
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertGreaterThanOrEqual(
            host.session.counters.idrRequests, 1,
            "the refusal goes straight to the IDR path — no deadline burned")
        let stats = harness.core.nackStats
        XCTAssertEqual(stats.refusalsReceived, UInt64(refusalCount))
        XCTAssertEqual(stats.refusalsActedOn, 1)
        XCTAssertEqual(
            stats.refusalsIgnored,
            UInt64(refusalCount - 1),
            "later refusals for the settled ask are harmless"
        )
        XCTAssertEqual(stats.framesEscalatedToIdr, 0,
                       "refusal-acted is its own book, not a deadline expiry")
        XCTAssertTrue(harness.notes.contains {
            $0.contains("repair refused") && $0.contains("staleBudget")
        }, "the refusal is loud in the protocol notes")
    }
}
