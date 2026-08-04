import XCTest
import HostCore
import HostWire
import LyteWire
import LyteWireTestKit

// THE GATE (build plan HS-8 row, the host-side half): the session's CTRL
// channel rides the W3 ArqEndpoint and SURVIVES the W-G4 fault model —
// 5% seeded loss plus duplication and jitter-driven reorder through
// SimNet, RTT-adaptive retransmit, exactly-once in-order delivery both
// directions — while the deliberately ARQ-exempt traffic stays exempt:
// beacons are never retransmitted (a late beacon is a lie; a lost one is
// superseded at 1 Hz) and a sealed IDR request still lands mid-storm.
// The other half of the slice's gate — beacon residual <1 ms after 30 s
// — is client-measured, joint with CL-10/CL-7, and runs when the client
// grows its LyteUdpSession leg.
//
// The far end here is a LyteWire client build-up: NoiseSession initiator
// (the HS-7 harness's discipline) plus its own ArqEndpoint<ClientClock>,
// which is exactly what CL-7 will assemble — the two endpoints meet
// through the same frame codecs the frozen arq-v1 vectors pin.

final class ArqCtrlGateTests: XCTestCase {

    private static let rateBPS = 20_000_000

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_004,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    // MARK: The ARQ-capable loopback client

    /// The client role, sans-IO: Noise initiator, unseal, a client-clock
    /// ArqEndpoint, and the bookkeeping the gate asserts against.
    private struct ArqClient {
        var noise: NoiseSession
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var arq = ArqEndpoint<ClientClock>(channel: .ctrl)
        let staticKeys: NoiseKeyPair

        var received: [(group: ArqGroupId, bytes: [UInt8])] = []
        var oneShotAcks: [ArqGroupId] = []
        var beaconSeqsSeen: [UInt32] = []
        var arqIgnored = 0
        /// Byte-identical network duplicates die at the transport's
        /// replay window — before any layer above sees them.
        var replayDrops = 0

        init(hostStaticPublicKey: [UInt8]) throws {
            staticKeys = NoiseKeyPair.generate()
            noise = try NoiseSession(
                role: .initiator,
                staticKeys: staticKeys,
                remoteStaticPublicKey: hostStaticPublicKey
            )
        }

        mutating func message1Datagram(clientMicros: UInt64) throws -> [UInt8] {
            let message1 = try noise.writeMessage1()
            return try ctrlDatagram(
                body: [CtrlMessageType.noiseHandshake1] + message1,
                sealed: false,
                clientMicros: clientMicros
            )
        }

        mutating func ctrlDatagram(
            body: [UInt8], sealed: Bool, clientMicros: UInt64
        ) throws -> [UInt8] {
            let envelope = Envelope(
                channel: .ctrl,
                seq: ChannelSeq(rawValue: ctrlSeq),
                frame: FrameNumber(rawValue: 0),
                timestamp: clientMicros,
                fec: 0
            )
            ctrlSeq &+= 1
            guard sealed else { return try envelope.encode(payload: body) }
            let header = try envelope.encode(payload: [])
            let payload = try transport!.seal(
                plaintext: body[...], aad: header[...], envelope: envelope
            )
            return try envelope.encode(payload: payload)
        }

