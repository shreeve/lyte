import XCTest
import Foundation
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE GATE (build plan CL-7, the ARQ leg — the client half of HS-8's
// gate): the client's real reliable-CTRL stack — NoiseTransportCrypto
// initiator, ReceiveDemux unseal, TransportSender seal,
// ReliableCtrlEndpoint over ArqEndpoint<ClientClock> — SURVIVES the
// W-G4 fault model against a LyteWire host build-up: 5% seeded loss
// plus duplication and jitter-driven reorder through SimNet,
// RTT-adaptive retransmit, exactly-once in-order delivery both
// directions — while the deliberately ARQ-exempt traffic stays exempt
// (beacons pass the one-byte peek untouched; a sealed IDR request
// still lands mid-storm on its fire-and-forget path).
//
// The far end here is a host stand-in assembled from LyteWire parts:
// NoiseSession responder plus its own ArqEndpoint<HostClock>, configured
// to pack conn-id-tagged CTRL at the session's real 1101 B plaintext
// ceiling — exactly the HS-8 Session's discipline, met
// through the same frame codecs the frozen arq-v1 vectors pin. The
// host-side ArqCtrlGateTests runs the mirror-image pairing with the real
// Session; this gate deliberately retains its isolated Wire peer.

final class ReliableCtrlGateTests: XCTestCase {

    // MARK: The host stand-in

    /// The host role, sans-IO: Noise responder, seal/unseal, a
    /// host-clock ArqEndpoint, conn-id tagging, carrier-sized packing, and
    /// the bookkeeping the gate asserts against.
    private final class HostStandIn: NoiseHandshakeIO {
        let staticKeys = NoiseKeyPair.generate()
        let connectionId: ConnectionId
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var arq: ArqEndpoint<HostClock>
        var beaconSeq: UInt32 = 0
        private var handshakeOutbox: [[UInt8]] = []

        var received: [(group: ArqGroupId, bytes: [UInt8])] = []
        var oneShotAcks: [ArqGroupId] = []
        var arqIgnored = 0
        /// Byte-identical network duplicates die at the transport's
        /// replay window — before any layer above sees them.
        var replayDrops = 0
        var idrSeen = false
        var echoesSeen = 0
        /// Conn-id TLVs observed on inbound client datagrams — the
        /// every-packet tagging evidence.
        var clientConnIdTags = 0

        init(arqConfig: ArqConfig = ArqConfig()) {
            var rng = SplitMix64(seed: 0xC10_7)
            connectionId = ConnectionId.random(using: &rng)
            var bounded = arqConfig
            bounded.maxDatagramPayloadByteCount = min(
                bounded.maxDatagramPayloadByteCount,
                WireBudget.maxConnectionIdTaggedPlaintextByteCount
            )
            arq = ArqEndpoint(channel: .ctrl, config: bounded)
        }

        // NoiseHandshakeIO — the client's pre-thread handshake window,
        // answered in-process (fault injection starts after; retry
        // under handshake loss is NoiseClientTests' subject).

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
            // Message 2 rides bare (pre-transport) but conn-id-tagged,
            // exactly as the real Session's sendCtrl builds it.
            let carriage = Envelope(
                channel: .ctrl,
                seq: ChannelSeq(rawValue: ctrlSeq),
                frame: FrameNumber(rawValue: 0),
                timestamp: 0,
                fec: 0,
                extensions: [connectionId.wireExtension]
            )
            ctrlSeq &+= 1
            handshakeOutbox.append(try carriage.encode(
                payload: [CtrlMessageType.noiseHandshake2] + message2))
        }

        func receiveDatagram(timeoutMilliseconds: Int) throws -> [UInt8]? {
            handshakeOutbox.isEmpty ? nil : handshakeOutbox.removeFirst()
        }

        // The established send path: conn-id-tagged envelope, header
        // bytes as AAD, sealed under the transport.

        func sealedCtrl(body: [UInt8], hostMicros: UInt64) throws -> [UInt8] {
            let envelope = Envelope(
                channel: .ctrl,
                seq: ChannelSeq(rawValue: ctrlSeq),
                frame: FrameNumber(rawValue: 0),
                timestamp: hostMicros,
                fec: 0,
                extensions: [connectionId.wireExtension]
            )
            ctrlSeq &+= 1
            let header = try envelope.encode(payload: [])
            let payload = try transport!.seal(
                plaintext: body[...], aad: header[...], envelope: envelope
            )
            let datagram = try envelope.encode(payload: payload)
            XCTAssertLessThanOrEqual(
                datagram.count, WireBudget.maxDatagramByteCount,
                "host datagram over the 1152 B budget"
            )
            return datagram
        }

        /// One 1 Hz-style clock beacon — ARQ-exempt by construction,
        /// and the datagram that teaches the client the conn-id.
        func beaconDatagram(hostMicros: UInt64) throws -> [UInt8] {
            let beacon = ClockBeacon(
                beaconSeq: beaconSeq,
                hostSend: HostTimestamp(microseconds: hostMicros),
                lastEcho: nil
            )
            beaconSeq &+= 1
            return try sealedCtrl(body: beacon.encode(), hostMicros: hostMicros)
        }

        /// One client datagram: unseal, verify the conn-id tag, then the
        /// one-byte peek — ARQ bytes to the endpoint, exempt types
        /// recorded, everything else surfaced loud.
        func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            XCTAssertLessThanOrEqual(bytes.count, WireBudget.maxDatagramByteCount)
            let (envelope, payload) = try Envelope.decode(bytes)
            let aad = bytes[bytes.startIndex..<payload.startIndex]
            let plaintext: [UInt8]
            do {
                plaintext = try transport!.unseal(
                    wirePayload: payload, aad: aad, envelope: envelope
                )
            } catch NoiseError.replayedSequence, NoiseError.staleSequence {
                replayDrops += 1
                return
            }
            switch plaintext.first {
            case CtrlMessageType.arqSegment, CtrlMessageType.arqAck:
                XCTAssertLessThanOrEqual(
                    plaintext.count,
                    WireBudget.maxConnectionIdTaggedPlaintextByteCount,
                    "client ARQ payload over the TLV+tag-adjusted budget"
                )
                // The every-packet rule, client-side: once the client
                // has learned the session's conn-id, its reliable
                // datagrams must carry it back.
                if let claimed = try ConnectionId.decode(
                    extensions: envelope.extensions) {
                    XCTAssertEqual(claimed, connectionId,
                                   "the client must echo the session's conn-id")
                    clientConnIdTags += 1
                }
                for event in arq.ingest(
                    payload: plaintext,
                    now: HostTimestamp(microseconds: nowMicros)
                ) {
                    switch event {
                    case .message(let group, let bytes):
                        received.append((group, bytes))
                    case .oneShotAcknowledged(let group):
                        oneShotAcks.append(group)
                    case .ignored:
                        arqIgnored += 1
                    }
                }
            case CtrlMessageType.idrRequest:
                idrSeen = true
            case CtrlMessageType.beaconEcho:
                echoesSeen += 1
            default:
                XCTFail("unexpected client CTRL type \(plaintext.first ?? 0)")
            }
        }

        /// Drains the host endpoint's carrier-sized output into sealed
        /// CTRL datagrams. ArqEndpoint owns the only packing pass.
        func pollOut(nowMicros: UInt64) throws -> [[UInt8]] {
            let (payloads, _) = arq.poll(
                now: HostTimestamp(microseconds: nowMicros)
            )
            return try payloads.map {
                try sealedCtrl(body: $0, hostMicros: nowMicros)
            }
        }
    }

    // MARK: The client harness

    /// The REAL client stack under test, plus the routing the CLI does:
    /// demux → CTRL → reliable endpoint's one-byte peek → beacon
    /// fall-through.
    private final class Harness {
        let host: HostStandIn
        let crypto: NoiseTransportCrypto
        let demux: ReceiveDemux
        let sender: TransportSender
        let reliable: ReliableCtrlEndpoint
        /// Everything the client transmitted, in order (the SimNet
        /// forwarding cursor reads from here).
        let outbound: LockedDatagrams
        private let capturedEvents: LockedEvents

        var beaconSeqsSeen: [UInt32] = []
        var replayDrops = 0

        init(arqConfig: ArqConfig = ArqConfig()) throws {
            let host = HostStandIn(arqConfig: arqConfig)
            let crypto = try NoiseTransportCrypto(
                hostAddress: "10.0.0.249", hostPort: 41_005,
                hostStaticPublicKey: host.staticKeys.publicKey,
                attempts: 2, attemptTimeoutMilliseconds: 200)
            try crypto.performHandshake(io: host)
            let outbound = LockedDatagrams()
            let sender = TransportSender(crypto: crypto, transmit: {
                outbound.append($0)
                return true
            })
            let captured = LockedEvents()
            self.host = host
            self.crypto = crypto
            self.demux = ReceiveDemux(crypto: crypto)
            self.sender = sender
            self.reliable = ReliableCtrlEndpoint(
                sender: sender,
                config: arqConfig,
                onEvent: { captured.append($0) })
            self.outbound = outbound
            self.capturedEvents = captured
        }

        /// One host datagram through the real receive path: demux
        /// unseal, then the CLI's CTRL routing. Fails loud on anything
        /// unexpected; byte-identical duplicates die at the replay
        /// window and are counted.
        func absorb(_ bytes: [UInt8], tMicros: UInt64) {
            XCTAssertLessThanOrEqual(bytes.count, WireBudget.maxDatagramByteCount)
            let outcome = demux.ingest(
                datagram: bytes[...], arrivalMicroseconds: tMicros)
            switch outcome {
            case .accepted(let envelope, let payload):
                XCTAssertEqual(envelope.channel, .ctrl)
                if reliable.handleCtrlDatagram(
                    envelope: envelope, payload: payload,
                    now: ClientTimestamp(microseconds: tMicros)) {
                    return
                }
                if payload.first == CtrlMessageType.clockBeacon,
                   let beacon = try? ClockBeacon.decode(payload) {
                    beaconSeqsSeen.append(beacon.beaconSeq)
                } else {
                    XCTFail("unexpected host CTRL type \(payload.first ?? 0)")
                }
            case .unsealFailed:
                replayDrops += 1
            default:
                XCTFail("host datagram refused: \(outcome)")
            }
        }

        var deliveredMessages: [(group: ArqGroupId, bytes: [UInt8])] {
            capturedEvents.all.compactMap {
                if case .message(let group, let bytes) = $0 {
                    return (group, bytes)
                }
                return nil
            }
        }

        var oneShotAcks: [ArqGroupId] {
            capturedEvents.all.compactMap {
                if case .oneShotAcknowledged(let group) = $0 { return group }
                return nil
            }
        }
    }

    private final class LockedDatagrams: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[UInt8]] = []
        func append(_ d: [UInt8]) { lock.lock(); stored.append(d); lock.unlock() }
        var all: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return stored }
        var count: Int { lock.lock(); defer { lock.unlock() }; return stored.count }
    }

    private final class LockedEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ArqEvent] = []
        func append(_ e: ArqEvent) { lock.lock(); stored.append(e); lock.unlock() }
        var all: [ArqEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    // MARK: The gate — 5% loss, duplication, reorder, both directions

    func testGateReliableCtrlSurvivesLossDuplicationAndReorder() throws {
        let harness = try Harness()
        let host = harness.host

        // The session-start beacon teaches the client the conn-id
        // before any reliable traffic (as the real host's control FIFO
        // orders it: message 2, then the beacon, then everything else).
        harness.absorb(try host.beaconDatagram(hostMicros: 100), tMicros: 200)
        XCTAssertEqual(harness.reliable.learnedConnectionId, host.connectionId)

        // The W-G4 fault model: 5% loss, 2% duplication, 3 ms base
        // delay with 4 ms jitter — displacement reorder emerges.
        var net = SimNet(
            config: SimNetConfig(
                lossRate: 0.05,
                duplicateRate: 0.02,
                baseDelayMicroseconds: 3_000,
                jitterMicroseconds: 4_000
            ),
            seed: 0xC1_1007
        )

        // Traffic both ways: the ordered stream in mixed sizes (single
        // and multi-segment) plus independent one-shots.
        let sizes = [1, 17, 300, 1_093, 1_500, 2_600]
        let clientStream: [[UInt8]] = (0..<30).map { i in
            [UInt8](repeating: UInt8(truncatingIfNeeded: 0x40 &+ i),
                    count: sizes[i % sizes.count])
        }
        let clientOneShotMessages: [[UInt8]] = [
            [0xC7], [UInt8](repeating: 0xC9, count: 1_400),
        ]
        let hostStream: [[UInt8]] = (0..<30).map { i in
            [UInt8](repeating: UInt8(truncatingIfNeeded: i &+ 1),
                    count: sizes[(i + 3) % sizes.count])
        }
        let hostOneShots: [UInt16: [UInt8]] = [
            1: [0xB1, 0xB1], 2: [UInt8](repeating: 0xB2, count: 2_000),
        ]

        // Traffic drips over ~4.5 virtual seconds (one message every
        // 150 ms each way, one-shots partway in), so the storm spans
        // several beacons and many PTO cycles.
        let sendIntervalMicros: UInt64 = 150_000
        var clientSent = 0
        var hostSent = 0
        var oneShotsSent = false
        var clientOneShotGroups: [ArqGroupId] = []

        // An ARQ-exempt IDR request fired mid-storm proves the exempt
        // fire-and-forget path is untouched by the reliable machinery
        // around it; like the real coalescing requester, it refires
        // until honored (superseded, never retransmitted).
        let idrRequest = IdrRequest(
            requestSeq: 0, frame: FrameNumber(rawValue: 4), coalescedCount: 1
        )
        var idrRefires = 0

        // Host beacons keep flowing through the storm at 1 Hz — the
        // exemption evidence on the client's routing side.
        var nextBeaconAt: UInt64 = 1_000_000

        var t: UInt64 = 1_000 // virtual µs
        var forwarded = harness.outbound.count
        let horizon: UInt64 = 30_000_000
        var converged: UInt64?
        while t < horizon {
            for delivery in net.deliveries(upTo: t) {
                if delivery.destination == 0 {
                    harness.absorb(delivery.bytes, tMicros: t)
                } else {
                    try host.absorb(delivery.bytes, nowMicros: t)
                }
            }

            while clientSent < clientStream.count,
                  t >= UInt64(clientSent) * sendIntervalMicros {
                try harness.reliable.send(
                    clientStream[clientSent],
                    now: ClientTimestamp(microseconds: t))
                clientSent += 1
            }
            while hostSent < hostStream.count,
                  t >= UInt64(hostSent) * sendIntervalMicros {
                try host.arq.send(
                    message: hostStream[hostSent],
                    now: HostTimestamp(microseconds: t))
                hostSent += 1
            }
            if !oneShotsSent, t >= 1_200_000 {
                oneShotsSent = true
                for message in clientOneShotMessages {
                    clientOneShotGroups.append(try harness.reliable.sendOneShot(
                        message, now: ClientTimestamp(microseconds: t)))
                }
                for (group, message) in hostOneShots.sorted(by: { $0.key < $1.key }) {
                    try host.arq.sendOneShot(
                        message: message, group: ArqGroupId(rawValue: group),
                        now: HostTimestamp(microseconds: t))
                }
            }
            if !host.idrSeen, t >= 500_000 + UInt64(idrRefires) * 100_000 {
                idrRefires += 1
                _ = try harness.sender.send(
                    channel: .ctrl,
                    timestamp: ClientTimestamp(microseconds: t),
                    plaintext: idrRequest.encode())
            }
            if t >= nextBeaconAt {
                net.send(from: 1,
                         bytes: try host.beaconDatagram(hostMicros: t),
                         now: t)
                nextBeaconAt += 1_000_000
            }

            // Service both ends' timers, then move due output into the
            // pipe: the client's PTO through tick (production: the
            // self-armed wake), the host's through pollOut.
            harness.reliable.tick(now: ClientTimestamp(microseconds: t))
            while forwarded < harness.outbound.count {
                net.send(from: 0, bytes: harness.outbound.all[forwarded], now: t)
                forwarded += 1
            }
            for datagram in try host.pollOut(nowMicros: t) {
                net.send(from: 1, bytes: datagram, now: t)
            }

            if clientSent == clientStream.count, hostSent == hostStream.count,
               oneShotsSent, host.idrSeen,
               harness.reliable.isQuiescent, host.arq.isQuiescent,
               harness.deliveredMessages.count
                   == hostStream.count + hostOneShots.count,
               host.received.count
                   == clientStream.count + clientOneShotMessages.count,
               net.nextArrivalTime == nil {
                converged = t
                break
            }

            var next = t + 5_000
            if let arrival = net.nextArrivalTime {
                next = min(next, max(arrival, t + 1))
            }
            if let deadline = harness.reliable.nextDeadline {
                next = min(next, max(deadline.microseconds, t + 1))
            }
            t = next
        }

        // ── Convergence, exactly-once, in-order ────────────────────────
        XCTAssertNotNil(converged,
                        "reliable CTRL did not converge within 30 virtual s")
        XCTAssertGreaterThan(net.lostCount, 0, "the storm must be real")
        XCTAssertGreaterThan(net.duplicatedCount, 0)

        // Host→client: the ordered stream exactly once, in order; each
        // one-shot exactly once with its acknowledgment surfaced host-side.
        let clientOrdered = harness.deliveredMessages
            .filter { $0.group == .orderedStream }.map(\.bytes)
        XCTAssertEqual(clientOrdered, hostStream,
                       "host→client stream: exactly once, in order")
        for (group, message) in hostOneShots {
            let hits = harness.deliveredMessages.filter {
                $0.group == ArqGroupId(rawValue: group)
            }
            XCTAssertEqual(hits.count, 1, "one-shot \(group) exactly once")
            XCTAssertEqual(hits.first?.bytes, message)
        }

        // Client→host: the mirror, through the REAL sealed send path.
        let hostOrdered = host.received
            .filter { $0.group == .orderedStream }.map(\.bytes)
        XCTAssertEqual(hostOrdered, clientStream,
                       "client→host stream: exactly once, in order")
        for (group, message) in zip(clientOneShotGroups, clientOneShotMessages) {
            let hits = host.received.filter { $0.group == group }
            XCTAssertEqual(hits.count, 1)
            XCTAssertEqual(hits.first?.bytes, message)
            XCTAssertTrue(harness.oneShotAcks.contains(group),
                          "one-shot \(group.rawValue): the acknowledgment must surface")
        }

        // ── Retransmission is what survived the loss ───────────────────
        let stats = harness.reliable.snapshotStats()
        XCTAssertGreaterThan(
            Int(stats.datagramsSent),
            clientStream.count + clientOneShotMessages.count,
            "retransmits + re-ACKs must exceed the fresh-message count"
        )
        XCTAssertEqual(stats.sendFailures, 0)
        XCTAssertGreaterThan(host.clientConnIdTags, 0)

        // ── Exempt stays exempt ────────────────────────────────────────
        // Beacons fell through the one-byte peek untouched, none seen
        // twice under distinct envelope seqs (byte-identical duplicates
        // died at the replay window before the routing saw them).
        XCTAssertGreaterThan(harness.beaconSeqsSeen.count, 1)
        XCTAssertEqual(
            harness.beaconSeqsSeen.count, Set(harness.beaconSeqsSeen).count,
            "a beacon was retransmitted — exempt traffic entered the ARQ"
        )
        XCTAssertTrue(host.idrSeen,
                      "the exempt IDR request must land mid-storm")

        print("CL-7 gate: \(clientStream.count)+\(clientOneShotMessages.count) client and "
            + "\(hostStream.count)+\(hostOneShots.count) host messages "
            + "exactly-once in-order through 5% loss / 2% dup / 4 ms jitter "
            + "(\(net.lostCount) lost, \(net.duplicatedCount) duplicated of "
            + "\(net.sentCount) datagrams; \(stats.datagramsSent) client ARQ "
            + "datagrams, \(host.clientConnIdTags) conn-id-tagged; converged at "
            + "\(converged.map(String.init) ?? "-") µs virtual; "
            + "\(harness.beaconSeqsSeen.count) beacons through the peek, "
            + "none retransmitted; \(harness.replayDrops)+\(host.replayDrops) "
            + "replay drops)")
    }

    // MARK: PTO retransmit rides the tick machinery

    func testPtoRetransmitServicedThroughTick() throws {
        let harness = try Harness()
        let host = harness.host
        harness.absorb(try host.beaconDatagram(hostMicros: 100), tMicros: 200)
        let cursor = harness.outbound.count

        // One reliable message; its first transmission is "lost" (never
        // delivered to the host).
        var t: UInt64 = 1_000_000
        try harness.reliable.send(
            [CtrlMessageType.idrRequest, 0xEE], // any typed body
            now: ClientTimestamp(microseconds: t))
        XCTAssertEqual(harness.outbound.count, cursor + 1,
                       "one fresh ARQ datagram leaves in the send pass")

        // The endpoint must now expose the PTO deadline — production's
        // self-armed wake fires tick there; tests drive it directly.
        guard let deadline = harness.reliable.nextDeadline else {
            return XCTFail("no deadline armed while a segment is unacknowledged")
        }
        XCTAssertGreaterThan(deadline.microseconds, t)

        // Advancing to the deadline retransmits: a byte-identical
        // segment inside a FRESH datagram (fresh envelope seq, fresh
        // nonce — never a datagram replay).
        t = deadline.microseconds + 1
        harness.reliable.tick(now: ClientTimestamp(microseconds: t))
        XCTAssertEqual(harness.outbound.count, cursor + 2,
                       "the PTO fired one retransmit")
        XCTAssertNotEqual(harness.outbound.all[cursor + 1],
                          harness.outbound.all[cursor],
                          "a retransmit rides a FRESH datagram, never a replay")

        // Deliver the retransmit; the host's ACK completes the exchange.
        try host.absorb(harness.outbound.all[cursor + 1], nowMicros: t)
        XCTAssertEqual(host.received.count, 1)
        XCTAssertEqual(host.received[0].bytes, [CtrlMessageType.idrRequest, 0xEE])
        for datagram in try host.pollOut(nowMicros: t) {
            harness.absorb(datagram, tMicros: t + 1_000)
        }
        XCTAssertTrue(harness.reliable.isQuiescent, "acknowledged → quiescent")
        XCTAssertNil(harness.reliable.nextDeadline)

        // Quiescent means quiescent: ticking far ahead emits nothing.
        let settled = harness.outbound.count
        harness.reliable.tick(now: ClientTimestamp(microseconds: t + 5_000_000))
        XCTAssertEqual(harness.outbound.count, settled,
                       "a quiescent endpoint emits no datagrams, forever")
    }

    // MARK: Carrier-sized packing, conn-id tagging, and ACK piggyback

    func testArqOutputPacksOnceAtTheSessionBudgetAndKeepsThePiggyback() throws {
        // 548 B bodies make two 556 B frames exceed the session's real
        // 1101 B ceiling. ArqEndpoint must emit two carrier-sized payloads
        // directly; nothing downstream may decode and re-cut them. A
        // 2-segment send window then stages the piggyback: the host
        // datagram that opens the window carries a segment of its own,
        // so the very next client pass owes an ACK AND has queued
        // segments — they must leave in one datagram, ACK first.
        let harness = try Harness(arqConfig: ArqConfig(
            sendWindowSegments: 2, maxSegmentBodyByteCount: 548))
        let host = harness.host
        harness.absorb(try host.beaconDatagram(hostMicros: 100), tMicros: 200)
        let cursor = harness.outbound.count

        /// Unseals one client CTRL datagram into its ARQ frames,
        /// holding the budget and tagging assertions on the way through.
        func arqFrames(_ datagram: [UInt8]) throws -> [ArqFrame] {
            XCTAssertLessThanOrEqual(datagram.count, WireBudget.maxDatagramByteCount)
            let (envelope, payload) = try Envelope.decode(datagram[...])
            XCTAssertEqual(
                try ConnectionId.decode(extensions: envelope.extensions),
                host.connectionId,
                "every client ARQ datagram carries the learned conn-id"
            )
            let aad = datagram[datagram.startIndex..<(datagram.count - payload.count)]
            let plaintext = try host.transport!.unseal(
                wirePayload: payload, aad: aad, envelope: envelope)
            XCTAssertLessThanOrEqual(
                plaintext.count,
                WireBudget.maxConnectionIdTaggedPlaintextByteCount,
                "an ARQ datagram burst the session's plaintext budget")
            return try ArqFrame.decodeAll(plaintext)
        }

        // Four segments queued; the window lets two fly. They leave the
        // endpoint as two datagrams in its one and only packing pass.
        let message = [UInt8](repeating: 0x77, count: 4 * 548)
        var t: UInt64 = 1_000_000
        try harness.reliable.send(message, now: ClientTimestamp(microseconds: t))
        let firstFlight = Array(harness.outbound.all[cursor...])
        XCTAssertEqual(
            firstFlight.count, 2,
            "the endpoint must pack two in-budget datagrams directly")
        var frames: [ArqFrame] = []
        for datagram in firstFlight {
            let decoded = try arqFrames(datagram)
            frames += decoded
            // The host also ingests, so its ACK below is honest.
            for frame in decoded {
                _ = host.arq.ingest(
                    payload: frame.encode(),
                    now: HostTimestamp(microseconds: t))
            }
        }

        // The host acknowledges AND sends its own message — one
        // datagram carrying [ACK, segment], the endpoint's packing.
        t += 10_000
        try host.arq.send(
            message: [0x42, 0x42, 0x42],
            now: HostTimestamp(microseconds: t))
        let opening = try host.pollOut(nowMicros: t)
        XCTAssertEqual(opening.count, 1)
        let preCursor = harness.outbound.count
        for datagram in opening {
            harness.absorb(datagram, tMicros: t)
        }
        XCTAssertTrue(harness.deliveredMessages.contains {
            $0.group == .orderedStream && $0.bytes == [0x42, 0x42, 0x42]
        })

        // The window just opened and an ACK is owed: the client's next
        // flight leads with the ACK sharing a datagram with segment 2
        // (the piggyback), segment 3 overflowing into datagram 2.
        let secondFlight = Array(harness.outbound.all[preCursor...])
        XCTAssertEqual(secondFlight.count, 2)
        let leadFrames = try arqFrames(secondFlight[0])
        guard case .ack = leadFrames.first else {
            return XCTFail("the ACK must ride ahead of the segments")
        }
        XCTAssertGreaterThan(
            leadFrames.count, 1,
            "the ACK must share its datagram with a segment (the piggyback)")
        frames += leadFrames
        frames += try arqFrames(secondFlight[1])

        let segments = frames.compactMap { frame -> ArqSegment? in
            if case .segment(let segment) = frame { return segment }
            return nil
        }
        XCTAssertEqual(segments.count, 4, "2192 B at 548 B bodies = 4 segments")
        XCTAssertEqual(
            segments.map(\.body).reduce([], +), message,
            "packing datagram boundaries must not touch the bytes")
    }

    /// The default config is carrier-bounded at init: no caller-provided
    /// payload or segment ceiling may burst the session's CTRL budget once
    /// the TLV and tag ride along.
    func testDefaultSegmentBodiesAreClampedToTheSessionBudget() throws {
        let harness = try Harness()
        let host = harness.host
        harness.absorb(try host.beaconDatagram(hostMicros: 100), tMicros: 200)
        let cursor = harness.outbound.count

        // A message one byte over the carrier-sized body (1093) must split
        // into two segments, every datagram within every budget.
        let t: UInt64 = 1_000_000
        try harness.reliable.send(
            [UInt8](repeating: 0x55, count: 1_094),
            now: ClientTimestamp(microseconds: t))
        let fresh = Array(harness.outbound.all[cursor...])
        XCTAssertEqual(fresh.count, 2, "1094 B > one carrier-sized 1093 B body")
        for datagram in fresh {
            XCTAssertLessThanOrEqual(datagram.count, WireBudget.maxDatagramByteCount)
            try host.absorb(datagram, nowMicros: t)
        }
        XCTAssertEqual(host.received.count, 1)
        XCTAssertEqual(host.received[0].bytes.count, 1_094)
    }

    func testCallerSmallerCarrierCeilingIsPreserved() throws {
        let callerCeiling = 900
        let harness = try Harness(arqConfig: ArqConfig(
            sendWindowSegments: 2,
            maxSegmentBodyByteCount: 448,
            maxDatagramPayloadByteCount: callerCeiling
        ))
        let host = harness.host
        harness.absorb(try host.beaconDatagram(hostMicros: 100), tMicros: 200)
        let cursor = harness.outbound.count

        try harness.reliable.send(
            [UInt8](repeating: 0x66, count: 896),
            now: ClientTimestamp(microseconds: 1_000_000)
        )
        XCTAssertEqual(
            harness.outbound.count - cursor, 2,
            "the client carrier must not widen a caller's smaller ceiling"
        )
    }

    /// Before the first host datagram there is no conn-id to echo; the
    /// budget is reserved anyway, and the tag appears the moment the
    /// TLV is learned.
    func testConnectionIdIsLearnedNotInvented() throws {
        let harness = try Harness()
        let host = harness.host
        XCTAssertNil(harness.reliable.learnedConnectionId)

        // A send before any host datagram leaves untagged — and still
        // within the reserved 1101 B ceiling.
        let t: UInt64 = 500_000
        try harness.reliable.send([0x7F, 0x01],
                                  now: ClientTimestamp(microseconds: t))
        let first = harness.outbound.all.last!
        let (envelope, _) = try Envelope.decode(first[...])
        XCTAssertNil(try ConnectionId.decode(extensions: envelope.extensions))

        // The first tagged host datagram teaches the id; the next
        // client ARQ datagram (here: the PTO retransmit) carries it.
        harness.absorb(try host.beaconDatagram(hostMicros: 600_000),
                       tMicros: 600_000)
        XCTAssertEqual(harness.reliable.learnedConnectionId, host.connectionId)
        guard let deadline = harness.reliable.nextDeadline else {
            return XCTFail("a deadline must be armed")
        }
        harness.reliable.tick(
            now: ClientTimestamp(microseconds: deadline.microseconds + 1))
        let retransmit = harness.outbound.all.last!
        let (tagged, _) = try Envelope.decode(retransmit[...])
        XCTAssertEqual(try ConnectionId.decode(extensions: tagged.extensions),
                       host.connectionId)
    }
}
