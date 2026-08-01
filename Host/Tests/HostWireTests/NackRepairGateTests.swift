import XCTest
import HostCore
import HostWire
import LyteWire
import LyteWireTestKit

// THE GATE (build plan HS-17 row: "Congestion II: NACK responder
// (≥4 s rings), per-frame adaptive FEC — client NACKs honored, closes
// §4.7"). Pinned behaviors, each a leg below:
//
//   • REPAIR ROUND TRIP: a NACK naming shards FEC could not recover
//     (missing > parity) draws exactly those shards back as FRESH
//     datagrams — fresh seqs (the W3/W9 rule), original frame number,
//     fec field, capture timestamp, byte-identical payloads — on the
//     `.videoTail` class (the overview's unified priority order), and
//     the union of survivors + repairs loop-decodes to the original
//     Annex-B byte-exact;
//   • STALENESS VERDICTS (resiliency §1.1 rules 3–4): a frame older
//     than the last IDR is refused dead (no repair, no IDR — the IDR
//     already re-anchored the chain) while the IDR itself stays
//     repairable; a NACK whose SRTT + retransmit serialization no
//     longer fit the remaining freeze budget (2 frame intervals —
//     Work mode has no video jitter buffer) is answered with the IDR
//     alternative through the SAME coalesced keyframe latch client
//     0x10 requests pull; no RTT evidence means no honest promise, so
//     the gate refuses; an evicted frame is unavailable → IDR; one
//     attempt per shard, ever — no retransmission of retransmissions;
//     a closed session suppresses repairs entirely;
//   • THE ≥4 s RING: the repair store evicts by age and by byte cap,
//     oldest first;
//   • POST-FEC LOSS → THE ESTIMATOR (HS-16's named seam): NACK
//     evidence over the rolling window past 2% (rung 3) downshifts
//     the rate — NOT held like the pre-FEC 2–10% band, because this
//     is precisely the loss FEC failed to absorb — and steps the
//     §5.2 FEC regime clean → lossy at the packetizing seam
//     (per-frame: the next frame carries the lossy column's parity);
//     a sustained quiet stretch steps it back; NACK evidence inside a
//     RECOVERY feedback window honestly holds RECOVERY;
//   • THE CADENCE GATE (R-G8's shape under a repair storm): 5 s of
//     virtual time — 5 ms audio, 60 fps damage, a worst-case IDR
//     every 2 s, and a NACK against every fresh frame with repairs
//     flowing throughout — audio inter-send holds 5 ms ± 2 ms at p99,
//     structurally (audio outranks videoTail) and now proven.

final class NackRepairGateTests: XCTestCase {

    private static let ceiling = 20_000_000
    private static let ms: UInt64 = 1_000_000

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_071,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    // MARK: Harness

    private final class Box {
        var sent: [(at: UInt64, datagram: VideoChannelDatagram)] = []
        var sendInstant: UInt64 = 0

        func tail() -> [VideoChannelDatagram] {
            sent.filter { $0.datagram.pacerClass == .videoTail }
                .map(\.datagram)
        }

        func fresh() -> [VideoChannelDatagram] {
            sent.filter { $0.datagram.pacerClass == .freshVideo }
                .map(\.datagram)
        }
    }

