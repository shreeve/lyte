import XCTest
import CoreMedia
import Foundation
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE GATE (build plan CL-12): the client's half of targeted repair —
// NACK emission per resiliency §1.1 (past-parity trigger, rule-3
// staleness mirror, once-ever dedupe, rule-4 IDR backstop) driven end to
// end in virtual time through the REAL production parts: ReceiveDemux
// unseal → LyteVideoPipeline → VideoAssembler presumption →
// NackPolicy → FeedbackSender's NACK section on the wire → a LyteWire
// host stand-in mirroring HS-17's responder (fresh-seq, fresh-seal
// repair datagrams carrying the ORIGINAL frame number + fec field,
// one attempt per shard) → the repaired frame emerging byte-exact from
// the same receive path. The root package cannot import HostWire; the
// stand-in rebuilds VideoChannel.enqueueRepair's shape from the same
// Wire parts the frozen vectors pin — exactly the LyteUdpSessionGate
// pattern.

final class NackRepairClientGateTests: XCTestCase {

    // MARK: - Corpus

    private static var corpusDirectory: String {
        var components = #filePath.split(separator: "/", omittingEmptySubsequences: false)
        components.removeLast(3)
        return components.joined(separator: "/") + "/Wire/Vectors/video-corpus-v1"
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

    // MARK: - The repairing host stand-in

    /// Noise responder + the HS-17 repair discipline: every packetized
    /// shard retained (plaintext + fec field), NACK entries read out of
    /// the client's real chan-3 reports, honored shards re-sent as
    /// FRESH datagrams — fresh seq continuing the channel counter,
    /// fresh seal, original frame/fec/timestamp — one attempt per
    /// shard, ever.
    private final class RepairHost: NoiseHandshakeIO {
        let staticKeys = NoiseKeyPair.generate()
        var transport: NoiseTransport?
        private var handshakeOutbox: [[UInt8]] = []

        var nextVideoSeq = ChannelSeq(rawValue: 0)
        /// frame → its original shards (envelope carries frame/fec/ts).
        var retained: [UInt32: [(envelope: Envelope, payload: [UInt8])]] = [:]
        var repairedShards = Set<UInt64>()   // frame<<8 | index

        // Evidence.
        var nackEntriesSeen: [(frame: UInt32, shards: [UInt8])] = []
        var idrRequestsSeen = 0
        var repairDatagramsSent = 0
        var duplicateAsks = 0

        func sendToHost(_ datagram: [UInt8]) throws {
            guard let (envelope, payload) = try? Envelope.decode(datagram[...]),
                  envelope.channel == .ctrl,
                  payload.first == CtrlMessageType.noiseHandshake1
            else { return }
            var responder = try NoiseSession(
                role: .responder, staticKeys: staticKeys)
            _ = try responder.readMessage1(payload.dropFirst())
            let message2 = try responder.writeMessage2()
            transport = try responder.makeTransport()
            let carriage = Envelope(
                channel: .ctrl,
                seq: ChannelSeq(rawValue: 0),
                frame: FrameNumber(rawValue: 0),
                timestamp: 0,
                fec: 0
            )
            handshakeOutbox.append(try carriage.encode(
                payload: [CtrlMessageType.noiseHandshake2] + message2))
        }

        func receiveDatagram(timeoutMilliseconds: Int) throws -> [UInt8]? {
            handshakeOutbox.isEmpty ? nil : handshakeOutbox.removeFirst()
        }

        private func seal(
            envelope: Envelope, plaintext: [UInt8]
        ) throws -> [UInt8] {
            let header = try envelope.encode(payload: [])
            let sealed = try transport!.seal(
                plaintext: plaintext[...], aad: header[...], envelope: envelope
            )
            let datagram = try envelope.encode(payload: sealed)
            XCTAssertLessThanOrEqual(
                datagram.count, WireBudget.maxDatagramByteCount)
            return datagram
        }

        /// Packetizes + retains one frame; returns sealed datagrams for
        /// every shard whose index is not in `dropping` — the scripted
        /// loss pattern.
        func videoDatagrams(
            annexB: [UInt8], frameNumber: UInt32, hostMicros: UInt64,
            dropping: Set<Int> = []
        ) throws -> [[UInt8]] {
            var packetizer = VideoPacketizer(firstSeq: nextVideoSeq)
            let shards = try packetizer.packetize(
                frame: annexB,
                frameNumber: FrameNumber(rawValue: frameNumber),
                captureTimestamp: HostTimestamp(microseconds: hostMicros),
                isIDR: AnnexBCheck.containsIrap(annexB),
                regime: .clean
            )
            nextVideoSeq = nextVideoSeq.advanced(by: Int16(shards.count))
            retained[frameNumber] = shards.map { ($0.envelope, $0.payload) }
            var out: [[UInt8]] = []
            for (index, shard) in shards.enumerated()
            where !dropping.contains(index) {
                out.append(try seal(
                    envelope: shard.envelope, plaintext: shard.payload))
            }
            return out
        }

        /// The geometry `annexB` WILL packetize to at the current seq —
        /// a scratch packetizer, no state disturbed (tests plan their
        /// drop sets from it).
        func plannedGeometry(annexB: [UInt8]) throws -> FecGeometry {
            var scratch = VideoPacketizer(firstSeq: nextVideoSeq)
            let shards = try scratch.packetize(
                frame: annexB,
                frameNumber: FrameNumber(rawValue: 0xFFFF_0000),
                captureTimestamp: HostTimestamp(microseconds: 0),
                isIDR: AnnexBCheck.containsIrap(annexB),
                regime: .clean
            )
            guard case .reedSolomon(_, let geometry) =
                try FecField.decode(shards[0].envelope.fec)
            else { preconditionFailure("packetizer emitted a non-RS shard") }
            return geometry
        }

        /// The HS-17 answer: fresh seq, fresh seal, original everything
        /// else. One attempt per shard, ever — a re-ask counts loud.
        func repairDatagrams(
            frame: UInt32, shardIndices: [UInt8]
        ) throws -> [[UInt8]] {
            guard let shards = retained[frame] else { return [] }
            var out: [[UInt8]] = []
            for index in shardIndices where Int(index) < shards.count {
                let key = UInt64(frame) << 8 | UInt64(index)
                guard !repairedShards.contains(key) else {
                    duplicateAsks += 1
                    continue
                }
                repairedShards.insert(key)
                var envelope = shards[Int(index)].envelope
                envelope.seq = nextVideoSeq
                nextVideoSeq = nextVideoSeq.next
                out.append(try seal(
                    envelope: envelope,
                    plaintext: shards[Int(index)].payload))
                repairDatagramsSent += 1
            }
            return out
        }

        /// One client datagram: chan-3 reports feed the NACK evidence,
        /// sealed 0x10s count as IDR requests; ARQ/echo noise ignores.
        func absorb(_ bytes: [UInt8]) throws {
            let (envelope, payload) = try Envelope.decode(bytes)
            let aad = bytes[bytes.startIndex..<payload.startIndex]
            let plaintext = try transport!.unseal(
                wirePayload: payload, aad: aad, envelope: envelope
            )
            if envelope.channel == .feedback {
                let report = try FeedbackReport.decode(plaintext)
                for nack in report.nacks {
                    nackEntriesSeen.append(
                        (nack.frame.rawValue, nack.missingShards))
                }
                return
            }
            if envelope.channel == .ctrl,
               plaintext.first == CtrlMessageType.idrRequest {
                idrRequestsSeen += 1
            }
        }
    }

    // MARK: - The client harness (the real core, virtual clock)

    private final class Harness: @unchecked Sendable {
        let host: RepairHost
        let crypto: NoiseTransportCrypto
        let demux: ReceiveDemux
        var core: LyteUdpSessionCore!
        let outbound = LockedPile()
        let clock = LockedClock()
        var samples: [DecodeUnit] = []
        var notes: [String] = []

        init(
            host: RepairHost,
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
                onSample: { [weak self] _, unit in
                    self?.samples.append(unit)
                },
                onEvent: { [weak self] event in
                    if case .protocolNote(let note) = event {
                        self?.notes.append(note)
                    }
                })
        }

        func absorb(_ bytes: [UInt8], tMicros: UInt64) {
            let outcome = demux.ingest(
                datagram: bytes[...], arrivalMicroseconds: tMicros)
            switch outcome {
            case .accepted:
                core.handleDatagram(outcome, arrivalMicroseconds: tMicros)
            case .unsealFailed:
                break
            default:
                XCTFail("host datagram refused: \(outcome)")
            }
        }

        /// Forwards everything the client sent to the host, in order.
        func pumpOutboundToHost(forwarded: inout Int) throws {
            while forwarded < outbound.count {
                try host.absorb(outbound.all[forwarded])
                forwarded += 1
            }
        }
    }

