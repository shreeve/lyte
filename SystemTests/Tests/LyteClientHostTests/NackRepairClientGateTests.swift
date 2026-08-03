import XCTest
import Foundation
import HostWire
import LyteClientTestKit
import LyteCore
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE JOINT GATE (build plans CL-12 + HS-17): targeted repair —
// NACK emission per resiliency §1.1 (past-parity trigger, rule-3
// staleness mirror, once-ever dedupe, rule-4 IDR backstop) driven end to
// end in virtual time through the REAL production parts: ReceiveDemux
// unseal → LyteVideoPipeline → VideoAssembler presumption →
// NackPolicy → FeedbackSender's NACK section on the wire → the real
// HostWire Session judgement → its VideoChannel responder (fresh-seq,
// fresh-seal repair datagrams carrying the ORIGINAL frame number + fec field,
// one attempt per shard) → the repaired frame emerging byte-exact from
// the same receive path. UDP IO and clocks are replaced by an in-memory sink
// and one guarded virtual clock; Noise, packetization, retention, judgement,
// and repair policy are the two shipping roles' implementations.

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

    // MARK: - The real host session, with only its socket replaced

    /// A Noise-backed shipping Session with an in-memory datagram sink.
    /// Loss and reordering happen only after this sink, exactly where a
    /// UDP socket would have released the bytes.
    private final class SessionRepairHost: NoiseHandshakeIO {
        private static let tuple = FourTuple(
            localAddress: "10.0.0.249", localPort: 41_081,
            remoteAddress: "10.0.0.23", remotePort: 61_000
        )

        private final class Outbox {
            var datagrams: [VideoChannelDatagram] = []
        }

        let staticKeys = NoiseKeyPair.generate()
        private let outbox = Outbox()
        private let config: SessionConfig
        private var nowNS: UInt64 = 0
        private var nextFrameNumber: UInt32 = 0
        private var repairsTaken = 0
        private(set) var events: [SessionEvent] = []

        private(set) lazy var session = Session(
            config: config,
            clientTuple: Self.tuple,
            now: 0,
            rng: SplitMix64(seed: 0xC1_12),
            send: { [outbox] datagram in
                outbox.datagrams.append(datagram)
            }
        )

        init(tweak: (inout SessionConfig) -> Void = { _ in }) {
            var config = SessionConfig(
                crypto: .noise(hostStatic: staticKeys),
                rateBitsPerSecond: 1_000_000_000
            )
            tweak(&config)
            self.config = config
        }

        var nowMicroseconds: UInt64 {
            (nowNS &+ 999) / 1_000
        }

        func sendToHost(_ datagram: [UInt8]) throws {
            events += session.receive(
                datagram,
                from: Self.tuple,
                now: nowNS,
                hostMicroseconds: nowNS / 1_000
            )
            session.pump(now: nowNS)
        }

        func receiveDatagram(timeoutMilliseconds: Int) throws -> [UInt8]? {
            serviceUntil(
                maxAdvanceNS: UInt64(timeoutMilliseconds) * 1_000_000
            ) { !outbox.datagrams.isEmpty }
            guard !outbox.datagrams.isEmpty else { return nil }
            return outbox.datagrams.removeFirst().bytes
        }

        func absorb(_ bytes: [UInt8], clientMicros: UInt64) throws {
            let arrivalNS = clientMicros * 1_000
            guard arrivalNS >= nowNS else {
                throw NSError(
                    domain: "NackRepairClientGateTests.hostClockRetreat",
                    code: 1,
                    userInfo: [
                        "hostNowNS": nowNS,
                        "clientArrivalNS": arrivalNS,
                    ]
                )
            }
            nowNS = arrivalNS
            events += session.receive(
                bytes,
                from: Self.tuple,
                now: nowNS,
                hostMicroseconds: nowNS / 1_000
            )
            session.pump(now: nowNS)
        }

        func videoDatagrams(
            annexB: [UInt8], frameNumber: UInt32, hostMicros: UInt64
        ) throws -> [[UInt8]] {
            XCTAssertEqual(
                frameNumber, nextFrameNumber,
                "the shipping Session owns one ascending frame sequence"
            )
            nextFrameNumber &+= 1
            nowNS = max(nowNS, hostMicros * 1_000)
            let count = try session.ingestVideoFrame(
                annexB,
                captureTimestampMicroseconds: hostMicros,
                isKeyframe: AnnexBCheck.containsIrap(annexB),
                now: nowNS
            )
            serviceUntil(maxAdvanceNS: 20_000_000) {
                self.outbox.datagrams.filter {
                    $0.pacerClass == .freshVideo
                        && $0.frameNumber.rawValue == frameNumber
                }.count >= count
            }
            let datagrams = take {
                $0.pacerClass == .freshVideo
                    && $0.frameNumber.rawValue == frameNumber
            }
            XCTAssertEqual(datagrams.count, count)
            return datagrams.map(\.bytes)
        }

        func takeControlDatagrams(
            maxAdvanceNS: UInt64 = 1_000_000
        ) -> [[UInt8]] {
            serviceFor(maxAdvanceNS: maxAdvanceNS)
            return take { $0.pacerClass == .control }.map(\.bytes)
        }

        func takeRepairDatagrams() -> [[UInt8]] {
            let expected = session.counters.repairDatagramsEnqueued
                - repairsTaken
            serviceUntil(maxAdvanceNS: 20_000_000) {
                self.outbox.datagrams.filter {
                    $0.pacerClass == .videoTail
                }.count >= expected
            }
            let datagrams = take { $0.pacerClass == .videoTail }
            repairsTaken += datagrams.count
            return datagrams.map(\.bytes)
        }

        private func take(
            where selectedBy: (VideoChannelDatagram) -> Bool
        ) -> [VideoChannelDatagram] {
            var selected: [VideoChannelDatagram] = []
            var kept: [VideoChannelDatagram] = []
            for datagram in outbox.datagrams {
                if selectedBy(datagram) {
                    selected.append(datagram)
                } else {
                    kept.append(datagram)
                }
            }
            outbox.datagrams = kept
            return selected
        }

        private func serviceFor(maxAdvanceNS: UInt64) {
            let horizon = nowNS &+ maxAdvanceNS
            session.pump(now: nowNS)
            while let wake = session.nextWake(now: nowNS), wake <= horizon {
                nowNS = max(nowNS &+ 1, wake)
                events += session.advance(
                    now: nowNS,
                    hostMicroseconds: nowNS / 1_000
                )
                session.pump(now: nowNS)
            }
        }

        private func serviceUntil(
            maxAdvanceNS: UInt64,
            _ done: () -> Bool
        ) {
            let horizon = nowNS &+ maxAdvanceNS
            session.pump(now: nowNS)
            while !done(),
                  let wake = session.nextWake(now: nowNS),
                  wake <= horizon {
                nowNS = max(nowNS &+ 1, wake)
                events += session.advance(
                    now: nowNS,
                    hostMicroseconds: nowNS / 1_000
                )
                session.pump(now: nowNS)
            }
        }
    }

    // MARK: - The client harness (the real core, virtual clock)

    private final class Harness: @unchecked Sendable {
        let host: SessionRepairHost
        let crypto: NoiseTransportCrypto
        let demux: ReceiveDemux
        var core: LyteUdpSessionCore!
        let outbound = LockedBytePile()
        let clock = LockedClock()
        var samples: [DecodeUnit] = []
        var notes: [String] = []
        var recoveryDemands: [(VideoRecoveryCause, FrameNumber)] = []
        var recoveryTrace: [VideoRecoveryTraceEvent] = []

        init(
            host: SessionRepairHost,
            coreConfig: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig()
        ) throws {
            self.host = host
            let crypto = try NoiseTransportCrypto(
                hostAddress: "10.0.0.249", hostPort: 41_081,
                hostStaticPublicKey: host.staticKeys.publicKey,
                staticKeys: NoiseKeyPair.generate(),
                attempts: 3, attemptTimeoutMilliseconds: 200)
            try crypto.performHandshake(io: host)
            self.crypto = crypto
            self.demux = ReceiveDemux(crypto: crypto)
            let outbound = self.outbound
            let clock = self.clock
            let sender = TransportSender(crypto: crypto, transmit: {
                outbound.append($0)
                return true
            })
            self.core = LyteUdpSessionCore(
                demux: demux,
                sender: sender,
                config: coreConfig,
                now: { ClientTimestamp(microseconds: clock.value) },
                onVideoRecoveryDemand: { [weak self] cause, frame in
                    self?.recoveryDemands.append((cause, frame))
                },
                onVideoRecoveryTrace: { [weak self] event in
                    self?.recoveryTrace.append(event)
                },
                videoSink: HeadlessVideoSink(receive: {
                    [weak self] _, unit in
                    self?.samples.append(unit)
                }),
                onEvent: { [weak self] event in
                    if case .protocolNote(let note) = event {
                        self?.notes.append(note)
                    }
                })
        }

        func absorb(_ bytes: [UInt8], tMicros: UInt64) {
            let arrival = max(tMicros, host.nowMicroseconds)
            clock.advance(to: arrival)
            let outcome = demux.ingest(
                datagram: bytes[...], arrivalMicroseconds: arrival)
            switch outcome {
            case .accepted:
                core.handleDatagram(outcome, arrivalMicroseconds: arrival)
            case .unsealFailed:
                break
            default:
                XCTFail("host datagram refused: \(outcome)")
            }
        }

        /// Forwards everything the client sent to the host, in order.
        func pumpOutboundToHost(forwarded: inout Int) throws {
            while forwarded < outbound.count {
                try host.absorb(
                    outbound.all[forwarded],
                    clientMicros: clock.value
                )
                forwarded += 1
            }
        }
    }

    final class LockedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64 = 1_000
        var value: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func advance(
            to next: UInt64,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            lock.lock()
            guard next >= stored else {
                let previous = stored
                lock.unlock()
                XCTFail(
                    "client clock retreated from \(previous) to \(next)",
                    file: file,
                    line: line
                )
                return
            }
            stored = next
            lock.unlock()
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

    private func split(
        _ datagrams: [[UInt8]], dropping: Set<Int>
    ) -> (sent: [[UInt8]], held: [[UInt8]]) {
        var sent: [[UInt8]] = []
        var held: [[UInt8]] = []
        for (index, datagram) in datagrams.enumerated() {
            if dropping.contains(index) {
                held.append(datagram)
            } else {
                sent.append(datagram)
            }
        }
        return (sent, held)
    }

    /// Finish the real Session's startup control flight through the real
    /// client. The beacon echo returns through the same encrypted CTRL
    /// path and seeds the host's actual SRTT estimator.
    private func settleStartup(
        host: SessionRepairHost,
        harness: Harness,
        forwarded: inout Int,
        at t: UInt64
    ) throws {
        harness.clock.advance(to: t)
        for datagram in host.takeControlDatagrams(
            maxAdvanceNS: 5_000_000
        ) {
            harness.absorb(datagram, tMicros: t)
        }
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertNotNil(
            host.session.srttMicroseconds,
            "the real startup beacon/echo must seed host SRTT"
        )
    }

    // MARK: - Leg A: past-parity loss → NACK → repair → byte-exact

    func testNackDrawsRepairAndFrameCompletesByteExact() throws {
        let corpus = try loadCorpus(4)
        let host = SessionRepairHost()
        let harness = try Harness(host: host)

        var t: UInt64 = 1_000
        var forwarded = 0
        try settleStartup(
            host: host,
            harness: harness,
            forwarded: &forwarded,
            at: t
        )

        // Frame 0 (IDR) arrives whole — the render bootstrap. Its clean
        // report also ends the host's opening-IDR exemption, so frame 1
        // must pass the normal SRTT + freeze-budget judgement.
        for datagram in try host.videoDatagrams(
            annexB: corpus[0], frameNumber: 0, hostMicros: t
        ) {
            harness.absorb(datagram, tMicros: t)
        }
        harness.core.feedback.tick(now: ClientTimestamp(microseconds: t))
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertGreaterThanOrEqual(
            host.session.counters.feedbackReportsParsed, 1
        )

        // Frame 1 loses parity+2 DATA shards — past parity, FEC alone
        // can never complete it.
        t += 5_000; harness.clock.advance(to: t)
        let frame1 = try host.videoDatagrams(
            annexB: corpus[1], frameNumber: 1, hostMicros: t
        )
        let geometry1 = try geometry(of: frame1)
        let dropCount = geometry1.parityShards + 2
        XCTAssertLessThan(dropCount, geometry1.dataShards,
                          "corpus frame must survive the drop plan")
        let dropped = Set(0..<dropCount)
        for datagram in split(frame1, dropping: dropped).sent {
            harness.absorb(datagram, tMicros: t)
        }

        // Follow-on frames advance the channel's highest seq: the
        // presumption crosses packet-threshold 3, the verdict goes past
        // parity, and the ask leaves in an out-of-cadence report.
        for number in 2...3 {
            t += 5_000; harness.clock.advance(to: t)
            for datagram in try host.videoDatagrams(
                annexB: corpus[number], frameNumber: UInt32(number),
                hostMicros: t
            ) {
                harness.absorb(datagram, tMicros: t)
            }
            harness.core.tick(now: ClientTimestamp(microseconds: t))
        }

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
        for datagram in repairs {
            harness.absorb(datagram, tMicros: t)
        }
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

        let stats = harness.core.nackPolicy.snapshotStats()
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

    // MARK: - Leg B: stale frame → no NACK, IDR instead (rule 3 + 4)

    func testStaleFrameDrawsNoNackAndFallsBackToIdr() throws {
        let corpus = try loadCorpus(4)
        let host = SessionRepairHost()
        // A tightened budget stands in for a slow path: with the frame
        // 150 ms old at verdict time, the 100 ms budget refuses the ask.
        var config = LyteUdpSessionCoreConfig()
        config.nackPolicy = NackPolicyConfig(
            staleBudgetMicroseconds: 100_000)
        let harness = try Harness(host: host, coreConfig: config)

        var t: UInt64 = 1_000
        harness.clock.advance(to: t)
        for datagram in try host.videoDatagrams(
            annexB: corpus[0], frameNumber: 0, hostMicros: t
        ) {
            harness.absorb(datagram, tMicros: t)
        }

        // Frame 1 arrives holed (one survivor short of the geometry),
        // then the wire goes quiet: the frame AGES past the budget
        // before any follow-on traffic renders the verdict.
        t += 5_000; harness.clock.advance(to: t)
        let probe = try host.videoDatagrams(
            annexB: corpus[1], frameNumber: 1, hostMicros: t)
        // Deliver ONLY the first shard: the group opens, everything
        // else is in flight as far as presumption knows.
        harness.absorb(probe[0], tMicros: t)

        // 150 ms of silence — under the assembler's 250 ms eviction,
        // over the policy's 100 ms budget.
        t += 150_000; harness.clock.advance(to: t)
        for number in 2...3 {
            for datagram in try host.videoDatagrams(
                annexB: corpus[number], frameNumber: UInt32(number),
                hostMicros: t
            ) {
                harness.absorb(datagram, tMicros: t)
            }
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
        let stats = harness.core.nackPolicy.snapshotStats()
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
        let host = SessionRepairHost()
        let harness = try Harness(host: host)
        var forwarded = 0
        let base: UInt64 = 1_000

        // Establish the decoder before damage.
        for datagram in try host.videoDatagrams(
            annexB: corpus[0], frameNumber: 0, hostMicros: base
        ) {
            harness.absorb(datagram, tMicros: base)
        }
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
        XCTAssertTrue(
            harness.core.idrRequester.snapshotStats().recoveryOutstanding)

        // An already-built dependent P frame cannot cross the core's render
        // seam while that episode is outstanding.
        let pAt = base + 150_000
        for datagram in try host.videoDatagrams(
            annexB: corpus[1], frameNumber: 1, hostMicros: pAt
        ) {
            harness.absorb(datagram, tMicros: pAt)
        }
        XCTAssertEqual(harness.samples.count, 1)
        XCTAssertTrue(harness.recoveryTrace.contains {
            $0.kind == "coreRejectedNonIrap"
                && $0.frame.rawValue == 1
        })

        // Assembly alone cannot close the episode.
        let irapAt = base + 200_000
        harness.clock.advance(to: irapAt)
        for datagram in try host.videoDatagrams(
            annexB: corpus[0], frameNumber: 2, hostMicros: irapAt
        ) {
            harness.absorb(datagram, tMicros: irapAt)
        }
        XCTAssertEqual(harness.samples.count, 2)
        XCTAssertTrue(harness.samples[1].isIDR)
        XCTAssertTrue(harness.recoveryTrace.contains {
            $0.kind == "coreForwardedIrap"
                && $0.frame.rawValue == 2
        })
        XCTAssertTrue(
            harness.core.idrRequester.snapshotStats().recoveryOutstanding)
        harness.core.noteVideoIrapEnqueued(
            frame: FrameNumber(rawValue: 2))
        XCTAssertFalse(
            harness.core.idrRequester.snapshotStats().recoveryOutstanding)
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
        harness.core.idrRequester.recordRecoveryDemand(
            frame: FrameNumber(rawValue: 12),
            now: ClientTimestamp(microseconds: base + 800_001))
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertEqual(host.session.counters.idrRequests, 2)
    }

    // MARK: - Leg C: a seeded SimNet storm heals through the ask loop

    func testStormLossHealsThroughNackRepairLoop() throws {
        let corpus = try loadCorpus(5)
        let host = SessionRepairHost()
        let harness = try Harness(host: host)
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
        try settleStartup(
            host: host,
            harness: harness,
            forwarded: &forwardedToHost,
            at: t
        )

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
                harness.absorb(delivery.bytes, tMicros: t)
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
                + host.takeControlDatagrams() {
                net.send(from: 1, bytes: datagram, now: t)
            }

            t += 2_000
        }

        // Every DELIVERED frame is byte-identical to its source — the
        // W-G3 integrity property held through loss + repair.
        XCTAssertGreaterThan(harness.samples.count, 10)
        for unit in harness.samples {
            XCTAssertEqual(unit.annexB, frameBytes[unit.frameNumber.rawValue],
                           "frame \(unit.frameNumber.rawValue) corrupt")
        }
        // The storm produced past-parity frames and the loop healed at
        // least one of them via repair (seed-pinned).
        let stats = harness.core.nackPolicy.snapshotStats()
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

    // MARK: - Leg D: answers after stragglers already fixed the frame

    /// The task the books exist for: the presumption goes past parity
    /// and the ask leaves, but the "lost" originals were merely
    /// reordered — they straggle in and complete the frame before any
    /// repair lands. Every answer the host then sends must be a clean
    /// no-op counted LATE: no double delivery, no corruption, no
    /// repair-acceptance bookkeeping.
    func testAnswersAfterStragglerHealAreCountedLateAndChangeNothing() throws {
        let corpus = try loadCorpus(3)
        let host = SessionRepairHost()
        let harness = try Harness(host: host)

        var t: UInt64 = 1_000
        var forwarded = 0
        try settleStartup(
            host: host,
            harness: harness,
            forwarded: &forwarded,
            at: t
        )
        for datagram in try host.videoDatagrams(
            annexB: corpus[0], frameNumber: 0, hostMicros: t
        ) {
            harness.absorb(datagram, tMicros: t)
        }

        // Frame 1: parity+2 shards "lost" — actually held for later.
        t += 5_000; harness.clock.advance(to: t)
        let frame1 = try host.videoDatagrams(
            annexB: corpus[1], frameNumber: 1, hostMicros: t
        )
        let geometry1 = try geometry(of: frame1)
        let dropCount = geometry1.parityShards + 2
        XCTAssertLessThan(dropCount, geometry1.dataShards)
        let frame1Split = split(
            frame1, dropping: Set(0..<dropCount)
        )
        for datagram in frame1Split.sent {
            harness.absorb(datagram, tMicros: t)
        }

        // ONE follow-on frame renders the past-parity verdict; the ask
        // leaves. (Just one, deliberately: the ~23-shard corpus frames
        // mean a second would push the stragglers past the 64-seq
        // replay window and the demux — correctly — would eat them
        // before this leg's seam is ever exercised.)
        t += 5_000; harness.clock.advance(to: t)
        for datagram in try host.videoDatagrams(
            annexB: corpus[2], frameNumber: 2, hostMicros: t
        ) {
            harness.absorb(datagram, tMicros: t)
        }
        harness.core.tick(now: ClientTimestamp(microseconds: t))
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        let repairs = host.takeRepairDatagrams()
        XCTAssertFalse(repairs.isEmpty)

        // TWO stragglers arrive — exactly enough for RS to complete —
        // and the frame emits byte-exact before any repair shows up.
        t += 3_000; harness.clock.advance(to: t)
        for datagram in frame1Split.held.prefix(2) {
            harness.absorb(datagram, tMicros: t)
        }
        XCTAssertEqual(harness.samples.map(\.frameNumber.rawValue),
                       [0, 1, 2])
        XCTAssertEqual(harness.samples[1].annexB, corpus[1])

        // The host honors the full ask anyway; every answer lands after
        // the frame's turn has passed.
        t += 5_000; harness.clock.advance(to: t)
        for datagram in repairs {
            harness.absorb(datagram, tMicros: t)
        }
        harness.core.tick(now: ClientTimestamp(microseconds: t))

        // No re-delivery, no corruption — and the books call every
        // answer late.
        XCTAssertEqual(harness.samples.map(\.frameNumber.rawValue),
                       [0, 1, 2], "a late answer must never re-deliver")
        let stats = harness.core.nackPolicy.snapshotStats()
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

    // MARK: - Leg E: answers for an abandoned frame count superseded

    /// The give-up story: an asked frame gets skipped by the holdback
    /// (newer decoded frames pile up behind it), rule 4 escalates it to
    /// the IDR requester, and every answer that still arrives is a
    /// counted no-op — SUPERSEDED, never rendered, never corrupting.
    func testAnswersForSupersededFrameCountAndAsksStop() throws {
        let corpus = try loadCorpus(5)
        let host = SessionRepairHost()
        let harness = try Harness(host: host)

        var t: UInt64 = 1_000
        var forwarded = 0
        try settleStartup(
            host: host,
            harness: harness,
            forwarded: &forwarded,
            at: t
        )
        for datagram in try host.videoDatagrams(
            annexB: corpus[0], frameNumber: 0, hostMicros: t
        ) {
            harness.absorb(datagram, tMicros: t)
        }

        // Frame 1 holed past parity; the ask leaves on the follow-on
        // traffic.
        t += 5_000; harness.clock.advance(to: t)
        let frame1 = try host.videoDatagrams(
            annexB: corpus[1], frameNumber: 1, hostMicros: t
        )
        let geometry1 = try geometry(of: frame1)
        let dropCount = geometry1.parityShards + 2
        XCTAssertLessThan(dropCount, geometry1.dataShards)
        for datagram in split(
            frame1, dropping: Set(0..<dropCount)
        ).sent {
            harness.absorb(datagram, tMicros: t)
        }

        // Three decoded frames pile up behind the hole — the holdback
        // (3) skips frame 1 the moment frame 4 decodes, and the skip
        // escalates the asked frame to the IDR requester (rule 4 via
        // the frame's death, not the deadline).
        for number in 2...4 {
            t += 5_000; harness.clock.advance(to: t)
            for datagram in try host.videoDatagrams(
                annexB: corpus[number], frameNumber: UInt32(number),
                hostMicros: t
            ) {
                harness.absorb(datagram, tMicros: t)
            }
            harness.core.tick(now: ClientTimestamp(microseconds: t))
        }
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
        t += 5_000; harness.clock.advance(to: t)
        for datagram in repairs {
            harness.absorb(datagram, tMicros: t)
        }
        harness.core.tick(now: ClientTimestamp(microseconds: t))

        XCTAssertEqual(harness.samples.map(\.frameNumber.rawValue),
                       [0],
                       "an answer for a dead frame must change nothing")
        let stats = harness.core.nackPolicy.snapshotStats()
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

    // MARK: - Leg F (HS-32): an explicit refusal ends the wait NOW

    func testHostRefusalEndsRepairWaitImmediately() throws {
        let corpus = try loadCorpus(4)
        let host = SessionRepairHost {
            $0.repairFreezeBudgetOverrideNS = 1_000_000
        }
        let harness = try Harness(host: host)

        var t: UInt64 = 1_000
        var forwarded = 0
        try settleStartup(
            host: host,
            harness: harness,
            forwarded: &forwarded,
            at: t
        )
        for datagram in try host.videoDatagrams(
            annexB: corpus[0], frameNumber: 0, hostMicros: t
        ) {
            harness.absorb(datagram, tMicros: t)
        }
        harness.core.feedback.tick(now: ClientTimestamp(microseconds: t))
        try harness.pumpOutboundToHost(forwarded: &forwarded)

        // Frame 1 goes past parity; follow-ons render the verdict and
        // the ask leaves in an out-of-cadence report (leg A's shape).
        t += 5_000; harness.clock.advance(to: t)
        let frame1 = try host.videoDatagrams(
            annexB: corpus[1], frameNumber: 1, hostMicros: t
        )
        let geometry1 = try geometry(of: frame1)
        let dropped = Set(0..<(geometry1.parityShards + 2))
        for datagram in split(frame1, dropping: dropped).sent {
            harness.absorb(datagram, tMicros: t)
        }
        for number in 2...3 {
            t += 5_000; harness.clock.advance(to: t)
            for datagram in try host.videoDatagrams(
                annexB: corpus[number], frameNumber: UInt32(number),
                hostMicros: t
            ) {
                harness.absorb(datagram, tMicros: t)
            }
            harness.core.tick(now: ClientTimestamp(microseconds: t))
        }
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
        let controlFlight = host.takeControlDatagrams()
        XCTAssertGreaterThanOrEqual(controlFlight.count, refusalCount)
        for datagram in controlFlight {
            harness.absorb(datagram, tMicros: t)
        }
        harness.core.feedback.tick(now: ClientTimestamp(microseconds: t))
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertGreaterThanOrEqual(
            host.session.counters.idrRequests, 1,
            "the refusal goes straight to the IDR path — no deadline burned")
        let stats = harness.core.nackPolicy.snapshotStats()
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