    private func makeSession(
        box: Box, seed: UInt64 = 0x1701,
        tweak: (inout SessionConfig) -> Void = { _ in }
    ) -> Session {
        var config = SessionConfig(
            crypto: .insecure, rateBitsPerSecond: Self.ceiling
        )
        tweak(&config)
        return Session(
            config: config,
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: seed)
        ) { [box] datagram in
            box.sent.append((box.sendInstant, datagram))
        }
    }

    /// Services wakes (pacer batches, ARQ PTOs, beacons) up to the
    /// horizon, stamping each send with its emission instant.
    private func drain(
        _ session: Session, box: Box, until horizon: UInt64,
        now: inout UInt64
    ) {
        while let wake = session.nextWake(now: now), wake <= horizon {
            now = max(now &+ 1, wake)
            box.sendInstant = now
            _ = session.advance(now: now, hostMicroseconds: now / 1_000)
            session.pump(now: now)
        }
    }

    /// Answers the session-start beacon with one synthetic echo so the
    /// retransmit gate has SRTT evidence: 450 µs out + 450 µs back,
    /// 100 µs client turnaround → RTT 900 µs.
    private func establishSrtt(
        _ session: Session, box: Box, now: inout UInt64
    ) throws {
        box.sendInstant = now
        _ = session.advance(now: now, hostMicroseconds: now / 1_000)
        session.pump(now: now)
        // The capability declaration (ARQ-carried) shares the control
        // class — find the beacon by its own type byte.
        var beaconPayload: [UInt8]?
        for (_, datagram) in box.sent
        where datagram.pacerClass == .control {
            let (_, payload) = try Envelope.decode(datagram.bytes)
            if payload.first == CtrlMessageType.clockBeacon {
                beaconPayload = Array(payload)
            }
        }
        guard let beaconPayload else {
            return XCTFail("no session-start beacon on the first advance")
        }
        let beacon = try ClockBeacon.decode(beaconPayload)
        let t1 = beacon.hostSend.microseconds
        let clientOffset: UInt64 = 5_000_000_000
        let echo = BeaconEcho(
            beaconSeq: beacon.beaconSeq,
            hostSend: beacon.hostSend,
            clientReceive: ClientTimestamp(
                microseconds: t1 &+ clientOffset &+ 450
            ),
            clientSend: ClientTimestamp(
                microseconds: t1 &+ clientOffset &+ 550
            )
        )
        let envelope = Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 60_000),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
        )
        now = now &+ Self.ms
        _ = session.receive(
            try envelope.encode(payload: echo.encode()),
            from: Self.tupleA,
            now: now, hostMicroseconds: t1 &+ 1_000
        )
        XCTAssertEqual(session.srttMicroseconds, 900,
                       "the synthetic echo must seed SRTT")
    }

    /// A frame-shaped Annex-B blob with position-dependent bytes so a
    /// shard swap can never pass the byte-equality checks.
    private func syntheticFrame(
        byteCount: Int, irap: Bool = false
    ) -> [UInt8] {
        [0, 0, 0, 1, irap ? 0x26 : 0x02, 0x01]
            + (0..<(byteCount - 6)).map {
                UInt8(truncatingIfNeeded: $0 &* 131 &+ 7)
            }
    }

    private var feedbackSeq: UInt16 = 0

    /// Wraps a report in a chan-3 envelope and feeds it in (insecure
    /// mode: payload passthrough).
    private func feed(
        _ session: Session,
        report: FeedbackReport,
        now: UInt64
    ) throws -> [SessionEvent] {
        let envelope = Envelope(
            channel: .feedback,
            seq: ChannelSeq(rawValue: feedbackSeq),
            frame: FrameNumber(rawValue: 0),
            timestamp: now / 1_000,
            fec: 0
        )
        feedbackSeq &+= 1
        return session.receive(
            try envelope.encode(payload: report.encode()),
            from: Self.tupleA, now: now, hostMicroseconds: now / 1_000
        )
    }

    private func nackReport(
        frame: UInt32, shards: [UInt8], clientMicros: UInt64,
        channels: [FeedbackReport.ChannelStats] = []
    ) throws -> FeedbackReport {
        FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: clientMicros),
            channels: channels,
            nacks: [try FeedbackReport.NackEntry(
                frame: FrameNumber(rawValue: frame), missingShards: shards
            )]
        )
    }

    private func shardsByIndex(
        _ datagrams: [VideoChannelDatagram], frame: UInt32
    ) throws -> (
        byIndex: [UInt8: (envelope: Envelope, payload: [UInt8])],
        geometry: FecGeometry?
    ) {
        var byIndex: [UInt8: (envelope: Envelope, payload: [UInt8])] = [:]
        var geometry: FecGeometry?
        for datagram in datagrams
        where datagram.frameNumber.rawValue == frame {
            let (envelope, payload) = try Envelope.decode(datagram.bytes)
            guard case .reedSolomon(let index, let geo) =
                try FecField.decode(envelope.fec) else {
                XCTFail("video shard without an RS fec field")
                continue
            }
            byIndex[index] = (envelope, Array(payload))
            geometry = geo
        }
        return (byIndex, geometry)
    }

    // MARK: Leg 1 — repair round trip heals what FEC cannot

    func testGateRepairRoundTripHealsWhatFecCannot() throws {
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = 0
        try establishSrtt(session, box: box, now: &now)

        // One 30 KB frame: k = 28 data shards + 5 parity (clean 15%).
        let annexB = syntheticFrame(byteCount: 30_000)
        box.sendInstant = now
        let shardCount = try session.ingestVideoFrame(
            annexB, captureTimestampMicroseconds: now / 1_000,
            isKeyframe: false, now: now
        )
        drain(session, box: box, until: now + 20 * Self.ms, now: &now)

        let originals = box.fresh()
        XCTAssertEqual(originals.count, shardCount)
        let (byIndex, geo) = try shardsByIndex(originals, frame: 0)
        let geometry = try XCTUnwrap(geo)
        XCTAssertEqual(byIndex.count, geometry.totalShards)

        // Lose SIX data shards — one past the 5-parity best case:
        // FEC-impossible, the NACK's whole reason to exist.
        let lost: [UInt8] = [0, 3, 9, 14, 20, 27]
        XCTAssertGreaterThan(lost.count, geometry.parityShards)

        let events = try feed(
            session,
            report: nackReport(
                frame: 0, shards: lost, clientMicros: now / 1_000
            ),
            now: now
        )
        XCTAssertTrue(events.contains(.repairEnqueued(
            frame: FrameNumber(rawValue: 0), shards: lost.count
        )), "an in-budget NACK for a live frame must be honored")
        drain(session, box: box, until: now + 10 * Self.ms, now: &now)

        // ── The repairs: fresh datagrams, original interior ─────────
        let repairs = box.tail()
        XCTAssertEqual(repairs.count, lost.count)
        let maxOriginalSeq = originals.map(\.seq.rawValue).max()!
        var repairedSlots = [[UInt8]?](
            repeating: nil, count: geometry.totalShards
        )
        for repair in repairs {
            let (envelope, payload) = try Envelope.decode(repair.bytes)
            guard case .reedSolomon(let index, let repairGeo) =
                try FecField.decode(envelope.fec) else {
                return XCTFail("repair without an RS fec field")
            }
            XCTAssertTrue(lost.contains(index),
                          "repair named an un-NACKed shard")
            XCTAssertEqual(repairGeo, geometry,
                           "the fec field rides verbatim")
            XCTAssertEqual(envelope.frame.rawValue, 0)
            XCTAssertGreaterThan(envelope.seq.rawValue, maxOriginalSeq,
                                 "a retransmit is a FRESH datagram (W3/W9)")
            let original = try XCTUnwrap(byIndex[index])
            XCTAssertEqual(Array(payload), original.payload,
                           "repair payload must be byte-identical")
            XCTAssertEqual(envelope.timestamp, original.envelope.timestamp,
                           "capture stamp rides verbatim")
            repairedSlots[Int(index)] = Array(payload)
        }

        // ── Survivors + repairs loop-decode byte-exact ──────────────
        var slots = repairedSlots
        for (index, shard) in byIndex where !lost.contains(index) {
            slots[Int(index)] = shard.payload
        }
        let decoded = try FecDecoder.decode(
            shards: slots, geometry: geometry
        )
        XCTAssertEqual(decoded, annexB,
                       "the healed frame must be byte-identical")

        XCTAssertEqual(session.counters.nacksHonored, 1)
        XCTAssertEqual(session.counters.repairDatagramsEnqueued, lost.count)
        XCTAssertFalse(session.takeFreshKeyframeRequest(),
                       "an honored NACK must not arm an IDR")

        // ── One attempt, ever (rule 3) ──────────────────────────────
        let again = try feed(
            session,
            report: nackReport(
                frame: 0, shards: lost, clientMicros: now / 1_000 + 100
            ),
            now: now
        )
        XCTAssertTrue(again.contains(.nackJudgedStale(
            frame: FrameNumber(rawValue: 0), reason: .alreadyRepaired
        )), "no retransmission of retransmissions")
        drain(session, box: box, until: now + 5 * Self.ms, now: &now)
        XCTAssertEqual(box.tail().count, lost.count,
                       "the re-NACK must add nothing to the wire")
        XCTAssertFalse(session.takeFreshKeyframeRequest(),
                       "in-flight repairs must not be doubled by an IDR")

        print("HS-17 gate leg 1: \(lost.count) shards past parity healed "
            + "byte-exact via videoTail repairs (fresh seqs > "
            + "\(maxOriginalSeq)); re-NACK refused")
    }

    // MARK: Leg 2 — staleness verdicts

    func testNackOlderThanLastIdrRefusedDeadButIdrItselfRepairable() throws {
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = 0
        try establishSrtt(session, box: box, now: &now)

        box.sendInstant = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 8_000),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: false, now: now
        )
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 12_000, irap: true),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: true, now: now
        )
        drain(session, box: box, until: now + 15 * Self.ms, now: &now)

        // Frame 0 predates the IDR (frame 1): dead reference.
        let dead = try feed(
            session,
            report: nackReport(frame: 0, shards: [0],
                               clientMicros: now / 1_000),
            now: now
        )
        XCTAssertTrue(dead.contains(.nackJudgedStale(
            frame: FrameNumber(rawValue: 0), reason: .olderThanIdr
        )))
        XCTAssertFalse(session.takeFreshKeyframeRequest(),
                       "the newer IDR is the heal — no fresh IDR owed")
        drain(session, box: box, until: now + 5 * Self.ms, now: &now)
        XCTAssertTrue(box.tail().isEmpty)

        // The IDR itself stays repairable (§5.2's burst-loss rationale).
        let idrRepair = try feed(
            session,
            report: nackReport(frame: 1, shards: [0, 1],
                               clientMicros: now / 1_000 + 100),
            now: now
        )
        XCTAssertTrue(idrRepair.contains(.repairEnqueued(
            frame: FrameNumber(rawValue: 1), shards: 2
        )))
        drain(session, box: box, until: now + 5 * Self.ms, now: &now)
        XCTAssertEqual(box.tail().count, 2)
        XCTAssertTrue(box.tail().allSatisfy(\.isKeyframe))
    }

    func testNackPastFreezeBudgetArmsTheCoalescedIdrLatch() throws {
        let box = Box()
        // Pin the HS-17 constant via the HS-32 override: this leg
        // tests the refusal behavior, not the derivation (which has
        // its own legs below).
        let session = makeSession(box: box) {
            $0.repairFreezeBudgetOverrideNS = 33_333_333
        }
        var now: UInt64 = 0
        try establishSrtt(session, box: box, now: &now)

        box.sendInstant = now
        let ingestedAt = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 8_000),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: false, now: now
        )
        drain(session, box: box, until: now + 10 * Self.ms, now: &now)

        // 50 ms later: past the overridden 33.3 ms freeze budget.
        now = ingestedAt + 50 * Self.ms
        let events = try feed(
            session,
            report: nackReport(frame: 0, shards: [0, 1],
                               clientMicros: now / 1_000),
            now: now
        )
        XCTAssertTrue(events.contains(.nackJudgedStale(
            frame: FrameNumber(rawValue: 0), reason: .budgetExceeded
        )))
        drain(session, box: box, until: now + 5 * Self.ms, now: &now)
        XCTAssertTrue(box.tail().isEmpty,
                      "a repair that cannot beat the freeze is not sent")
        XCTAssertTrue(session.takeFreshKeyframeRequest(),
                      "the stale verdict answers with the IDR alternative")
        XCTAssertFalse(session.takeFreshKeyframeRequest(),
                       "the latch is coalesced: one demand, one IDR")
        XCTAssertEqual(session.counters.idrArmedOnStaleNack, 1)
    }

    func testNackWithoutRttEvidenceIsRefused() throws {
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = Self.ms
        // Deliberately NO beacon echo: SRTT is nil.
        box.sendInstant = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 8_000),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: false, now: now
        )
        drain(session, box: box, until: now + 10 * Self.ms, now: &now)

        let events = try feed(
            session,
            report: nackReport(frame: 0, shards: [0],
                               clientMicros: now / 1_000),
            now: now
        )
        XCTAssertTrue(events.contains(.nackJudgedStale(
            frame: FrameNumber(rawValue: 0), reason: .budgetExceeded
        )), "no RTT evidence = no honest promise the repair lands")
        XCTAssertTrue(session.takeFreshKeyframeRequest())
    }

    func testNackForEvictedFrameIsUnavailableAndArmsIdr() throws {
        let box = Box()
        // Tight retention, roomy budget: isolate the eviction verdict.
        let session = makeSession(box: box) {
            $0.repairRetentionNS = 100 * Self.ms
            $0.repairFreezeBudgetOverrideNS = 10_000 * Self.ms
        }
        var now: UInt64 = 0
        try establishSrtt(session, box: box, now: &now)

        box.sendInstant = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 8_000),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: false, now: now
        )
        drain(session, box: box, until: now + 10 * Self.ms, now: &now)

        // 200 ms later a new frame's retention pass evicts frame 0.
        now += 200 * Self.ms
        box.sendInstant = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 8_000),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: false, now: now
        )
        drain(session, box: box, until: now + 10 * Self.ms, now: &now)

        let events = try feed(
            session,
            report: nackReport(frame: 0, shards: [0],
                               clientMicros: now / 1_000),
            now: now
        )
        XCTAssertTrue(events.contains(.nackJudgedStale(
            frame: FrameNumber(rawValue: 0), reason: .unavailable
        )))
        XCTAssertTrue(session.takeFreshKeyframeRequest())
    }

    func testGarbageUnknownFrameNacksArmAtMostOncePerInterval() throws {
        let box = Box()
        let session = makeSession(box: box) {
            $0.unknownFrameIdrArmIntervalNS = 1_000 * Self.ms
        }
        var now: UInt64 = 10 * Self.ms
        var armed = 0

        // An authenticated peer names a different impossible frame on
        // every 25 ms feedback beat. Verdicts/refusals still surface,
        // but only the first may pressure the encoder into an IDR.
        for i in 0..<40 {
            let events = try feed(
                session,
                report: nackReport(
                    frame: UInt32(0x8000_0000 + i), shards: [0],
                    clientMicros: now / 1_000
                ),
                now: now
            )
            XCTAssertTrue(events.contains(.nackJudgedStale(
                frame: FrameNumber(rawValue: UInt32(0x8000_0000 + i)),
                reason: .unavailable
            )))
            if session.takeFreshKeyframeRequest() { armed += 1 }
            now += 25 * Self.ms
        }
        XCTAssertEqual(armed, 1,
            "wire-cadence garbage NACKs forced repeated IDRs")
        XCTAssertEqual(session.counters.idrArmedOnStaleNack, 1)
        XCTAssertEqual(session.counters.unknownFrameIdrArmsThrottled, 39)

        // A legitimate later unknown-frame demand gets a fresh interval
        // and must still re-anchor the client.
        now = 1_011 * Self.ms
        _ = try feed(
            session,
            report: nackReport(
                frame: 7, shards: [0], clientMicros: now / 1_000
            ),
            now: now
        )
        XCTAssertTrue(session.takeFreshKeyframeRequest())
        XCTAssertEqual(session.counters.idrArmedOnStaleNack, 2)
    }

    func testNackAfterCloseIsSuppressed() throws {
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = 0
        try establishSrtt(session, box: box, now: &now)
        box.sendInstant = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 8_000),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: false, now: now
        )
        _ = session.beginTeardown(
            reason: .shuttingDown, now: now, hostMicroseconds: now / 1_000
        )
        let events = try feed(
            session,
            report: nackReport(frame: 0, shards: [0],
                               clientMicros: now / 1_000),
            now: now
        )
        XCTAssertTrue(events.contains(.nackJudgedStale(
            frame: FrameNumber(rawValue: 0), reason: .sendsSuppressed
        )), "closed sessions retransmit nothing")
        XCTAssertFalse(session.takeFreshKeyframeRequest())
    }

    // MARK: Leg 2b — HS-32: the derived budget, explicit refusals,
    // and the opening-IDR exemption

    /// One empty (parseable) report — cadence evidence only.
    private func feedCadenceReport(
        _ session: Session, now: UInt64
    ) throws {
        _ = try feed(
            session,
            report: FeedbackReport(
                clientTimestamp: ClientTimestamp(
                    microseconds: now / 1_000
                ),
                channels: [], nacks: []
            ),
            now: now
        )
    }

    /// Every 0x23 refusal on the control class, decoded off the wire.
    private func refusalsOnWire(_ box: Box) throws -> [RepairRefusal] {
        var out: [RepairRefusal] = []
        for (_, datagram) in box.sent
        where datagram.pacerClass == .control {
            let (_, payload) = try Envelope.decode(datagram.bytes)
            if payload.first == CtrlMessageType.repairRefused {
                out.append(try RepairRefusal.decode(Array(payload)))
            }
        }
        return out
    }

    func testFreezeBudgetDerivesFromObservedCadence() throws {
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = 0
        try establishSrtt(session, box: box, now: &now)
        // Before evidence: the 50 ms documented worst-case cadence.
        XCTAssertEqual(
            session.repairFreezeBudgetNS,
            UInt64(1.5 * 50_000_000) + 15_000_000,
            "pre-evidence budget = 1.5 × 50 ms worst case + 15 ms"
        )
        // Reports on the client's reference 40 ms cadence.
        for _ in 0..<4 {
            try feedCadenceReport(session, now: now)
            now += 40 * Self.ms
        }
        XCTAssertEqual(
            session.repairFreezeBudgetNS,
            UInt64(1.5 * 40_000_000) + 15_000_000,
            "budget = 1.5 × observed cadence + 15 ms jitter allowance"
        )
    }

    func testAskOnTheCadenceIsNowHonoredAndReAskStaysSilent() throws {
        // The HS-32 headline: an ask arriving 50 ms after the flight —
        // dead on arrival under HS-17's 33 ms constant BY CONSTRUCTION
        // (the ask itself rides the 40 ms feedback cadence) — is
        // inside the derived budget, and the repair actually flies.
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = 0
        try establishSrtt(session, box: box, now: &now)
        for _ in 0..<3 {
            try feedCadenceReport(session, now: now)
            now += 40 * Self.ms
        }
        box.sendInstant = now
        let flightAt = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 8_000),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: false, now: now
        )
        drain(session, box: box, until: now + 10 * Self.ms, now: &now)

        now = flightAt + 50 * Self.ms
        let events = try feed(
            session,
            report: nackReport(frame: 0, shards: [0, 1],
                               clientMicros: now / 1_000),
            now: now
        )
        XCTAssertTrue(events.contains(.repairEnqueued(
            frame: FrameNumber(rawValue: 0), shards: 2
        )), "the on-cadence ask is honored under the derived budget")
        drain(session, box: box, until: now + 5 * Self.ms, now: &now)
        XCTAssertEqual(box.tail().count, 2)
        XCTAssertEqual(session.counters.repairRefusalsSent, 0)
        XCTAssertFalse(session.takeFreshKeyframeRequest())

        // A re-ask for the same shards is alreadyRepaired — and stays
        // SILENT: the repairs may be in flight, and a refusal would
        // double-heal into an IDR.
        now += Self.ms
        let again = try feed(
            session,
            report: nackReport(frame: 0, shards: [0, 1],
                               clientMicros: now / 1_000),
            now: now
        )
        XCTAssertTrue(again.contains(.nackJudgedStale(
            frame: FrameNumber(rawValue: 0), reason: .alreadyRepaired
        )))
        drain(session, box: box, until: now + 5 * Self.ms, now: &now)
        XCTAssertTrue(try refusalsOnWire(box).isEmpty)
        XCTAssertEqual(session.counters.repairRefusalsSent, 0)
    }

    func testBudgetRefusalIsExplicitOnTheWire() throws {
        let box = Box()
        let session = makeSession(box: box) {
            $0.repairFreezeBudgetOverrideNS = 33_333_333
        }
        var now: UInt64 = 0
        try establishSrtt(session, box: box, now: &now)
        box.sendInstant = now
        let flightAt = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 8_000),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: false, now: now
        )
        drain(session, box: box, until: now + 10 * Self.ms, now: &now)

        now = flightAt + 50 * Self.ms
        _ = try feed(
            session,
            report: nackReport(frame: 0, shards: [0],
                               clientMicros: now / 1_000),
            now: now
        )
        drain(session, box: box, until: now + 5 * Self.ms, now: &now)
        XCTAssertEqual(try refusalsOnWire(box), [RepairRefusal(
            frame: FrameNumber(rawValue: 0), reason: .staleBudget
        )], "a budget refusal is explicit on the wire — 0x23")
        XCTAssertEqual(session.counters.repairRefusalsSent, 1)
        XCTAssertTrue(box.tail().isEmpty)
    }

    func testOlderThanIdrRefusalRidesSuperseded() throws {
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = 0
        try establishSrtt(session, box: box, now: &now)
        box.sendInstant = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 8_000),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: false, now: now
        )
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 12_000, irap: true),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: true, now: now
        )
        drain(session, box: box, until: now + 15 * Self.ms, now: &now)

        _ = try feed(
            session,
            report: nackReport(frame: 0, shards: [0],
                               clientMicros: now / 1_000),
            now: now
        )
        drain(session, box: box, until: now + 5 * Self.ms, now: &now)
        XCTAssertEqual(try refusalsOnWire(box), [RepairRefusal(
            frame: FrameNumber(rawValue: 0), reason: .superseded
        )], "older-than-IDR refuses dead but tells the client")
    }

    func testEvictedFrameRefusalRidesUnknownFrame() throws {
        let box = Box()
        let session = makeSession(box: box) {
            $0.repairRetentionNS = 100 * Self.ms
            $0.repairFreezeBudgetOverrideNS = 10_000 * Self.ms
        }
        var now: UInt64 = 0
        try establishSrtt(session, box: box, now: &now)
        box.sendInstant = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 8_000),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: false, now: now
        )
        drain(session, box: box, until: now + 10 * Self.ms, now: &now)
        now += 200 * Self.ms
        box.sendInstant = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 8_000),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: false, now: now
        )
        drain(session, box: box, until: now + 10 * Self.ms, now: &now)

        _ = try feed(
            session,
            report: nackReport(frame: 0, shards: [0],
                               clientMicros: now / 1_000),
            now: now
        )
        drain(session, box: box, until: now + 5 * Self.ms, now: &now)
        XCTAssertEqual(try refusalsOnWire(box), [RepairRefusal(
            frame: FrameNumber(rawValue: 0), reason: .unknownFrame
        )])
    }

    func testOpeningIdrExemptionRepairsBlackGlass() throws {
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = Self.ms
        // Deliberately NO SRTT: at session open the first beacon echo
        // may be up to a second away — the exemption must not need it.
        box.sendInstant = now
        let flightAt = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 12_000, irap: true),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: true, now: now
        )
        drain(session, box: box, until: now + 10 * Self.ms, now: &now)

        // 200 ms later — hopeless under ANY budget. Nothing has ever
        // reached the glass, so the last IDR is repairable regardless.
        now = flightAt + 200 * Self.ms
        let events = try feed(
            session,
            report: nackReport(frame: 0, shards: [0],
                               clientMicros: now / 1_000),
            now: now
        )
        XCTAssertTrue(events.contains(.repairEnqueued(
            frame: FrameNumber(rawValue: 0), shards: 1
        )), "black glass: the opening IDR repairs regardless of age")
        XCTAssertEqual(session.counters.openingExemptRepairsHonored, 1)
        drain(session, box: box, until: now + 5 * Self.ms, now: &now)
        XCTAssertEqual(box.tail().count, 1)
        XCTAssertTrue(box.tail().allSatisfy(\.isKeyframe))
        XCTAssertTrue(try refusalsOnWire(box).isEmpty)
    }

    func testOpeningExemptionIsAttemptAndByteBounded() throws {
        // Attempt bound.
        let box = Box()
        let session = makeSession(box: box) {
            $0.openingRepairMaxAttempts = 1
        }
        var now: UInt64 = Self.ms
        box.sendInstant = now
        let flightAt = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 12_000, irap: true),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: true, now: now
        )
        drain(session, box: box, until: now + 10 * Self.ms, now: &now)
        now = flightAt + 200 * Self.ms
        _ = try feed(
            session,
            report: nackReport(frame: 0, shards: [0],
                               clientMicros: now / 1_000),
            now: now
        )
        XCTAssertEqual(session.counters.openingExemptRepairsHonored, 1)
        now += Self.ms
        let second = try feed(
            session,
            report: nackReport(frame: 0, shards: [1],
                               clientMicros: now / 1_000),
            now: now
        )
        XCTAssertTrue(second.contains(.nackJudgedStale(
            frame: FrameNumber(rawValue: 0), reason: .budgetExceeded
        )), "the attempt bound holds — no congestion amplification")
        XCTAssertEqual(session.counters.openingExemptRepairsHonored, 1)

        // Byte bound.
        let box2 = Box()
        let session2 = makeSession(box: box2) {
            $0.openingRepairMaxBytes = 1
        }
        now = Self.ms
        box2.sendInstant = now
        let flightAt2 = now
        _ = try session2.ingestVideoFrame(
            syntheticFrame(byteCount: 12_000, irap: true),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: true, now: now
        )
        drain(session2, box: box2, until: now + 10 * Self.ms, now: &now)
        now = flightAt2 + 200 * Self.ms
        let asked = try feed(
            session2,
            report: nackReport(frame: 0, shards: [0],
                               clientMicros: now / 1_000),
            now: now
        )
        XCTAssertTrue(asked.contains(.nackJudgedStale(
            frame: FrameNumber(rawValue: 0), reason: .budgetExceeded
        )), "the byte bound holds")
        XCTAssertEqual(session2.counters.openingExemptRepairsHonored, 0)
    }

    func testGlassEvidenceEndsTheOpeningExemption() throws {
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = Self.ms
        box.sendInstant = now
        let flightAt = now
        let shardCount = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 12_000, irap: true),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: true, now: now
        )
        drain(session, box: box, until: now + 10 * Self.ms, now: &now)

        // The client reports clean receipt through the opening group:
        // a frame plausibly completed — the exemption dies for good.
        _ = try feed(
            session,
            report: FeedbackReport(
                clientTimestamp: ClientTimestamp(
                    microseconds: now / 1_000
                ),
                channels: [FeedbackReport.ChannelStats(
                    channel: .videoActive,
                    highestSeq: ChannelSeq(
                        rawValue: UInt16(shardCount - 1)
                    ),
                    received: UInt32(shardCount),
                    missing: 0,
                    duplicates: 0
                )],
                nacks: []
            ),
            now: now
        )

        now = flightAt + 200 * Self.ms
        let events = try feed(
            session,
            report: nackReport(frame: 0, shards: [0],
                               clientMicros: now / 1_000),
            now: now
        )
        XCTAssertTrue(events.contains(.nackJudgedStale(
            frame: FrameNumber(rawValue: 0), reason: .budgetExceeded
        )), "with glass evidence the normal budget gate governs")
        XCTAssertEqual(session.counters.openingExemptRepairsHonored, 0)
        drain(session, box: box, until: now + 5 * Self.ms, now: &now)
        XCTAssertEqual(try refusalsOnWire(box), [RepairRefusal(
            frame: FrameNumber(rawValue: 0), reason: .staleBudget
        )])
    }

    // MARK: Leg 3 — the ≥4 s ring's eviction laws (channel level)

    func testRepairStoreEvictsByAgeAndByteCapOldestFirst() throws {
        var sent: [VideoChannelDatagram] = []
        let channel = VideoChannel(
            config: VideoChannelConfig(
                rateBitsPerSecond: Self.ceiling,
                repairRetentionNS: 4_000_000_000,
                // One 9 KB frame stores 11,000 B (9 data + 2 parity
                // shards of 1,000 B): three frames burst this cap by
                // exactly one frame's worth.
                repairStoreByteCap: 25_000
            ),
            now: 0
        ) { sent.append($0) }

        func ingest(_ frame: UInt32, at now: UInt64) throws {
            _ = try channel.ingest(
                frame: syntheticFrame(byteCount: 9_000),
                frameNumber: FrameNumber(rawValue: frame),
                captureTimestampMicroseconds: now / 1_000,
                isKeyframe: false, now: now
            )
        }

        // Byte cap: the third 9 KB frame pushes the first out.
        try ingest(0, at: 0)
        try ingest(1, at: Self.ms)
        try ingest(2, at: 2 * Self.ms)
        XCTAssertNil(channel.repairAnchor(for: FrameNumber(rawValue: 0)),
                     "over the byte cap, the oldest frame goes first")
        XCTAssertNotNil(channel.repairAnchor(for: FrameNumber(rawValue: 1)))
        XCTAssertNotNil(channel.repairAnchor(for: FrameNumber(rawValue: 2)))
        XCTAssertLessThanOrEqual(channel.repairStoreBytes, 25_000)

        // Age: 5 s later the next ingest sweeps everything expired.
        try ingest(3, at: 5_000 * Self.ms)
        XCTAssertNil(channel.repairAnchor(for: FrameNumber(rawValue: 1)))
        XCTAssertNil(channel.repairAnchor(for: FrameNumber(rawValue: 2)))
        XCTAssertNotNil(channel.repairAnchor(for: FrameNumber(rawValue: 3)))

        // Channel-level one-attempt: a second repair of the same shard
        // enqueues nothing.
        XCTAssertEqual(try channel.enqueueRepair(
            frame: FrameNumber(rawValue: 3), shardIndices: [0],
            now: 5_001 * Self.ms
        ), 1)
        XCTAssertEqual(try channel.enqueueRepair(
            frame: FrameNumber(rawValue: 3), shardIndices: [0],
            now: 5_002 * Self.ms
        ), 0)
        XCTAssertEqual(channel.counters.repairShardsAlreadySent, 1)
    }

    // MARK: Leg 4 — post-FEC loss feeds the estimator (rung 3)

    private func videoLedger(
        received: UInt32, missing: UInt32 = 0
    ) -> [FeedbackReport.ChannelStats] {
        [FeedbackReport.ChannelStats(
            channel: .videoActive,
            highestSeq: ChannelSeq(rawValue: 0),
            received: received, missing: missing, duplicates: 0
        )]
    }

    func testEstimatorPostFecLossDownshiftsAndStepsRegime() throws {
        var config = RateEstimatorConfig(
            ceilingBitsPerSecond: Self.ceiling
        )
        config.regimeStepDownHoldNS = 1_000 * Self.ms
        let estimator = RateEstimator(config: config, now: 0)

        func report(
            received: UInt32, nackFrame: UInt32? = nil,
            shards: [UInt8] = [], clientMicros: UInt64
        ) throws -> FeedbackReport {
            var nacks: [FeedbackReport.NackEntry] = []
            if let nackFrame {
                nacks = [try FeedbackReport.NackEntry(
                    frame: FrameNumber(rawValue: nackFrame),
                    missingShards: shards
                )]
            }
            return FeedbackReport(
                clientTimestamp: ClientTimestamp(microseconds: clientMicros),
                channels: videoLedger(received: received),
                nacks: nacks
            )
        }

        // Seed the cumulative ledger (first report contributes nothing).
        _ = estimator.ingest(
            try report(received: 100, clientMicros: 100_000),
            now: 100 * Self.ms, inRecovery: false
        )
        // 100 more video datagrams attempted; 5 of them NACKed
        // post-FEC = 5% — over rung 3's 2%.
        let verdict = estimator.ingest(
            try report(received: 200, nackFrame: 7,
                       shards: [0, 1, 2, 3, 4], clientMicros: 200_000),
            now: 200 * Self.ms, inRecovery: false
        )
        XCTAssertEqual(verdict.postFecLossFraction, 0.05, accuracy: 1e-9)
        XCTAssertEqual(verdict.change, .postFecLoss,
                       "post-FEC loss is NOT the held 2–10% band")
        XCTAssertEqual(verdict.newRateBitsPerSecond,
                       Int(Double(Self.ceiling) * 0.85),
                       "rung 3's fall is multiplicative ×0.85")
        XCTAssertEqual(verdict.fecRegime, .lossy,
                       "the downshift and the regime step ride together")
        XCTAssertEqual(estimator.fecRegime, .lossy)
        XCTAssertEqual(estimator.stats.postFecDownshifts, 1)
        XCTAssertEqual(estimator.stats.nackShardsCounted, 5)

        // The same shards re-NACKed inside the window count once, and
        // the regime step does not repeat.
        let again = estimator.ingest(
            try report(received: 300, nackFrame: 7,
                       shards: [0, 1, 2, 3, 4], clientMicros: 250_000),
            now: 250 * Self.ms, inRecovery: false
        )
        XCTAssertNil(again.fecRegime, "the regime is a latch, not a pulse")
        XCTAssertEqual(estimator.stats.nackShardsCounted, 5,
                       "a re-NACK is insistence, not new loss")

        // Clean reports until the window empties and the hold passes:
        // the regime steps back down.
        var stepDown: FecRegime?
        var received: UInt32 = 300
        for beat in 1...30 {
            received += 100
            let v = estimator.ingest(
                try report(received: received,
                           clientMicros: UInt64(250_000 + beat * 100_000)),
                now: (250 + UInt64(beat) * 100) * Self.ms,
                inRecovery: false
            )
            if let regime = v.fecRegime { stepDown = regime }
        }
        XCTAssertEqual(stepDown, .clean,
                       "a sustained quiet stretch steps the ladder down")
        XCTAssertEqual(estimator.fecRegime, .clean)
        XCTAssertEqual(estimator.stats.regimeSteps, 2)
    }

    func testNackEvidenceHoldsRecoveryWindows() throws {
        var config = RateEstimatorConfig(
            ceilingBitsPerSecond: Self.ceiling
        )
        config.recoveryWindowNS = 25 * Self.ms
        let estimator = RateEstimator(config: config, now: 0)

        func report(
            nacked: Bool, frame: UInt32, clientMicros: UInt64
        ) throws -> FeedbackReport {
            FeedbackReport(
                clientTimestamp: ClientTimestamp(microseconds: clientMicros),
                nacks: nacked ? [try FeedbackReport.NackEntry(
                    frame: FrameNumber(rawValue: frame), missingShards: [0]
                )] : []
            )
        }

        // First report opens the window; its NACK evidence seeds it.
        let open = estimator.ingest(
            try report(nacked: true, frame: 1, clientMicros: 10_000),
            now: 10 * Self.ms, inRecovery: true
        )
        XCTAssertEqual(open.recoveryWindows, [])
        // 30 ms later the window closes UNCLEAN: post-FEC loss inside
        // a recovery window honestly holds RECOVERY.
        let dirty = estimator.ingest(
            try report(nacked: false, frame: 0, clientMicros: 40_000),
            now: 40 * Self.ms, inRecovery: true
        )
        XCTAssertEqual(dirty.recoveryWindows, [false])
        // A genuinely clean window closes clean.
        let clean = estimator.ingest(
            try report(nacked: false, frame: 0, clientMicros: 70_000),
            now: 70 * Self.ms, inRecovery: true
        )
        XCTAssertEqual(clean.recoveryWindows, [true])
    }

    // MARK: Leg 5 — the regime step lands on the packetizing seam

    func testGateFecRegimeStepChangesNextFrameGeometry() throws {
        let box = Box()
        let session = makeSession(box: box)
        var now: UInt64 = 0
        try establishSrtt(session, box: box, now: &now)

        // A 30 KB frame under the CLEAN column: k=28 → 5 parity.
        box.sendInstant = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 30_000),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: false, now: now
        )
        drain(session, box: box, until: now + 20 * Self.ms, now: &now)
        let (_, cleanGeo) = try shardsByIndex(box.fresh(), frame: 0)
        XCTAssertEqual(try XCTUnwrap(cleanGeo).parityShards, 5)

        // Seed the ledger, then a NACK-heavy report: 5% post-FEC.
        _ = try feed(session, report: FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: now / 1_000),
            channels: videoLedger(received: 100)
        ), now: now)
        now += 25 * Self.ms
        let events = try feed(session, report: FeedbackReport(
            clientTimestamp: ClientTimestamp(microseconds: now / 1_000),
            channels: videoLedger(received: 200),
            nacks: [try FeedbackReport.NackEntry(
                frame: FrameNumber(rawValue: 900),
                missingShards: [0, 1, 2, 3, 4]
            )]
        ), now: now)
        XCTAssertTrue(events.contains(.fecRegimeChanged(.lossy)))
        XCTAssertTrue(events.contains(where: {
            if case .rateChanged(_, .postFecLoss) = $0 { return true }
            return false
        }))
        XCTAssertEqual(session.fecRegime, .lossy)

        // The NEXT frame draws from the lossy column: k=28 → 35% →
        // 10 parity. Per-frame switch, no re-cutting of frame 0.
        box.sendInstant = now
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 30_000),
            captureTimestampMicroseconds: now / 1_000,
            isKeyframe: false, now: now
        )
        drain(session, box: box, until: now + 30 * Self.ms, now: &now)
        let (byIndex, lossyGeo) = try shardsByIndex(box.fresh(), frame: 1)
        XCTAssertEqual(try XCTUnwrap(lossyGeo).parityShards, 10,
                       "the lossy §5.2 column applies from the next frame")
        XCTAssertEqual(byIndex.count, 38)
        XCTAssertEqual(session.counters.fecRegimeSteps, 1)

        print("HS-17 gate leg 5: post-FEC 5% stepped clean→lossy — "
            + "frame 0 at 28+5, frame 1 at 28+10")
    }

    // MARK: Leg 6 — THE CADENCE GATE under a repair storm (R-G8 shape)

    /// 5 s of virtual time at 20 Mbps: 5 ms audio, 60 fps damage, a
    /// worst-case IDR every 2 s — and a NACK against EVERY fresh video
    /// frame on the 25 ms feedback cadence, so repairs flow the whole
    /// run. Audio inter-send must hold 5 ms ± 2 ms at p99: repairs
    /// ride videoTail, structurally below audio, and this leg proves
    /// the structure.
    func testGateAudioCadenceHoldsThroughRepairStorm() throws {
        let box = Box()
        let session = makeSession(box: box, seed: 0x1706)
        var now: UInt64 = 0
        try establishSrtt(session, box: box, now: &now)

        let ms = Self.ms
        let start = now
        let horizonNS = start + 5_000 * ms

        enum Arrival { case audio, damage, idr, feedback }
        var events: [(at: UInt64, what: Arrival)] = []
        var t = start
        while t < horizonNS { events.append((t, .audio)); t += 5 * ms }
        t = start + 8 * ms
        while t < horizonNS { events.append((t, .damage)); t += 16_666_667 }
        t = start + 100 * ms
        while t < horizonNS { events.append((t, .idr)); t += 2_000 * ms }
        t = start + 25 * ms
        while t < horizonNS { events.append((t, .feedback)); t += 25 * ms }
        events.sort { $0.at < $1.at }

        func opusPacket(_ n: Int) -> [UInt8] {
            (0..<80).map { UInt8(truncatingIfNeeded: n &* 31 &+ $0) }
        }

        var audioPacketNumber = 0
        var frameCounter: UInt32 = 0
        var lastNackedFrame: UInt32?
        var received: UInt32 = 0

        for event in events {
            while let wake = session.nextWake(now: now), wake < event.at {
                now = max(now &+ 1, wake)
                box.sendInstant = now
                _ = session.advance(now: now, hostMicroseconds: now / 1_000)
                session.pump(now: now)
            }
            now = event.at
            box.sendInstant = now
            switch event.what {
            case .audio:
                _ = try session.ingestAudioPacket(
                    opusPacket(audioPacketNumber),
                    captureTimestampMicroseconds: now / 1_000, now: now
                )
                audioPacketNumber += 1
            case .damage:
                _ = try session.ingestVideoFrame(
                    syntheticFrame(byteCount: 4_000),
                    captureTimestampMicroseconds: now / 1_000,
                    isKeyframe: false, now: now
                )
                frameCounter += 1
            case .idr:
                _ = try session.ingestVideoFrame(
                    syntheticFrame(byteCount: 59_904, irap: true),
                    captureTimestampMicroseconds: now / 1_000,
                    isKeyframe: true, now: now
                )
                frameCounter += 1
            case .feedback:
                // NACK the newest un-NACKed frame's first two shards:
                // a sustained repair storm, one attempt per frame.
                // The ledger stays big enough that post-FEC loss sits
                // under 2% — this leg pins cadence, leg 5 pins steps.
                received += 250
                var nacks: [FeedbackReport.NackEntry] = []
                if frameCounter > 0,
                   lastNackedFrame != frameCounter - 1 {
                    lastNackedFrame = frameCounter - 1
                    nacks = [try FeedbackReport.NackEntry(
                        frame: FrameNumber(rawValue: frameCounter - 1),
                        missingShards: [0, 1]
                    )]
                }
                _ = try feed(session, report: FeedbackReport(
                    clientTimestamp:
                        ClientTimestamp(microseconds: now / 1_000),
                    channels: videoLedger(received: received),
                    nacks: nacks
                ), now: now)
            }
            session.pump(now: now)
        }
        while let wake = session.nextWake(now: now), wake < horizonNS {
            now = max(now &+ 1, wake)
            box.sendInstant = now
            _ = session.advance(now: now, hostMicroseconds: now / 1_000)
            session.pump(now: now)
        }

        // ── Repairs really flowed ────────────────────────────────────
        let repairCount = box.tail().count
        XCTAssertGreaterThanOrEqual(repairCount, 200,
            "the storm must produce a repair stream, not a trickle")
        XCTAssertGreaterThanOrEqual(session.counters.nacksHonored, 100)

        // ── The cadence held THROUGH it (audio-continuity §4.1) ─────
        var audioSends: [(at: UInt64, envelope: Envelope)] = []
        for (at, datagram) in box.sent
        where datagram.pacerClass == .audio {
            let (envelope, _) = try Envelope.decode(datagram.bytes)
            audioSends.append((at, envelope))
        }
        let dataSends = try audioSends.filter {
            let field = try FecField.decode($0.envelope.fec)
            guard case .reedSolomon(let index, _) = field else {
                return false
            }
            return index < 4
        }
        XCTAssertEqual(dataSends.count, audioPacketNumber,
                       "every 5 ms packet reached the wire")
        var deviations: [UInt64] = []
        for i in 1..<dataSends.count {
            let delta = dataSends[i].at - dataSends[i - 1].at
            deviations.append(
                delta > 5 * ms ? delta - 5 * ms : 5 * ms - delta
            )
        }
        deviations.sort()
        let p99 = deviations[Int(Double(deviations.count - 1) * 0.99)]
        XCTAssertLessThanOrEqual(p99, 2 * ms,
            "audio inter-send p99 deviation \(Double(p99) / 1e6) ms > "
            + "2 ms through the repair storm")

        print("HS-17 gate (R-G8 + repair storm) @5 s virtual: "
            + "\(session.counters.nacksHonored) NACKs honored → "
            + "\(repairCount) repair datagrams on videoTail; "
            + "\(dataSends.count) audio packets, inter-send deviation "
            + "p99 \(Double(p99) / 1e6) ms, worst "
            + "\(Double(deviations.last!) / 1e6) ms; audio max queue "
            + "delay "
            + "\(Double(session.pacerTelemetry[.audio].maxQueueDelayNS) / 1e6)"
            + " ms")
    }
}