        /// One host datagram: unseal (bare message 2 completes the
        /// handshake), then the one-byte peek — ARQ bytes to the
        /// endpoint, beacons recorded, everything else surfaced loud.
        mutating func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            XCTAssertLessThanOrEqual(
                bytes.count, WireBudget.maxDatagramByteCount,
                "host datagram over the 1152 B budget"
            )
            let (envelope, payload) = try Envelope.decode(bytes)
            XCTAssertEqual(envelope.channel, .ctrl)
            if transport == nil {
                XCTAssertEqual(payload.first, CtrlMessageType.noiseHandshake2)
                _ = try noise.readMessage2(payload.dropFirst())
                transport = try noise.makeTransport()
                return
            }
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
                    "ARQ payload over the session's TLV+tag-adjusted budget"
                )
                for event in arq.ingest(
                    payload: plaintext,
                    now: ClientTimestamp(microseconds: nowMicros)
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
            case CtrlMessageType.clockBeacon:
                beaconSeqsSeen.append(try ClockBeacon.decode(plaintext).beaconSeq)
            default:
                XCTFail("unexpected host CTRL type \(plaintext.first ?? 0)")
            }
        }

        /// Drains the client endpoint's due output into sealed CTRL
        /// datagrams (no conn-id TLV client-side, so poll's bare-budget
        /// packing already fits: 24 + 1112 + 16 = 1152 exactly).
        mutating func pollOut(nowMicros: UInt64) throws -> [[UInt8]] {
            let (payloads, _) = arq.poll(
                now: ClientTimestamp(microseconds: nowMicros)
            )
            return try payloads.map {
                try ctrlDatagram(body: $0, sealed: true, clientMicros: nowMicros)
            }
        }
    }

    // MARK: Shared harness

    /// Handshake, run directly (fault injection starts after — retry
    /// under handshake loss is the client's timer, not this slice).
    /// Returns the session, the client with its transport live, the
    /// sink, and the virtual instant the setup finished at. The W4b
    /// lifecycle machine's timers are pushed past the horizon by
    /// default: this suite gates the ARQ sublayer, and the machine has
    /// its own gate (SessionLifecycleGateTests).
    private func establish(
        arqConfig: ArqConfig = ArqConfig(),
        beaconIntervalNS: UInt64 = 1_000_000_000,
        sent: @escaping () -> [VideoChannelDatagram],
        append: @escaping (VideoChannelDatagram) -> Void
    ) throws -> (session: Session, client: ArqClient) {
        let hostStatic = NoiseKeyPair.generate()
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: beaconIntervalNS,
                arq: arqConfig,
                lifecycle: SessionMachineConfig(
                    blackoutSilenceMicroseconds: 1 << 44,
                    livenessTimeoutMicroseconds: 1 << 45
                )
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x88),
            send: append
        )
        var client = try ArqClient(hostStaticPublicKey: hostStatic.publicKey)
        _ = session.receive(
            try client.message1Datagram(clientMicros: 500),
            from: Self.tupleA, now: 0, hostMicroseconds: 0
        )
        XCTAssertEqual(session.phase, .established)
        var now: UInt64 = 0
        session.pump(now: now)
        while let wake = session.nextWake(now: now), wake < 5_000_000 {
            now = max(now &+ 1, wake)
            _ = session.advance(now: now, hostMicroseconds: now / 1_000)
            session.pump(now: now)
        }
        let handshake = sent()
        XCTAssertEqual(handshake.count, 3,
                       "message 2, session-start beacon, capability declaration")
        try client.absorb(handshake[0].bytes, nowMicros: 600)
        try client.absorb(handshake[1].bytes, nowMicros: 700)
        try client.absorb(handshake[2].bytes, nowMicros: 800)
        XCTAssertNotNil(client.transport)
        // The W7 declaration is the host's first reliable word (HS-8's
        // deferred capabilities item). Acknowledge it and clear the
        // baseline so the gates below start from a quiescent stream.
        XCTAssertEqual(client.received.count, 1)
        XCTAssertEqual(client.received.first?.bytes.first,
                       CtrlMessageType.capabilityDeclaration)
        client.received.removeAll()
        for datagram in try client.pollOut(nowMicros: 900) {
            _ = session.receive(
                datagram, from: Self.tupleA,
                now: 2_000_000, hostMicroseconds: 2_000
            )
        }
        XCTAssertTrue(session.arqIsQuiescent,
                      "declaration acked — quiescent baseline")
        return (session, client)
    }

    // MARK: The gate — 5% loss, duplication, reorder, both directions

    func testGateReliableCtrlSurvivesLossDuplicationAndReorder() throws {
        var sent: [VideoChannelDatagram] = []
        let established = try establish(
            sent: { sent }, append: { sent.append($0) }
        )
        let session = established.session
        var client = established.client
        var forwarded = sent.count // handshake rode outside the pipe

        // The W-G4 fault model: 5% loss, 2% duplication, 3 ms base
        // delay with 4 ms jitter — displacement reorder emerges.
        var net = SimNet(
            config: SimNetConfig(
                lossRate: 0.05,
                duplicateRate: 0.02,
                baseDelayMicroseconds: 3_000,
                jitterMicroseconds: 4_000
            ),
            seed: 0xA59_1004
        )

        // Traffic both ways: the ordered stream in mixed sizes (single
        // and multi-segment) plus independent one-shots.
        let sizes = [1, 17, 300, 1_093, 1_500, 2_600]
        let hostStream: [[UInt8]] = (0..<30).map { i in
            [UInt8](repeating: UInt8(truncatingIfNeeded: i &+ 1),
                    count: sizes[i % sizes.count])
        }
        let hostOneShots: [UInt16: [UInt8]] = [
            1: [0xB1, 0xB1], 2: [UInt8](repeating: 0xB2, count: 2_000),
        ]
        let clientStream: [[UInt8]] = (0..<30).map { i in
            [UInt8](repeating: UInt8(truncatingIfNeeded: 0x40 &+ i),
                    count: sizes[(i + 3) % sizes.count])
        }
        let clientOneShots: [UInt16: [UInt8]] = [
            7: [0xC7], 9: [UInt8](repeating: 0xC9, count: 1_400),
        ]

        // Traffic drips over ~4.5 virtual seconds (one message every
        // 150 ms each way, one-shots partway in), so the storm spans
        // several 1 Hz beacons and many PTO cycles — the exemption
        // evidence is real, not vacuous.
        let sendIntervalMicros: UInt64 = 150_000
        var hostSent = 0
        var clientSent = 0
        var oneShotsSent = false

        // An ARQ-exempt IDR request fired mid-storm proves the exempt
        // path is untouched by the reliable machinery around it; like
        // the real coalescing requester, it refires until honored (a
        // lost request is superseded, never retransmitted).
        let idrRequest = IdrRequest(
            requestSeq: 0, frame: FrameNumber(rawValue: 4), coalescedCount: 1
        )
        var idrSeen = false
        var idrRefires = 0

        var t: UInt64 = 1_000 // virtual µs
        var hostEvents: [SessionEvent] = []
        let horizon: UInt64 = 30_000_000 // the gate's 30 virtual seconds
        var converged: UInt64?
        while t < horizon {
            for delivery in net.deliveries(upTo: t) {
                if delivery.destination == 0 {
                    hostEvents += session.receive(
                        delivery.bytes, from: Self.tupleA,
                        now: t * 1_000, hostMicroseconds: t
                    )
                } else {
                    try client.absorb(delivery.bytes, nowMicros: t)
                }
            }
            idrSeen = idrSeen || hostEvents.contains(.idrRequested(idrRequest))

            while hostSent < hostStream.count,
                  t >= UInt64(hostSent) * sendIntervalMicros {
                try session.sendReliable(
                    hostStream[hostSent], now: t * 1_000, hostMicroseconds: t
                )
                hostSent += 1
            }
            while clientSent < clientStream.count,
                  t >= UInt64(clientSent) * sendIntervalMicros {
                try client.arq.send(
                    message: clientStream[clientSent],
                    now: ClientTimestamp(microseconds: t)
                )
                clientSent += 1
            }
            if !oneShotsSent, t >= 1_200_000 {
                oneShotsSent = true
                for (group, message) in hostOneShots.sorted(by: { $0.key < $1.key }) {
                    try session.sendReliableOneShot(
                        message, group: ArqGroupId(rawValue: group),
                        now: t * 1_000, hostMicroseconds: t
                    )
                }
                for (group, message) in clientOneShots.sorted(by: { $0.key < $1.key }) {
                    try client.arq.sendOneShot(
                        message: message, group: ArqGroupId(rawValue: group),
                        now: ClientTimestamp(microseconds: t)
                    )
                }
            }
            if !idrSeen, t >= 500_000 + UInt64(idrRefires) * 100_000 {
                idrRefires += 1
                net.send(
                    from: 1,
                    bytes: try client.ctrlDatagram(
                        body: idrRequest.encode(), sealed: true, clientMicros: t
                    ),
                    now: t
                )
            }

            hostEvents += session.advance(now: t * 1_000, hostMicroseconds: t)
            session.pump(now: t * 1_000)
            while forwarded < sent.count {
                net.send(from: 0, bytes: sent[forwarded].bytes, now: t)
                forwarded += 1
            }
            for datagram in try client.pollOut(nowMicros: t) {
                net.send(from: 1, bytes: datagram, now: t)
            }

            let hostGot = hostEvents.count {
                if case .reliableCtrl = $0 { return true } else { return false }
            }
            if hostSent == hostStream.count, clientSent == clientStream.count,
               oneShotsSent, idrSeen,
               session.arqIsQuiescent, client.arq.isQuiescent,
               client.received.count == hostStream.count + hostOneShots.count,
               hostGot == clientStream.count + clientOneShots.count,
               net.nextArrivalTime == nil {
                converged = t
                break
            }

            var next = t + 5_000
            if let arrival = net.nextArrivalTime {
                next = min(next, max(arrival, t + 1))
            }
            if let wake = session.nextWake(now: t * 1_000) {
                next = min(next, max(wake / 1_000 + 1, t + 1))
            }
            t = next
        }

        // ── Convergence, exactly-once, in-order ────────────────────────
        XCTAssertNotNil(converged,
                        "reliable CTRL did not converge within 30 virtual s")
        XCTAssertGreaterThan(net.lostCount, 0, "the storm must be real")
        XCTAssertGreaterThan(net.duplicatedCount, 0)

        let clientOrdered = client.received
            .filter { $0.group == .orderedStream }.map(\.bytes)
        XCTAssertEqual(clientOrdered, hostStream,
                       "host→client stream: exactly once, in order")
        for (group, message) in hostOneShots {
            let hits = client.received.filter {
                $0.group == ArqGroupId(rawValue: group)
            }
            XCTAssertEqual(hits.count, 1, "one-shot \(group) exactly once")
            XCTAssertEqual(hits.first?.bytes, message)
        }
        for group in hostOneShots.keys {
            XCTAssertTrue(
                hostEvents.contains(
                    .reliableOneShotAcknowledged(ArqGroupId(rawValue: group))
                ),
                "one-shot \(group): full acknowledgment must surface"
            )
        }

        var hostOrdered: [[UInt8]] = []
        var hostOneShotHits: [UInt16: [[UInt8]]] = [:]
        for event in hostEvents {
            if case .reliableCtrl(let group, let message) = event {
                if group == .orderedStream {
                    hostOrdered.append(message)
                } else {
                    hostOneShotHits[group.rawValue, default: []].append(message)
                }
            }
        }
        XCTAssertEqual(hostOrdered, clientStream,
                       "client→host stream: exactly once, in order")
        for (group, message) in clientOneShots {
            XCTAssertEqual(hostOneShotHits[group], [message])
        }

        // ── Retransmission is what survived the loss: everything was
        // delivered even though the pipe dropped real datagrams, and the
        // host emitted strictly more ARQ datagrams than its messages
        // needed fresh (retransmits + re-ACKs under duplication).
        XCTAssertGreaterThan(
            session.counters.arqDatagramsSent,
            hostStream.count + hostOneShots.count
        )

        // ── Exempt stays exempt ────────────────────────────────────────
        // A beacon seq arriving twice under distinct envelope seqs would
        // be a retransmission (byte-identical network duplicates die at
        // the replay window before the beacon layer). None may exist.
        XCTAssertEqual(
            client.beaconSeqsSeen.count, Set(client.beaconSeqsSeen).count,
            "a beacon was retransmitted — exempt traffic entered the ARQ"
        )
        XCTAssertLessThanOrEqual(
            client.beaconSeqsSeen.count, session.counters.beaconsSent,
            "lost beacons stay lost; the next 1 Hz send supersedes"
        )
        XCTAssertTrue(
            hostEvents.contains(.idrRequested(idrRequest)),
            "the exempt IDR request must land mid-storm"
        )

        print("HS-8 gate: \(hostStream.count)+\(hostOneShots.count) host and "
            + "\(clientStream.count)+\(clientOneShots.count) client messages "
            + "exactly-once in-order through 5% loss / 2% dup / 4 ms jitter "
            + "(\(net.lostCount) lost, \(net.duplicatedCount) duplicated of "
            + "\(net.sentCount) datagrams; \(session.counters.arqDatagramsSent) "
            + "host ARQ datagrams; converged at \(converged.map(String.init) ?? "-") µs "
            + "virtual; \(client.beaconSeqsSeen.count)/"
            + "\(session.counters.beaconsSent) beacons, none retransmitted)")
    }

    // MARK: PTO retransmit rides the session's wake machinery

    func testPtoRetransmitServicedThroughNextWakeAndAdvance() throws {
        var sent: [VideoChannelDatagram] = []
        // A beacon interval past the test's horizon keeps `advance`
        // emissions purely ARQ, so datagram counting stays exact.
        let established = try establish(
            beaconIntervalNS: 1 << 62,
            sent: { sent }, append: { sent.append($0) }
        )
        let session = established.session
        var client = established.client
        var cursor = sent.count

        // One reliable message; its first transmission is "lost" (never
        // delivered to the client).
        var t: UInt64 = 1_000_000
        try session.sendReliable(
            [CtrlMessageType.idrRequest, 0xEE], // any typed body
            now: t * 1_000, hostMicroseconds: t
        )
        session.pump(now: t * 1_000)
        XCTAssertEqual(sent.count, cursor + 1, "one fresh ARQ datagram")
        cursor = sent.count

        // The session must now expose the PTO deadline through nextWake
        // — on the Linux host, the idle-floor tick services it.
        guard let wake = session.nextWake(now: t * 1_000) else {
            return XCTFail("no wake armed while a segment is unacknowledged")
        }
        XCTAssertGreaterThan(wake, t * 1_000)

        // Advancing to the deadline retransmits, byte-identical segment
        // in a fresh datagram (fresh envelope seq, fresh nonce).
        t = wake / 1_000 + 1
        _ = session.advance(now: t * 1_000, hostMicroseconds: t)
        session.pump(now: t * 1_000)
        XCTAssertEqual(sent.count, cursor + 1, "the PTO fired one retransmit")
        XCTAssertNotEqual(sent[cursor].bytes, sent[cursor - 1].bytes,
                          "a retransmit rides a FRESH datagram, never a replay")

        // Deliver the retransmit; the ACK completes the exchange.
        try client.absorb(sent[cursor].bytes, nowMicros: t)
        XCTAssertEqual(client.received.count, 1)
        XCTAssertEqual(client.received[0].bytes, [CtrlMessageType.idrRequest, 0xEE])
        for datagram in try client.pollOut(nowMicros: t) {
            _ = session.receive(
                datagram, from: Self.tupleA,
                now: t * 1_000 + 1_000, hostMicroseconds: t + 1
            )
        }
        XCTAssertTrue(session.arqIsQuiescent, "acknowledged → quiescent")

        // Quiescent means quiescent: advancing far produces nothing.
        let settled = sent.count
        t += 5_000_000
        _ = session.advance(now: t * 1_000, hostMicroseconds: t)
        session.pump(now: t * 1_000)
        XCTAssertEqual(sent.count, settled,
                       "a quiescent endpoint emits no datagrams, forever")
    }

    // MARK: Carrier-sized packing and the ACK piggyback

    func testArqOutputPacksOnceAtTheSessionBudgetAndKeepsThePiggyback() throws {
        // 548 B bodies make two 556 B frames. The endpoint receives the
        // session's connection-id-tagged ceiling, so it must emit those as
        // two payloads immediately — never form a bare-budget payload that
        // a downstream layer must re-cut. A
        // 2-segment send window then stages the piggyback: the client
        // datagram that opens the window carries a segment of its own,
        // so the very next host poll owes an ACK AND has queued
        // segments — they must leave in one datagram, ACK first.
        var sent: [VideoChannelDatagram] = []
        let established = try establish(
            arqConfig: ArqConfig(
                sendWindowSegments: 2, maxSegmentBodyByteCount: 548
            ),
            sent: { sent }, append: { sent.append($0) }
        )
        let session = established.session
        var client = established.client
        let cursor = sent.count

        /// Unseals one host CTRL datagram into its ARQ frames, holding
        /// the budget assertions on the way through.
        func arqFrames(_ datagram: VideoChannelDatagram) throws -> [ArqFrame] {
            XCTAssertLessThanOrEqual(
                datagram.bytes.count, WireBudget.maxDatagramByteCount
            )
            let (envelope, payload) = try Envelope.decode(datagram.bytes)
            let aad = datagram.bytes[
                datagram.bytes.startIndex
                    ..< datagram.bytes.endIndex - payload.count
            ]
            let plaintext = try client.transport!.unseal(
                wirePayload: payload, aad: aad, envelope: envelope
            )
            XCTAssertLessThanOrEqual(
                plaintext.count,
                WireBudget.maxConnectionIdTaggedPlaintextByteCount,
                "an ARQ datagram burst the session's plaintext budget"
            )
            return try ArqFrame.decodeAll(plaintext)
        }

        // Four segments queued; the window lets two fly. The endpoint must
        // produce two carrier-sized datagrams in its first and only packing.
        let message = [UInt8](repeating: 0x77, count: 4 * 548)
        var t: UInt64 = 1_000_000
        try session.sendReliable(message, now: t * 1_000, hostMicroseconds: t)
        session.pump(now: t * 1_000)
        let firstFlight = Array(sent[cursor...])
        XCTAssertEqual(
            firstFlight.count, 2,
            "the endpoint must pack directly at the carrier ceiling"
        )
        var frames: [ArqFrame] = []
        for datagram in firstFlight {
            let decoded = try arqFrames(datagram)
            frames += decoded
            // The client also ingests, so its ACK below is honest.
            for frame in decoded {
                _ = client.arq.ingest(
                    payload: frame.encode(),
                    now: ClientTimestamp(microseconds: t)
                )
            }
        }

        // The client acknowledges AND sends its own message — one
        // datagram carrying [ACK, segment], the endpoint's packing.
        t += 10_000
        try client.arq.send(
            message: [0x42, 0x42, 0x42],
            now: ClientTimestamp(microseconds: t)
        )
        let opening = try client.pollOut(nowMicros: t)
        XCTAssertEqual(opening.count, 1)
        let preCursor = sent.count
        var hostEvents = [SessionEvent]()
        for datagram in opening {
            hostEvents += session.receive(
                datagram, from: Self.tupleA,
                now: t * 1_000, hostMicroseconds: t
            )
        }
        session.pump(now: t * 1_000)
        XCTAssertTrue(hostEvents.contains(
            .reliableCtrl(group: .orderedStream, message: [0x42, 0x42, 0x42])
        ))

        // The window just opened and an ACK is owed: the host's next
        // flight leads with the ACK sharing a datagram with segment 2
        // (the piggyback), segment 3 overflowing into datagram 2.
        let secondFlight = Array(sent[preCursor...])
        XCTAssertEqual(secondFlight.count, 2)
        let leadFrames = try arqFrames(secondFlight[0])
        guard case .ack = leadFrames.first else {
            return XCTFail("the ACK must ride ahead of the segments")
        }
        XCTAssertGreaterThan(
            leadFrames.count, 1,
            "the ACK must share its datagram with a segment (the piggyback)"
        )
        frames += leadFrames
        frames += try arqFrames(secondFlight[1])

        let segments = frames.compactMap { frame -> ArqSegment? in
            if case .segment(let segment) = frame { return segment }
            return nil
        }
        XCTAssertEqual(segments.count, 4, "2192 B at 548 B bodies = 4 segments")
        XCTAssertEqual(
            segments.map(\.body).reduce([], +), message,
            "carrier-sized packing must not touch the message bytes"
        )
    }

    /// The default config clamps at init: no caller-provided segment
    /// ceiling may burst the session's CTRL budget.
    func testDefaultSegmentBodiesAreClampedToTheSessionBudget() throws {
        var sent: [VideoChannelDatagram] = []
        let established = try establish(
            sent: { sent }, append: { sent.append($0) }
        )
        let session = established.session
        var client = established.client
        let cursor = sent.count

        let carrierBodyCeiling =
            WireBudget.maxConnectionIdTaggedPlaintextByteCount
                - ArqBounds.segmentHeaderByteCount
        // A message one byte over the endpoint-normalized body ceiling must
        // split into two segments, each datagram within every budget.
        let t: UInt64 = 1_000_000
        try session.sendReliable(
            [UInt8](repeating: 0x55, count: carrierBodyCeiling + 1),
            now: t * 1_000, hostMicroseconds: t
        )
        session.pump(now: t * 1_000)
        let fresh = sent[cursor...]
        XCTAssertEqual(
            fresh.count, 2,
            "one byte beyond the carrier body ceiling must split"
        )
        for datagram in fresh {
            XCTAssertLessThanOrEqual(
                datagram.bytes.count, WireBudget.maxDatagramByteCount
            )
            try client.absorb(datagram.bytes, nowMicros: t)
        }
        XCTAssertEqual(client.received.count, 1)
        XCTAssertEqual(
            client.received[0].bytes.count, carrierBodyCeiling + 1
        )
    }

    func testCallerSmallerCarrierCeilingIsPreserved() throws {
        let callerCeiling = 900
        var sent: [VideoChannelDatagram] = []
        let established = try establish(
            arqConfig: ArqConfig(
                sendWindowSegments: 2,
                maxSegmentBodyByteCount: 448,
                maxDatagramPayloadByteCount: callerCeiling
            ),
            sent: { sent }, append: { sent.append($0) }
        )
        let cursor = sent.count
        let t: UInt64 = 1_000_000
        try established.session.sendReliable(
            [UInt8](repeating: 0x66, count: 896),
            now: t * 1_000, hostMicroseconds: t
        )
        established.session.pump(now: t * 1_000)
        XCTAssertEqual(
            sent[cursor...].count, 2,
            "the Session must not widen a caller's smaller carrier ceiling"
        )
    }

    // MARK: API guards

    func testReliableSendRefusesBeforeEstablishmentAndBadGroups() throws {
        // Before the handshake there is no transport to seal under.
        let hostStatic = NoiseKeyPair.generate()
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: Self.rateBPS
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x1)
        ) { _ in }
        XCTAssertThrowsError(try session.sendReliable(
            [0x10], now: 0, hostMicroseconds: 0
        )) {
            XCTAssertEqual($0 as? SessionError, .notEstablished)
        }

        // Established: the endpoint's own refusals surface unchanged.
        var sent: [VideoChannelDatagram] = []
        let (live, _) = try establish(
            sent: { sent }, append: { sent.append($0) }
        )
        XCTAssertThrowsError(try live.sendReliable(
            [], now: 1_000, hostMicroseconds: 1
        )) {
            XCTAssertEqual($0 as? ArqSendError, .emptyMessage)
        }
        XCTAssertThrowsError(try live.sendReliableOneShot(
            [0x10], group: .orderedStream, now: 1_000, hostMicroseconds: 1
        )) {
            XCTAssertEqual($0 as? ArqSendError, .orderedStreamGroupId)
        }
        try live.sendReliableOneShot(
            [0x10], group: ArqGroupId(rawValue: 5),
            now: 1_000, hostMicroseconds: 1
        )
        XCTAssertThrowsError(try live.sendReliableOneShot(
            [0x10], group: ArqGroupId(rawValue: 5),
            now: 1_000, hostMicroseconds: 1
        )) {
            XCTAssertEqual(
                $0 as? ArqSendError,
                .oneShotGroupNotAscending(ArqGroupId(rawValue: 5))
            )
        }
    }
}