    final class LockedPile: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[UInt8]] = []
        func append(_ d: [UInt8]) { lock.lock(); stored.append(d); lock.unlock() }
        var all: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return stored }
        var count: Int { lock.lock(); defer { lock.unlock() }; return stored.count }
    }

    final class LockedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64 = 1_000
        var value: UInt64 {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    // MARK: - Leg A: past-parity loss → NACK → repair → byte-exact

    func testNackDrawsRepairAndFrameCompletesByteExact() throws {
        let corpus = try loadCorpus(4)
        let host = RepairHost()
        let harness = try Harness(host: host)

        var t: UInt64 = 1_000
        harness.clock.value = t

        // Frame 0 (IDR) arrives whole — the render bootstrap.
        for datagram in try host.videoDatagrams(
            annexB: corpus[0], frameNumber: 0, hostMicros: t
        ) {
            harness.absorb(datagram, tMicros: t)
        }

        // Frame 1 loses parity+2 DATA shards — past parity, FEC alone
        // can never complete it.
        t += 5_000; harness.clock.value = t
        let geometry1 = try host.plannedGeometry(annexB: corpus[1])
        let dropCount = geometry1.parityShards + 2
        XCTAssertLessThan(dropCount, geometry1.dataShards,
                          "corpus frame must survive the drop plan")
        let dropped = Set(0..<dropCount)
        for datagram in try host.videoDatagrams(
            annexB: corpus[1], frameNumber: 1, hostMicros: t,
            dropping: dropped
        ) {
            harness.absorb(datagram, tMicros: t)
        }

        // Follow-on frames advance the channel's highest seq: the
        // presumption crosses packet-threshold 3, the verdict goes past
        // parity, and the ask leaves in an out-of-cadence report.
        for number in 2...3 {
            t += 5_000; harness.clock.value = t
            for datagram in try host.videoDatagrams(
                annexB: corpus[number], frameNumber: UInt32(number),
                hostMicros: t
            ) {
                harness.absorb(datagram, tMicros: t)
            }
            harness.core.tick(now: ClientTimestamp(microseconds: t))
        }

        // The ask reached the host's stand-in through the REAL chan-3
        // report (unsealed, decoded); honor it the HS-17 way.
        var forwarded = 0
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertFalse(host.nackEntriesSeen.isEmpty,
                       "past-parity loss must draw a NACK ask")
        XCTAssertTrue(host.nackEntriesSeen.allSatisfy { $0.frame == 1 })
        let askedShards = Set(host.nackEntriesSeen.flatMap(\.shards))
        XCTAssertTrue(Set(dropped.map(UInt8.init)).isSubset(of: askedShards),
                      "every written-off shard must be asked for")

        t += 8_000; harness.clock.value = t
        for (frame, shards) in host.nackEntriesSeen {
            for datagram in try host.repairDatagrams(
                frame: frame, shardIndices: shards
            ) {
                harness.absorb(datagram, tMicros: t)
            }
        }
        harness.core.tick(now: ClientTimestamp(microseconds: t))

        // The frame healed byte-exact through the real receive path,
        // in frame order, and the IDR path never fired.
        XCTAssertEqual(harness.samples.map(\.frameNumber.rawValue),
                       [0, 1, 2, 3])
        XCTAssertEqual(harness.samples[1].annexB, corpus[1],
                       "the repaired frame must be byte-identical")
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertEqual(host.idrRequestsSeen, 0,
                       "repair healed the frame — no IDR")
        XCTAssertEqual(host.duplicateAsks, 0, "one attempt per shard, ever")

        let stats = harness.core.nackPolicy.snapshotStats()
        XCTAssertEqual(stats.pastParityFrames, 1)
        XCTAssertGreaterThanOrEqual(stats.shardsAsked, UInt64(dropCount))
        XCTAssertEqual(host.repairDatagramsSent, dropCount,
                       "every asked shard rode exactly one repair")
        // The group decodes the moment missing-data ≤ present-parity:
        // with parity+2 data shards dropped and all parity in hand,
        // exactly TWO repairs slot in before RS completes — the rest
        // land as duplicates on a decoded group (honest accounting,
        // same as the host gate's loop-decode leg).
        let needed = UInt64(dropCount - geometry1.parityShards)
        XCTAssertEqual(stats.repairShardsReceived, needed)
        XCTAssertEqual(stats.framesCompletedByRepair, 1)
        XCTAssertEqual(stats.asksSuppressedStale, 0)
        XCTAssertEqual(stats.framesEscalatedToIdr, 0)
        let pipeline = harness.core.pipeline.snapshotStats()
        XCTAssertEqual(pipeline.repairShardsAccepted, needed)
    }

    // MARK: - Leg B: stale frame → no NACK, IDR instead (rule 3 + 4)

    func testStaleFrameDrawsNoNackAndFallsBackToIdr() throws {
        let corpus = try loadCorpus(4)
        let host = RepairHost()
        // A tightened budget stands in for a slow path: with the frame
        // 150 ms old at verdict time, the 100 ms budget refuses the ask.
        var config = LyteUdpSessionCoreConfig()
        config.nackPolicy = NackPolicyConfig(
            staleBudgetMicroseconds: 100_000)
        let harness = try Harness(host: host, coreConfig: config)

        var t: UInt64 = 1_000
        harness.clock.value = t
        for datagram in try host.videoDatagrams(
            annexB: corpus[0], frameNumber: 0, hostMicros: t
        ) {
            harness.absorb(datagram, tMicros: t)
        }

        // Frame 1 arrives holed (one survivor short of the geometry),
        // then the wire goes quiet: the frame AGES past the budget
        // before any follow-on traffic renders the verdict.
        t += 5_000; harness.clock.value = t
        let probe = try host.videoDatagrams(
            annexB: corpus[1], frameNumber: 1, hostMicros: t)
        // Deliver ONLY the first shard: the group opens, everything
        // else is in flight as far as presumption knows.
        harness.absorb(probe[0], tMicros: t)

        // 150 ms of silence — under the assembler's 250 ms eviction,
        // over the policy's 100 ms budget.
        t += 150_000; harness.clock.value = t
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
        XCTAssertTrue(host.nackEntriesSeen.isEmpty,
                      "a stale frame must not be asked for")
        XCTAssertGreaterThanOrEqual(host.idrRequestsSeen, 1,
                                    "staleness is answered with the IDR")
        let stats = harness.core.nackPolicy.snapshotStats()
        XCTAssertEqual(stats.asksSuppressedStale, 1)
        XCTAssertEqual(stats.shardsAsked, 0)
        XCTAssertEqual(stats.fecImpossibleDeferred, 0,
                       "an unasked frame's verdict must not defer")
    }

    // MARK: - Leg C: policy discipline (dedupe, deadline, permanence)

    func testPolicyAsksOnceEverAndEscalatesOnDeadline() throws {
        let emitted = LockedPile()
        let escalated = LockedPile()
        let policy = NackPolicy(
            config: NackPolicyConfig(
                staleBudgetMicroseconds: 250_000,
                repairDeadlineMicroseconds: 100_000),
            rtt: { 5_000 },
            emit: { entries in
                for entry in entries {
                    emitted.append([UInt8(entry.frame.rawValue)]
                                   + entry.missingShards)
                }
            },
            escalate: { frame, _ in
                escalated.append([UInt8(frame.rawValue)])
            })
        let t0 = ClientTimestamp(microseconds: 1_000)
        let frame = FrameNumber(rawValue: 9)

        // Below parity: FEC owns it — no ask.
        policy.handle(.nackCandidates(
            frame: frame, missingShardIndices: [2],
            parityShards: 2, frameAgeMicroseconds: 0), now: t0)
        XCTAssertEqual(emitted.count, 0)

        // Past parity: ask, once.
        policy.handle(.nackCandidates(
            frame: frame, missingShardIndices: [2, 5, 7],
            parityShards: 2, frameAgeMicroseconds: 1_000), now: t0)
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.all[0], [9, 2, 5, 7])

        // The same picture again: nothing new — silence (dedupe).
        policy.handle(.nackCandidates(
            frame: frame, missingShardIndices: [2, 5, 7],
            parityShards: 2, frameAgeMicroseconds: 2_000), now: t0)
        XCTAssertEqual(emitted.count, 1)

        // A grown picture: only the NEW index rides.
        policy.handle(.nackCandidates(
            frame: frame, missingShardIndices: [2, 5, 7, 8],
            parityShards: 2, frameAgeMicroseconds: 3_000), now: t0)
        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(emitted.all[1], [9, 8])

        // A fec-impossible verdict inside the deadline defers.
        XCTAssertTrue(policy.shouldDeferFecImpossible(frame: frame, now: t0))

        // The deadline passes without completion: exactly ONE
        // escalation, and later beats stay quiet.
        policy.tick(now: t0.advanced(byMicroseconds: 100_000))
        XCTAssertEqual(escalated.count, 1)
        XCTAssertEqual(escalated.all[0], [9])
        policy.tick(now: t0.advanced(byMicroseconds: 150_000))
        XCTAssertEqual(escalated.count, 1)
        XCTAssertFalse(policy.shouldDeferFecImpossible(
            frame: frame, now: t0.advanced(byMicroseconds: 150_000)))

        let stats = policy.snapshotStats()
        XCTAssertEqual(stats.pastParityFrames, 1)
        XCTAssertEqual(stats.nackEntriesEmitted, 2)
        XCTAssertEqual(stats.shardsAsked, 4)
        XCTAssertEqual(stats.framesEscalatedToIdr, 1)
    }

    func testPolicyStaleRefusalIsPermanentAndCompletionCounts() throws {
        let emitted = LockedPile()
        let escalated = LockedPile()
        let policy = NackPolicy(
            config: NackPolicyConfig(staleBudgetMicroseconds: 50_000),
            rtt: { 40_000 },   // a slow path: 40 ms RTT
            emit: { entries in
                for _ in entries { emitted.append([]) }
            },
            escalate: { _, _ in escalated.append([]) })
        let t0 = ClientTimestamp(microseconds: 1_000)

        // age 20 ms + rtt 40 ms ≥ 50 ms budget → refused, forever.
        let old = FrameNumber(rawValue: 3)
        policy.handle(.nackCandidates(
            frame: old, missingShardIndices: [0, 1],
            parityShards: 1, frameAgeMicroseconds: 20_000), now: t0)
        XCTAssertEqual(emitted.count, 0)
        policy.handle(.nackCandidates(
            frame: old, missingShardIndices: [0, 1, 2],
            parityShards: 1, frameAgeMicroseconds: 25_000), now: t0)
        XCTAssertEqual(emitted.count, 0)
        XCTAssertFalse(policy.shouldDeferFecImpossible(frame: old, now: t0))
        XCTAssertEqual(policy.snapshotStats().asksSuppressedStale, 1)

        // A young frame asks; repairs land; completion books the heal
        // and the deadline never escalates it.
        let young = FrameNumber(rawValue: 4)
        policy.handle(.nackCandidates(
            frame: young, missingShardIndices: [1, 2],
            parityShards: 1, frameAgeMicroseconds: 2_000), now: t0)
        XCTAssertEqual(emitted.count, 1)
        policy.handle(.repairShardAccepted(frame: young, shardIndex: 1),
                      now: t0)
        policy.handle(.repairShardAccepted(frame: young, shardIndex: 2),
                      now: t0)
        policy.handle(.frameDecoded(frame: young), now: t0)
        policy.tick(now: t0.advanced(byMicroseconds: 300_000))
        XCTAssertEqual(escalated.count, 0)
        let stats = policy.snapshotStats()
        XCTAssertEqual(stats.repairShardsReceived, 2)
        XCTAssertEqual(stats.framesCompletedByRepair, 1)

        // An asked frame whose group DIES escalates immediately.
        let doomed = FrameNumber(rawValue: 5)
        policy.handle(.nackCandidates(
            frame: doomed, missingShardIndices: [0, 1],
            parityShards: 1, frameAgeMicroseconds: 2_000), now: t0)
        policy.handle(.framesGone(from: doomed, through: doomed), now: t0)
        XCTAssertEqual(escalated.count, 1)
    }

    // MARK: - Leg D: the feedback section carries and bounds the asks

    func testFeedbackReportCarriesQueuedNacksAndSpillsOverflow() throws {
        let host = RepairHost()
        let harness = try Harness(host: host)
        harness.clock.value = 1_000

        var entries: [FeedbackReport.NackEntry] = []
        for frame in 0..<8 {
            entries.append(try FeedbackReport.NackEntry(
                frame: FrameNumber(rawValue: UInt32(frame)),
                missingShards: [UInt8(frame), 20]))
        }
        harness.core.feedback.enqueueNacks(entries)

        // First beat: the section bound (6) rides; spill waits.
        let first = harness.core.feedback.buildReport(
            now: ClientTimestamp(microseconds: 1_000))
        XCTAssertEqual(first.nacks.count, FeedbackBounds.maxNackEntries)
        XCTAssertEqual(first.nacks.map(\.frame.rawValue),
                       [0, 1, 2, 3, 4, 5])
        // Encode/decode round-trips the section byte-faithfully.
        let decoded = try FeedbackReport.decode(first.encode())
        XCTAssertEqual(decoded.nacks, first.nacks)

        let second = harness.core.feedback.buildReport(
            now: ClientTimestamp(microseconds: 2_000))
        XCTAssertEqual(second.nacks.map(\.frame.rawValue), [6, 7])
        let third = harness.core.feedback.buildReport(
            now: ClientTimestamp(microseconds: 3_000))
        XCTAssertTrue(third.nacks.isEmpty, "drained is drained")
        XCTAssertEqual(
            harness.core.feedback.snapshotStats().nackEntriesSent, 8)
    }

    // MARK: - Leg E: a seeded SimNet storm heals through the ask loop

    func testStormLossHealsThroughNackRepairLoop() throws {
        let corpus = try loadCorpus(5)
        let host = RepairHost()
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
        // report loss story is rule 4's, covered in leg C).
        var forwardedToHost = 0
        var honored = Set<UInt64>()
        var frameBytes: [UInt32: [UInt8]] = [:]
        var nextFrame: UInt32 = 0
        var lastFeedbackAt: UInt64 = 0
        var t: UInt64 = 1_000

        while t <= 1_400_000 {
            harness.clock.value = t

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

            // The client's sends reach the host directly; new asks are
            // honored ONCE each, answered through the same lossy net.
            try harness.pumpOutboundToHost(forwarded: &forwardedToHost)
            for (frame, shards) in host.nackEntriesSeen {
                let fresh = shards.filter {
                    !honored.contains(UInt64(frame) << 8 | UInt64($0))
                }
                guard !fresh.isEmpty else { continue }
                for shard in fresh {
                    honored.insert(UInt64(frame) << 8 | UInt64(shard))
                }
                for datagram in try host.repairDatagrams(
                    frame: frame, shardIndices: fresh
                ) {
                    net.send(from: 1, bytes: datagram, now: t)
                }
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
        // Dedupe held under the storm: no (frame, shard) pair was ever
        // asked twice across every report the client sent.
        var askedPairs = Set<UInt64>()
        var repeatedAsks = 0
        for (frame, shards) in host.nackEntriesSeen {
            for shard in shards {
                if !askedPairs.insert(
                    UInt64(frame) << 8 | UInt64(shard)).inserted {
                    repeatedAsks += 1
                }
            }
        }
        XCTAssertEqual(repeatedAsks, 0, "one ask per shard, ever")
        XCTAssertLessThanOrEqual(stats.framesCompletedByRepair,
                                 stats.pastParityFrames)
    }
}
