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
            try videoDatagramsSplit(
                annexB: annexB, frameNumber: frameNumber,
                hostMicros: hostMicros, dropping: dropping
            ).sent
        }

        /// Like `videoDatagrams`, but the "dropped" shards come back
        /// sealed too — the straggler-reorder legs deliver them LATE
        /// instead of never (seals are envelope-keyed, so holding a
        /// datagram costs nothing).
        func videoDatagramsSplit(
            annexB: [UInt8], frameNumber: UInt32, hostMicros: UInt64,
            dropping: Set<Int> = []
        ) throws -> (sent: [[UInt8]], held: [[UInt8]]) {
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
            var sent: [[UInt8]] = []
            var held: [[UInt8]] = []
            for (index, shard) in shards.enumerated() {
                let datagram = try seal(
                    envelope: shard.envelope, plaintext: shard.payload)
                if dropping.contains(index) {
                    held.append(datagram)
                } else {
                    sent.append(datagram)
                }
            }
            return (sent, held)
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

        /// The NETWORK's second copy of an already-honored answer: the
        /// same original shard under yet another fresh seq. An exact
        /// byte duplicate would die at the demux's replay window and
        /// never reach the assembler's books — duplication on the wire
        /// re-seals. Deliberately bypasses the one-attempt guard: this
        /// models the wire (or a replay-shaping peer), not the host.
        func duplicateRepairDatagram(
            frame: UInt32, shardIndex: UInt8
        ) throws -> [UInt8] {
            let shards = retained[frame]!
            var envelope = shards[Int(shardIndex)].envelope
            envelope.seq = nextVideoSeq
            nextVideoSeq = nextVideoSeq.next
            return try seal(
                envelope: envelope,
                plaintext: shards[Int(shardIndex)].payload)
        }

        var nextCtrlSeq = ChannelSeq(rawValue: 0)

        /// HS-32: one sealed 0x23 refusal — the host responder's
        /// explicit "no", ARQ-exempt on the ctrl channel like 0x10.
        func refusalDatagram(
            frame: UInt32, reason: RepairRefusalReason, hostMicros: UInt64
        ) throws -> [UInt8] {
            let envelope = Envelope(
                channel: .ctrl,
                seq: nextCtrlSeq,
                frame: FrameNumber(rawValue: 0),
                timestamp: hostMicros,
                fec: 0
            )
            nextCtrlSeq = nextCtrlSeq.next
            return try seal(
                envelope: envelope,
                plaintext: RepairRefusal(
                    frame: FrameNumber(rawValue: frame), reason: reason
                ).encode())
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
        var recoveryDemands: [(VideoRecoveryCause, FrameNumber)] = []
        var recoveryTrace: [VideoRecoveryTraceEvent] = []

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
                onVideoRecoveryDemand: { [weak self] cause, frame in
                    self?.recoveryDemands.append((cause, frame))
                },
                onVideoRecoveryTrace: { [weak self] event in
                    self?.recoveryTrace.append(event)
                },
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
        XCTAssertTrue(harness.recoveryDemands.contains {
            $0.0 == .fecAssemblerDamage
        })
    }

    func testAcceptedIrapClosesOutstandingRecoveryEpisode() throws {
        let corpus = try loadCorpus(2)
        let host = RepairHost()
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
        harness.clock.value = base
        harness.core.requestVideoRecovery(
            after: FrameNumber(rawValue: 10), cause: .fecAssemblerDamage)
        harness.clock.value = base + 100_000
        harness.core.requestVideoRecovery(
            after: FrameNumber(rawValue: 11), cause: .fecAssemblerDamage)
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertEqual(host.idrRequestsSeen, 1)
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
        harness.clock.value = irapAt
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
        harness.core.feedback.tick(
            now: ClientTimestamp(microseconds: base + 800_000))
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertEqual(host.idrRequestsSeen, 1)
        harness.core.idrRequester.recordRecoveryDemand(
            frame: FrameNumber(rawValue: 12),
            now: ClientTimestamp(microseconds: base + 800_001))
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertEqual(host.idrRequestsSeen, 2)
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

    /// The whole-loss rule (the HS-33 unmasked gap): a frame that never
    /// landed a single shard has no book, no ask, and no fecImpossible
    /// verdict — before this rule, NOTHING reached the IDR requester and
    /// the broken reference chain stood until an unrelated wake IDR. A
    /// gone-range of such frames must escalate exactly once (one IDR
    /// heals everything), and a range already covered by a rule-4
    /// asked-frame escalation must NOT double-fire.
    func testWhollyLostFrameEscalatesToIdrOncePerRange() throws {
        let escalated = LockedPile()
        let policy = NackPolicy(
            config: NackPolicyConfig(
                staleBudgetMicroseconds: 250_000,
                repairDeadlineMicroseconds: 100_000),
            rtt: { 5_000 },
            emit: { _ in },
            escalate: { frame, _ in
                escalated.append([UInt8(frame.rawValue)])
            })
        let t0 = ClientTimestamp(microseconds: 1_000)

        // A three-frame numbering gap, no shard ever seen for any of
        // them: ONE escalation, anchored at the range's first frame.
        policy.handle(.framesGone(
            from: FrameNumber(rawValue: 20),
            through: FrameNumber(rawValue: 22)), now: t0)
        XCTAssertEqual(escalated.count, 1)
        XCTAssertEqual(escalated.all[0], [20])
        XCTAssertEqual(policy.snapshotStats().whollyLostEscalations, 1)

        // A range where one frame WAS asked (rule 4's territory): the
        // asked frame escalates, the whole-loss rule stands down.
        let asked = FrameNumber(rawValue: 31)
        policy.handle(.nackCandidates(
            frame: asked, missingShardIndices: [1, 2, 3],
            parityShards: 2, frameAgeMicroseconds: 0), now: t0)
        policy.handle(.framesGone(
            from: FrameNumber(rawValue: 30),
            through: FrameNumber(rawValue: 32)), now: t0)
        XCTAssertEqual(escalated.count, 2)
        XCTAssertEqual(escalated.all[1], [31])
        let stats = policy.snapshotStats()
        XCTAssertEqual(stats.framesEscalatedToIdr, 1)
        XCTAssertEqual(stats.whollyLostEscalations, 1)
    }

    /// A gone-range holding only settled books changes nothing: decoded
    /// frames emitted (no reference break), and an already-escalated
    /// range never re-fires.
    func testWholeLossRuleIgnoresSettledBooks() throws {
        let escalated = LockedPile()
        let policy = NackPolicy(
            config: NackPolicyConfig(
                staleBudgetMicroseconds: 250_000,
                repairDeadlineMicroseconds: 100_000),
            rtt: { 5_000 },
            emit: { _ in },
            escalate: { frame, _ in
                escalated.append([UInt8(frame.rawValue)])
            })
        let t0 = ClientTimestamp(microseconds: 1_000)
        let frame = FrameNumber(rawValue: 40)

        // A tracked, below-parity frame (book exists, never asked)
        // that then DECODES: its later gone-signal must not escalate.
        policy.handle(.nackCandidates(
            frame: frame, missingShardIndices: [2],
            parityShards: 2, frameAgeMicroseconds: 0), now: t0)
        policy.handle(.frameDecoded(frame: frame), now: t0)
        policy.handle(.framesGone(from: frame, through: frame), now: t0)
        XCTAssertEqual(escalated.count, 0)

        // An undecoded gone-range escalates once — and the SAME range
        // signalled again (books now settled .gone) stays quiet.
        let lost = FrameNumber(rawValue: 41)
        policy.handle(.nackCandidates(
            frame: lost, missingShardIndices: [2],
            parityShards: 2, frameAgeMicroseconds: 0), now: t0)
        policy.handle(.framesGone(from: lost, through: lost), now: t0)
        XCTAssertEqual(escalated.count, 1)
        policy.handle(.framesGone(from: lost, through: lost), now: t0)
        XCTAssertEqual(escalated.count, 1)
        XCTAssertEqual(policy.snapshotStats().whollyLostEscalations, 1)
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

        // An asked frame whose group DIES escalates immediately — and
        // is never asked for again, whatever pictures still arrive.
        let doomed = FrameNumber(rawValue: 5)
        policy.handle(.nackCandidates(
            frame: doomed, missingShardIndices: [0, 1],
            parityShards: 1, frameAgeMicroseconds: 2_000), now: t0)
        policy.handle(.framesGone(from: doomed, through: doomed), now: t0)
        XCTAssertEqual(escalated.count, 1)
        let askedBefore = emitted.count
        policy.handle(.nackCandidates(
            frame: doomed, missingShardIndices: [0, 1, 3],
            parityShards: 1, frameAgeMicroseconds: 3_000), now: t0)
        XCTAssertEqual(emitted.count, askedBefore,
                       "a settled frame must never be re-asked")

        // Answer classification, pinned per branch: an answer for the
        // GONE frame is superseded; a straggler for the DECODED frame
        // is late; a second copy of an ACCEPTED repair is a duplicate;
        // and signals for never-asked shards touch no repair book.
        policy.handle(.staleShardDropped(frame: doomed), now: t0)
        policy.handle(.staleShardDropped(frame: young), now: t0)
        policy.handle(.satisfiedShardDropped(frame: young, shardIndex: 1),
                      now: t0)
        let unasked = FrameNumber(rawValue: 77)
        policy.handle(.staleShardDropped(frame: unasked), now: t0)
        policy.handle(.satisfiedShardDropped(frame: unasked, shardIndex: 0),
                      now: t0)
        let classified = policy.snapshotStats()
        XCTAssertEqual(classified.repairsSuperseded, 1)
        XCTAssertEqual(classified.repairsLate, 1)
        XCTAssertEqual(classified.repairsDuplicate, 1)
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

    // MARK: - Leg F: answers after stragglers already fixed the frame

    /// The task the books exist for: the presumption goes past parity
    /// and the ask leaves, but the "lost" originals were merely
    /// reordered — they straggle in and complete the frame before any
    /// repair lands. Every answer the host then sends must be a clean
    /// no-op counted LATE: no double delivery, no corruption, no
    /// repair-acceptance bookkeeping.
    func testAnswersAfterStragglerHealAreCountedLateAndChangeNothing() throws {
        let corpus = try loadCorpus(3)
        let host = RepairHost()
        let harness = try Harness(host: host)

        var t: UInt64 = 1_000
        harness.clock.value = t
        for datagram in try host.videoDatagrams(
            annexB: corpus[0], frameNumber: 0, hostMicros: t
        ) {
            harness.absorb(datagram, tMicros: t)
        }

        // Frame 1: parity+2 shards "lost" — actually held for later.
        t += 5_000; harness.clock.value = t
        let geometry1 = try host.plannedGeometry(annexB: corpus[1])
        let dropCount = geometry1.parityShards + 2
        XCTAssertLessThan(dropCount, geometry1.dataShards)
        let split = try host.videoDatagramsSplit(
            annexB: corpus[1], frameNumber: 1, hostMicros: t,
            dropping: Set(0..<dropCount))
        for datagram in split.sent {
            harness.absorb(datagram, tMicros: t)
        }

        // ONE follow-on frame renders the past-parity verdict; the ask
        // leaves. (Just one, deliberately: the ~23-shard corpus frames
        // mean a second would push the stragglers past the 64-seq
        // replay window and the demux — correctly — would eat them
        // before this leg's seam is ever exercised.)
        t += 5_000; harness.clock.value = t
        for datagram in try host.videoDatagrams(
            annexB: corpus[2], frameNumber: 2, hostMicros: t
        ) {
            harness.absorb(datagram, tMicros: t)
        }
        harness.core.tick(now: ClientTimestamp(microseconds: t))
        var forwarded = 0
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertFalse(host.nackEntriesSeen.isEmpty)

        // TWO stragglers arrive — exactly enough for RS to complete —
        // and the frame emits byte-exact before any repair shows up.
        t += 3_000; harness.clock.value = t
        for datagram in split.held.prefix(2) {
            harness.absorb(datagram, tMicros: t)
        }
        XCTAssertEqual(harness.samples.map(\.frameNumber.rawValue),
                       [0, 1, 2])
        XCTAssertEqual(harness.samples[1].annexB, corpus[1])

        // The host honors the full ask anyway; every answer lands after
        // the frame's turn has passed.
        t += 5_000; harness.clock.value = t
        for (frame, shards) in host.nackEntriesSeen {
            for datagram in try host.repairDatagrams(
                frame: frame, shardIndices: shards
            ) {
                harness.absorb(datagram, tMicros: t)
            }
        }
        harness.core.tick(now: ClientTimestamp(microseconds: t))

        // No re-delivery, no corruption — and the books call every
        // answer late.
        XCTAssertEqual(harness.samples.map(\.frameNumber.rawValue),
                       [0, 1, 2], "a late answer must never re-deliver")
        let stats = harness.core.nackPolicy.snapshotStats()
        XCTAssertEqual(stats.pastParityFrames, 1)
        XCTAssertEqual(stats.repairsLate, UInt64(host.repairDatagramsSent))
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
        XCTAssertEqual(host.idrRequestsSeen, 0)
    }

    // MARK: - Leg G: a duplicated answer on the wire counts, once

    /// Network duplication of an accepted repair (fresh seq — an exact
    /// byte copy dies at the demux replay window, which is its own
    /// gate): the second copy is a counted no-op, and the frame still
    /// heals byte-exact.
    func testDuplicatedRepairAnswerIsCountedAndHarmless() throws {
        let corpus = try loadCorpus(4)
        let host = RepairHost()
        let harness = try Harness(host: host)

        var t: UInt64 = 1_000
        harness.clock.value = t
        for datagram in try host.videoDatagrams(
            annexB: corpus[0], frameNumber: 0, hostMicros: t
        ) {
            harness.absorb(datagram, tMicros: t)
        }

        t += 5_000; harness.clock.value = t
        let geometry1 = try host.plannedGeometry(annexB: corpus[1])
        let dropCount = geometry1.parityShards + 2
        XCTAssertLessThan(dropCount, geometry1.dataShards)
        for datagram in try host.videoDatagrams(
            annexB: corpus[1], frameNumber: 1, hostMicros: t,
            dropping: Set(0..<dropCount)
        ) {
            harness.absorb(datagram, tMicros: t)
        }
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
        var forwarded = 0
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertFalse(host.nackEntriesSeen.isEmpty)

        // The answers dribble in one at a time; the FIRST one gets
        // duplicated by the wire while the group is still incomplete.
        // (The ask may ride SPLIT across entries — the missing picture
        // grows as follow-on shards ingest — so gather them all.)
        t += 8_000; harness.clock.value = t
        var answers: [[UInt8]] = []
        for (frame, shards) in host.nackEntriesSeen {
            answers.append(contentsOf: try host.repairDatagrams(
                frame: frame, shardIndices: shards))
        }
        XCTAssertEqual(answers.count, dropCount)
        let firstAskedShard = host.nackEntriesSeen[0].shards[0]

        harness.absorb(answers[0], tMicros: t)   // accepted
        harness.absorb(try host.duplicateRepairDatagram(
            frame: 1, shardIndex: firstAskedShard), tMicros: t)   // the copy
        harness.absorb(answers[1], tMicros: t)   // accepted — RS completes
        harness.core.tick(now: ClientTimestamp(microseconds: t))

        XCTAssertEqual(harness.samples.map(\.frameNumber.rawValue),
                       [0, 1, 2, 3])
        XCTAssertEqual(harness.samples[1].annexB, corpus[1],
                       "healed byte-exact through the duplication")
        let stats = harness.core.nackPolicy.snapshotStats()
        XCTAssertEqual(stats.repairShardsReceived, 2)
        XCTAssertEqual(stats.framesCompletedByRepair, 1)
        XCTAssertEqual(stats.repairsDuplicate, 1,
                       "the wire's second copy counts exactly once")
        XCTAssertEqual(stats.repairsLate, 0)
        XCTAssertEqual(stats.repairsSuperseded, 0)
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertEqual(host.idrRequestsSeen, 0)
    }

    // MARK: - Leg H: answers for an abandoned frame count superseded

    /// The give-up story: an asked frame gets skipped by the holdback
    /// (newer decoded frames pile up behind it), rule 4 escalates it to
    /// the IDR requester, and every answer that still arrives is a
    /// counted no-op — SUPERSEDED, never rendered, never corrupting.
    func testAnswersForSupersededFrameCountAndAsksStop() throws {
        let corpus = try loadCorpus(5)
        let host = RepairHost()
        let harness = try Harness(host: host)

        var t: UInt64 = 1_000
        harness.clock.value = t
        for datagram in try host.videoDatagrams(
            annexB: corpus[0], frameNumber: 0, hostMicros: t
        ) {
            harness.absorb(datagram, tMicros: t)
        }

        // Frame 1 holed past parity; the ask leaves on the follow-on
        // traffic.
        t += 5_000; harness.clock.value = t
        let geometry1 = try host.plannedGeometry(annexB: corpus[1])
        let dropCount = geometry1.parityShards + 2
        XCTAssertLessThan(dropCount, geometry1.dataShards)
        for datagram in try host.videoDatagrams(
            annexB: corpus[1], frameNumber: 1, hostMicros: t,
            dropping: Set(0..<dropCount)
        ) {
            harness.absorb(datagram, tMicros: t)
        }

        // Three decoded frames pile up behind the hole — the holdback
        // (3) skips frame 1 the moment frame 4 decodes, and the skip
        // escalates the asked frame to the IDR requester (rule 4 via
        // the frame's death, not the deadline).
        for number in 2...4 {
            t += 5_000; harness.clock.value = t
            for datagram in try host.videoDatagrams(
                annexB: corpus[number], frameNumber: UInt32(number),
                hostMicros: t
            ) {
                harness.absorb(datagram, tMicros: t)
            }
            harness.core.tick(now: ClientTimestamp(microseconds: t))
        }
        harness.core.feedback.tick(now: ClientTimestamp(microseconds: t))
        var forwarded = 0
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertFalse(host.nackEntriesSeen.isEmpty,
                       "the ask must have left before the skip")
        XCTAssertEqual(harness.samples.map(\.frameNumber.rawValue),
                       [0],
                       "frame 1 skipped; dependent P frames stay fenced")
        XCTAssertGreaterThanOrEqual(host.idrRequestsSeen, 1,
                                    "the abandoned ask escalates to IDR")

        // The host's answers arrive anyway — for a frame that no
        // longer exists anywhere in the client.
        t += 5_000; harness.clock.value = t
        for (frame, shards) in host.nackEntriesSeen {
            for datagram in try host.repairDatagrams(
                frame: frame, shardIndices: shards
            ) {
                harness.absorb(datagram, tMicros: t)
            }
        }
        harness.core.tick(now: ClientTimestamp(microseconds: t))

        XCTAssertEqual(harness.samples.map(\.frameNumber.rawValue),
                       [0],
                       "an answer for a dead frame must change nothing")
        let stats = harness.core.nackPolicy.snapshotStats()
        XCTAssertEqual(stats.repairsSuperseded,
                       UInt64(host.repairDatagramsSent))
        XCTAssertGreaterThan(stats.repairsSuperseded, 0)
        XCTAssertEqual(stats.repairsLate, 0)
        XCTAssertEqual(stats.repairsDuplicate, 0)
        XCTAssertEqual(stats.repairShardsReceived, 0)
        XCTAssertEqual(stats.framesEscalatedToIdr, 1)
        XCTAssertEqual(
            harness.core.pipeline.snapshotStats().repairShardsAccepted, 0)
        // And the asking stopped: everything the host ever saw for
        // frame 1 predates the skip (once-ever dedupe + settled book).
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        let askedPairs = host.nackEntriesSeen.flatMap { entry in
            entry.shards.map { UInt64(entry.frame) << 8 | UInt64($0) }
        }
        XCTAssertEqual(askedPairs.count, Set(askedPairs).count,
                       "no (frame, shard) pair was ever re-asked")
    }

    // MARK: - Leg H (HS-32): an explicit refusal ends the wait NOW

    func testHostRefusalEndsRepairWaitImmediately() throws {
        let corpus = try loadCorpus(4)
        let host = RepairHost()
        let harness = try Harness(host: host)

        var t: UInt64 = 1_000
        harness.clock.value = t
        for datagram in try host.videoDatagrams(
            annexB: corpus[0], frameNumber: 0, hostMicros: t
        ) {
            harness.absorb(datagram, tMicros: t)
        }

        // Frame 1 goes past parity; follow-ons render the verdict and
        // the ask leaves in an out-of-cadence report (leg A's shape).
        t += 5_000; harness.clock.value = t
        let geometry1 = try host.plannedGeometry(annexB: corpus[1])
        let dropped = Set(0..<(geometry1.parityShards + 2))
        for datagram in try host.videoDatagrams(
            annexB: corpus[1], frameNumber: 1, hostMicros: t,
            dropping: dropped
        ) {
            harness.absorb(datagram, tMicros: t)
        }
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
        var forwarded = 0
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertFalse(host.nackEntriesSeen.isEmpty,
                       "the ask must be live before the refusal answers it")
        XCTAssertEqual(host.idrRequestsSeen, 0)

        // The host REFUSES instead of repairing — 5 ms later, far
        // inside the 250 ms deadline the client used to burn whole.
        t += 5_000; harness.clock.value = t
        harness.absorb(
            try host.refusalDatagram(
                frame: 1, reason: .staleBudget, hostMicros: t),
            tMicros: t)
        harness.core.feedback.tick(now: ClientTimestamp(microseconds: t))
        try harness.pumpOutboundToHost(forwarded: &forwarded)
        XCTAssertGreaterThanOrEqual(
            host.idrRequestsSeen, 1,
            "the refusal goes straight to the IDR path — no deadline burned")
        var stats = harness.core.nackPolicy.snapshotStats()
        XCTAssertEqual(stats.refusalsReceived, 1)
        XCTAssertEqual(stats.refusalsActedOn, 1)
        XCTAssertEqual(stats.refusalsIgnored, 0)
        XCTAssertEqual(stats.framesEscalatedToIdr, 0,
                       "refusal-acted is its own book, not a deadline expiry")
        XCTAssertTrue(harness.notes.contains {
            $0.contains("repair refused") && $0.contains("staleBudget")
        }, "the refusal is loud in the protocol notes")

        // A DUPLICATE refusal for the settled ask and an UNKNOWN one
        // for a frame never asked: ignored loud, nothing escalates.
        t += 1_000; harness.clock.value = t
        harness.absorb(
            try host.refusalDatagram(
                frame: 1, reason: .staleBudget, hostMicros: t),
            tMicros: t)
        harness.absorb(
            try host.refusalDatagram(
                frame: 7, reason: .unknownFrame, hostMicros: t),
            tMicros: t)
        stats = harness.core.nackPolicy.snapshotStats()
        XCTAssertEqual(stats.refusalsReceived, 3)
        XCTAssertEqual(stats.refusalsActedOn, 1,
                       "an ask acts at most once")
        XCTAssertEqual(stats.refusalsIgnored, 2)
    }
}
