import XCTest
import HostCore
import HostWire
import LyteWire
import LyteWireTestKit

// THE GATE (build plan HS-13 row, the in-tree half — the live leg runs
// on the reference host): the wire→injection path. Pinned behaviors:
//
//   • the 0x16/0x17 codecs are byte-pinned against hand-built layouts
//     (mirror-then-promote: these bytes move to Wire/ with CL-9,
//     unchanged) and never trap on hostile bytes;
//   • input events ride the sealed reliable CTRL stream through the
//     W-G4 fault model (5% loss, 2% dup, jitter reorder) and arrive
//     exactly once, IN ORDER — a reordered keystroke is corruption;
//   • every injection report produces exactly one echo tuple back on
//     the client, carrying the true (seq, rx, inject) host-µs stamps,
//     batched ≤ 32 tuples per 0x17 message;
//   • once an injection is reported, every subsequent video frame's
//     shards carry the lastInputSeq TLV (0x03) — per-shard, like the
//     conn-id — and the frame still reassembles byte-exact within the
//     1152 B budget (geometry derives from the real TLV headroom);
//   • an input event arriving in IDLE is the WAKE (W4b's pre-arm rule:
//     mode=active on the reliable stream + next-damage-as-IDR armed) —
//     the notePreArmInput seam HS-11 left unwired now has its caller.
//
// The far end is the SessionLifecycleGateTests discipline: a LyteWire
// client build-up (NoiseSession initiator + ArqEndpoint<ClientClock>) —
// exactly what CL-9 will assemble on top of CL-7.

final class InputGateTests: XCTestCase {

    private static let rateBPS = 20_000_000

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_010,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    // MARK: Codec pins — the bytes CL-9 will speak

    func testInputEventCodecPinsBytes() throws {
        // keyKeycode: KEY_A (30) pressed, seq 7, client µs 0x1122334455.
        let key = InputEvent(
            seq: 7, clientMicroseconds: 0x11_2233_4455,
            body: .keyKeycode(keycode: 30, pressed: true)
        )
        XCTAssertEqual(key.encode(), [
            0x16,                                   // type
            7, 0, 0, 0,                             // seq u32 LE
            0x55, 0x44, 0x33, 0x22, 0x11, 0, 0, 0,  // clientMicros u64 LE
            0x01,                                   // kind keyKeycode
            30, 0, 0, 0,                            // keycode u32 LE
            1,                                      // pressed
        ])
        XCTAssertEqual(try InputEvent.decode(key.encode()), key)

        // pointerMotionAbsolute: f64 bit patterns, LE.
        let move = InputEvent(
            seq: 8, clientMicroseconds: 2,
            body: .pointerMotionAbsolute(x: 512.0, y: 320.25)
        )
        var expected: [UInt8] = [0x16, 8, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0x02]
        for value in [512.0, 320.25] {
            let bits = value.bitPattern
            for shift in stride(from: 0, to: 64, by: 8) {
                expected.append(UInt8(truncatingIfNeeded: bits >> shift))
            }
        }
        XCTAssertEqual(move.encode(), expected)
        XCTAssertEqual(try InputEvent.decode(move.encode()), move)

        // The remaining kinds round-trip.
        for body: InputEvent.Body in [
            .pointerMotionRelative(dx: -3.5, dy: 12.0),
            .pointerButton(button: 0x110, pressed: false),
            .pointerAxis(dx: 0, dy: -45.0, finish: true),
        ] {
            let event = InputEvent(seq: 99, clientMicroseconds: 1_000, body: body)
            XCTAssertEqual(try InputEvent.decode(event.encode()), event)
        }

        // Echo: two tuples, hand-built layout.
        let echo = InputEcho(tuples: [
            InputEchoTuple(seq: 1, receivedMicroseconds: 0x0A,
                           injectedMicroseconds: 0x0B),
            InputEchoTuple(seq: 2, receivedMicroseconds: 0x0C,
                           injectedMicroseconds: 0x0D),
        ])
        XCTAssertEqual(echo.encode(), [
            0x17, 2,
            1, 0, 0, 0,
            0x0A, 0, 0, 0, 0, 0, 0, 0,
            0x0B, 0, 0, 0, 0, 0, 0, 0,
            2, 0, 0, 0,
            0x0C, 0, 0, 0, 0, 0, 0, 0,
            0x0D, 0, 0, 0, 0, 0, 0, 0,
        ])
        XCTAssertEqual(try InputEcho.decode(echo.encode()), echo)

        print("HS-13 gate (codec): 0x16 all five kinds + 0x17 pinned "
            + "byte-exact against hand-built layouts")
    }

    func testHostileInputBytesRejectAndNeverTrap() {
        let good = InputEvent(
            seq: 1, clientMicroseconds: 2,
            body: .keyKeycode(keycode: 30, pressed: true)
        ).encode()

        // Truncations at every length below the minimum.
        for length in 0..<good.count {
            XCTAssertThrowsError(
                try InputEvent.decode(Array(good.prefix(length))),
                "truncation to \(length) bytes must reject"
            )
        }
        // Foreign type byte.
        XCTAssertThrowsError(try InputEvent.decode([0x15] + good.dropFirst()))
        // Unknown kind.
        var badKind = good
        badKind[13] = 0x77
        XCTAssertThrowsError(try InputEvent.decode(badKind))
        // Trailing junk (body length disagrees with the kind).
        XCTAssertThrowsError(try InputEvent.decode(good + [0x00]))
        // A flag byte that is neither 0 nor 1.
        var badFlag = good
        badFlag[18] = 2
        XCTAssertThrowsError(try InputEvent.decode(badFlag))
        // Reserved axis-flag bits.
        var axis = InputEvent(
            seq: 1, clientMicroseconds: 2,
            body: .pointerAxis(dx: 1, dy: 2, finish: false)
        ).encode()
        axis[axis.count - 1] = 0x82
        XCTAssertThrowsError(try InputEvent.decode(axis))

        // Echo: count 0, count/length mismatch, over-limit count.
        XCTAssertThrowsError(try InputEcho.decode([0x17, 0]))
        XCTAssertThrowsError(try InputEcho.decode([0x17, 1, 1, 2, 3]))
        XCTAssertThrowsError(try InputEcho.decode(
            [0x17, 33] + [UInt8](repeating: 0, count: 33 * 20)
        ))

        // The TLV: duplicate and malformed value.
        let tlv = LastInputSeqTlv.wireExtension(seq: 5)
        XCTAssertEqual(try LastInputSeqTlv.decode(extensions: [tlv]), 5)
        XCTAssertThrowsError(
            try LastInputSeqTlv.decode(extensions: [tlv, tlv])
        )
        XCTAssertThrowsError(try LastInputSeqTlv.decode(
            extensions: [try WireExtension(
                type: HostWireExtensionType.lastInputSeq, value: [1, 2]
            )]
        ))
        XCTAssertNil(try LastInputSeqTlv.decode(extensions: []))
    }

    // MARK: The input-capable loopback client (the CL-9 shape)

    private struct InputClient {
        var noise: NoiseSession
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var arq = ArqEndpoint<ClientClock>(channel: .ctrl)
        let staticKeys: NoiseKeyPair

        var received: [(group: ArqGroupId, bytes: [UInt8])] = []
        var echoTuples: [InputEchoTuple] = []
        var echoMessageTupleCounts: [Int] = []
        /// Unsealed video shards, for the lastInputSeq TLV legs.
        var videoShards: [(envelope: Envelope, plaintext: [UInt8])] = []

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
                sealed: false, clientMicros: clientMicros
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

        mutating func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            XCTAssertLessThanOrEqual(
                bytes.count, WireBudget.maxDatagramByteCount,
                "host datagram over the 1152 B budget"
            )
            let (envelope, payload) = try Envelope.decode(bytes)
            if transport == nil {
                XCTAssertEqual(envelope.channel, .ctrl)
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
                return // network duplicate; routine
            }
            if envelope.channel == .videoActive {
                videoShards.append((envelope, plaintext))
                return
            }
            XCTAssertEqual(envelope.channel, .ctrl)
            switch plaintext.first {
            case CtrlMessageType.arqSegment, CtrlMessageType.arqAck:
                for event in arq.ingest(
                    payload: plaintext,
                    now: ClientTimestamp(microseconds: nowMicros)
                ) {
                    guard case .message(let group, let bytes) = event else {
                        continue
                    }
                    received.append((group, bytes))
                    if bytes.first == HostCtrlMessageType.inputEcho {
                        let echo = try InputEcho.decode(bytes)
                        echoTuples += echo.tuples
                        echoMessageTupleCounts.append(echo.tuples.count)
                    }
                }
            case CtrlMessageType.clockBeacon:
                break // 1 Hz weather
            default:
                XCTFail("unexpected host CTRL type \(plaintext.first ?? 0)")
            }
        }

        mutating func pollOut(nowMicros: UInt64) throws -> [[UInt8]] {
            let (payloads, _) = arq.poll(
                now: ClientTimestamp(microseconds: nowMicros)
            )
            return try payloads.map {
                try ctrlDatagram(body: $0, sealed: true, clientMicros: nowMicros)
            }
        }

        mutating func take(type: UInt8) -> [[UInt8]] {
            let hits = received.filter { $0.bytes.first == type }.map(\.bytes)
            received.removeAll { $0.bytes.first == type }
            return hits
        }
    }

    private final class DatagramBox {
        var datagrams: [VideoChannelDatagram] = []
    }

    /// Handshake + capability exchange, direct pipe (the lifecycle
    /// suite's establish, input-client flavored).
    private func establish(
        clientCapabilities: Capabilities? = .wireDefault,
        lifecycle: SessionMachineConfig = SessionMachineConfig(),
        beaconIntervalNS: UInt64 = 1 << 62
    ) throws -> (session: Session, client: InputClient, box: DatagramBox) {
        let hostStatic = NoiseKeyPair.generate()
        let box = DatagramBox()
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: beaconIntervalNS,
                lifecycle: lifecycle
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x1310),
            send: { box.datagrams.append($0) }
        )
        var client = try InputClient(hostStaticPublicKey: hostStatic.publicKey)
        _ = session.receive(
            try client.message1Datagram(clientMicros: 500),
            from: Self.tupleA, now: 0, hostMicroseconds: 0
        )
        XCTAssertEqual(session.phase, .established)
        session.pump(now: 0)
        if let clientCapabilities {
            var negotiator = CapabilityNegotiator(
                role: .client, local: clientCapabilities
            )
            try client.arq.send(
                message: try negotiator.start().encode(),
                now: ClientTimestamp(microseconds: 1_000)
            )
        }
        return (session, client, box)
    }

    /// One direct exchange pass at virtual µs `t`. Returns fresh host
    /// events; the caller owns reacting to them (that is the shell's
    /// injection loop, simulated).
    private func exchange(
        _ session: Session, _ client: inout InputClient,
        _ box: DatagramBox, forwarded: inout Int, t: UInt64
    ) throws -> [SessionEvent] {
        var events = session.advance(now: t * 1_000, hostMicroseconds: t)
        session.pump(now: t * 1_000)
        while forwarded < box.datagrams.count {
            try client.absorb(box.datagrams[forwarded].bytes, nowMicros: t)
            forwarded += 1
        }
        for datagram in try client.pollOut(nowMicros: t) {
            events += session.receive(
                datagram, from: Self.tupleA,
                now: t * 1_000, hostMicroseconds: t
            )
            session.pump(now: t * 1_000)
            while forwarded < box.datagrams.count {
                try client.absorb(box.datagrams[forwarded].bytes, nowMicros: t)
                forwarded += 1
            }
        }
        return events
    }

    /// Exchange passes 2 ms apart until both ends quiesce, injecting
    /// every delivered input event `injectDelayMicros` after receipt
    /// (the simulated shell).
    private func settle(
        _ session: Session, _ client: inout InputClient,
        _ box: DatagramBox, forwarded: inout Int, t: inout UInt64,
        injectDelayMicros: UInt64 = 300,
        onEvent: (SessionEvent) -> Void = { _ in }
    ) throws {
        var idle = 0
        while idle < 3 {
            t += 2_000
            let before = (forwarded, client.received.count)
            for event in try exchange(
                session, &client, box, forwarded: &forwarded, t: t
            ) {
                if case .inputReceived(let input, let rx) = event {
                    session.noteInputInjected(
                        seq: input.seq,
                        receivedAtMicroseconds: rx,
                        injectedAtMicroseconds: rx + injectDelayMicros
                    )
                }
                onEvent(event)
            }
            idle = (forwarded, client.received.count) == before ? idle + 1 : 0
        }
    }

    /// A synthetic frame-shaped Annex-B blob (the lifecycle suite's).
    private func syntheticFrame(byteCount: Int) -> [UInt8] {
        precondition(byteCount >= 6)
        return [0, 0, 0, 1, 0x02, 0x01]
            + [UInt8](repeating: 0xAA, count: byteCount - 6)
    }

    // MARK: The storm — exactly once, in order, echoed, through W-G4 weather

    func testGateInputStormExactlyOnceInOrderWithEchoes() throws {
        let (session, clientValue, box) = try establish()
        var client = clientValue
        var forwarded = 0
        var t: UInt64 = 1_000
        // Drain the establishment exchange (declarations both ways).
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        _ = client.take(type: CtrlMessageType.capabilityDeclaration)

        // The W-G4 fault model (input traffic is sparser than the HS-8
        // storm's, so duplication runs hotter to keep the dup evidence
        // non-vacuous at this datagram count).
        var net = SimNet(
            config: SimNetConfig(
                lossRate: 0.05,
                duplicateRate: 0.05,
                baseDelayMicroseconds: 3_000,
                jitterMicroseconds: 4_000
            ),
            seed: 0x1310_0722
        )

        // 40 events, all five kinds — a typing burst with the pointer
        // busy, one event every 100 ms.
        let events: [InputEvent] = (0..<40).map { i in
            let body: InputEvent.Body
            switch i % 5 {
            case 0: body = .keyKeycode(keycode: 30, pressed: true)
            case 1: body = .keyKeycode(keycode: 30, pressed: false)
            case 2: body = .pointerMotionAbsolute(
                x: Double(i) * 12.5, y: Double(i) * 7.25)
            case 3: body = .pointerButton(button: 0x110, pressed: i % 2 == 1)
            default: body = .pointerAxis(
                dx: 0, dy: Double(i) - 20, finish: i % 10 == 9)
            }
            return InputEvent(
                seq: UInt32(i),
                clientMicroseconds: 10_000 + UInt64(i) * 100_000,
                body: body
            )
        }

        var deliveredSeqs: [UInt32] = []
        var reportedTuples: [UInt32: (rx: UInt64, inject: UInt64)] = [:]
        var clientSent = 0
        let horizon: UInt64 = 30_000_000
        var converged: UInt64?

        while t < horizon {
            for delivery in net.deliveries(upTo: t) {
                if delivery.destination == 0 {
                    for event in session.receive(
                        delivery.bytes, from: Self.tupleA,
                        now: t * 1_000, hostMicroseconds: t
                    ) {
                        guard case .inputReceived(let input, let rx) = event
                        else { continue }
                        deliveredSeqs.append(input.seq)
                        XCTAssertEqual(
                            input, events[Int(input.seq)],
                            "event \(input.seq) must arrive byte-faithful"
                        )
                        // The simulated shell: inject 300 µs after rx.
                        let inject = rx + 300
                        reportedTuples[input.seq] = (rx, inject)
                        session.noteInputInjected(
                            seq: input.seq,
                            receivedAtMicroseconds: rx,
                            injectedAtMicroseconds: inject
                        )
                    }
                } else {
                    try client.absorb(delivery.bytes, nowMicros: t)
                }
            }

            while clientSent < events.count,
                  t >= 10_000 + UInt64(clientSent) * 100_000 {
                try client.arq.send(
                    message: events[clientSent].encode(),
                    now: ClientTimestamp(microseconds: t)
                )
                clientSent += 1
            }

            _ = session.advance(now: t * 1_000, hostMicroseconds: t)
            session.pump(now: t * 1_000)
            while forwarded < box.datagrams.count {
                net.send(from: 0, bytes: box.datagrams[forwarded].bytes, now: t)
                forwarded += 1
            }
            for datagram in try client.pollOut(nowMicros: t) {
                net.send(from: 1, bytes: datagram, now: t)
            }

            if clientSent == events.count,
               deliveredSeqs.count == events.count,
               client.echoTuples.count == events.count,
               session.arqIsQuiescent, client.arq.isQuiescent,
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

        XCTAssertNotNil(converged, "input did not converge within 30 virtual s")
        XCTAssertGreaterThan(net.lostCount, 0, "the storm must be real")
        XCTAssertGreaterThan(net.duplicatedCount, 0)

        // Exactly once, IN ORDER — the reliable ordered stream's word.
        XCTAssertEqual(deliveredSeqs, (0..<40).map(UInt32.init),
                       "input events must arrive exactly once, in order")
        XCTAssertEqual(session.counters.inputEventsReceived, 40)

        // Every injection echoed exactly once with the true stamps.
        XCTAssertEqual(client.echoTuples.count, 40)
        XCTAssertEqual(
            client.echoTuples.map(\.seq).sorted(), (0..<40).map(UInt32.init),
            "every seq echoed exactly once"
        )
        for tuple in client.echoTuples {
            guard let reported = reportedTuples[tuple.seq] else {
                XCTFail("echo for a seq never reported injected")
                continue
            }
            XCTAssertEqual(tuple.receivedMicroseconds, reported.rx)
            XCTAssertEqual(tuple.injectedMicroseconds, reported.inject)
        }
        XCTAssertEqual(session.counters.inputEchoTuplesSent, 40)
        for count in client.echoMessageTupleCounts {
            XCTAssertLessThanOrEqual(count, InputEcho.maxTupleCount)
        }

        // The frame stamped after the storm carries the last seq.
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 3_000),
            captureTimestampMicroseconds: t,
            isKeyframe: false, now: t * 1_000
        )
        session.pump(now: t * 1_000 + 2_000_000)
        for datagram in box.datagrams[forwarded...] {
            try client.absorb(datagram.bytes, nowMicros: t)
        }
        XCTAssertFalse(client.videoShards.isEmpty)
        for shard in client.videoShards {
            XCTAssertEqual(
                try LastInputSeqTlv.decode(extensions: shard.envelope.extensions),
                39, "every shard carries the last injected seq"
            )
        }

        print("HS-13 gate (storm): 40 events all kinds exactly-once "
            + "IN ORDER through 5% loss / 5% dup / 4 ms jitter "
            + "(\(net.lostCount) lost, \(net.duplicatedCount) duplicated of "
            + "\(net.sentCount)); 40/40 echo tuples byte-faithful in "
            + "\(client.echoMessageTupleCounts.count) messages; post-storm "
            + "frame stamped lastInputSeq=39 on all "
            + "\(client.videoShards.count) shards")
    }

    // MARK: lastInputSeq stamping + geometry under the extra TLV

    func testGateLastInputSeqStampingAndGeometry() throws {
        let (session, clientValue, box) = try establish()
        var client = clientValue
        var forwarded = 0
        var t: UInt64 = 1_000
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        _ = client.take(type: CtrlMessageType.capabilityDeclaration)

        // Pre-input: no TLV 0x03 anywhere. 1100 B fits ONE data shard
        // under the bare 1101 B budget (conn-id TLV + tag headroom) but
        // NOT under the stamped 1095 B budget — the discriminating size.
        let frameByteCount = 1_100
        let plain = syntheticFrame(byteCount: frameByteCount)
        _ = try session.ingestVideoFrame(
            plain, captureTimestampMicroseconds: 42,
            isKeyframe: false, now: t * 1_000
        )
        t += 30_000
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        XCTAssertFalse(client.videoShards.isEmpty)
        for shard in client.videoShards {
            XCTAssertNil(
                try LastInputSeqTlv.decode(extensions: shard.envelope.extensions),
                "no input yet — no stamp"
            )
            XCTAssertLessThanOrEqual(shard.plaintext.count, 1_101)
        }
        XCTAssertTrue(
            client.videoShards.contains { $0.plaintext.count == frameByteCount },
            "1100 B must ride one full data shard under the bare budget"
        )
        let bareShardCount = client.videoShards.count
        client.videoShards.removeAll()

        // The client types; the shell injects and reports (settle's
        // simulated loop). The NEXT frame carries the stamp.
        try client.arq.send(
            message: InputEvent(
                seq: 7, clientMicroseconds: 1,
                body: .keyKeycode(keycode: 30, pressed: true)
            ).encode(),
            now: ClientTimestamp(microseconds: t)
        )
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        XCTAssertEqual(session.lastInputSeq, 7)

        let stamped = syntheticFrame(byteCount: frameByteCount)
        _ = try session.ingestVideoFrame(
            stamped, captureTimestampMicroseconds: 43,
            isKeyframe: false, now: t * 1_000
        )
        t += 30_000
        try settle(session, &client, box, forwarded: &forwarded, t: &t)

        // Every shard: conn-id AND lastInputSeq TLVs, and the tighter
        // 1095 B plaintext ceiling (17 B TLV block) actually drove the
        // geometry — the same 1100 B frame now needs a second data
        // shard, so the shard count grew.
        XCTAssertFalse(client.videoShards.isEmpty)
        for shard in client.videoShards {
            XCTAssertEqual(
                try ConnectionId.decode(extensions: shard.envelope.extensions),
                session.connectionId
            )
            XCTAssertEqual(
                try LastInputSeqTlv.decode(extensions: shard.envelope.extensions),
                7
            )
            XCTAssertLessThanOrEqual(shard.plaintext.count, 1_095,
                "stamped shards must respect the TLV-adjusted budget")
        }
        XCTAssertGreaterThan(
            client.videoShards.count, bareShardCount,
            "1100 B no longer fits one shard at the 1095 B stamped "
                + "budget — geometry must derive from the real headroom"
        )

        // Byte-exact reassembly through the core's own assembler: the
        // extra TLV is invisible to the video interior.
        var assembler = VideoAssembler()
        var units: [DecodeUnit] = []
        var rxNow = ClientTimestamp(microseconds: 0)
        for shard in client.videoShards {
            rxNow = rxNow.advanced(byMicroseconds: 25)
            for event in assembler.ingest(
                envelope: shard.envelope, payload: shard.plaintext[...],
                now: rxNow
            ) {
                if case .decoded(let unit) = event { units.append(unit) }
            }
        }
        XCTAssertEqual(units.map(\.annexB), [stamped],
                       "the stamped frame must reassemble byte-exact")

        print("HS-13 gate (stamp): pre-input frames bare; post-injection "
            + "frames carry TLV 0x03 = 7 on every shard, geometry at the "
            + "1095 B TLV-adjusted budget, byte-exact through VideoAssembler")
    }

    // MARK: Input in IDLE is the WAKE (the notePreArmInput wiring)

    func testGateInputWakesIdleSession() throws {
        let (session, clientValue, box) = try establish()
        var client = clientValue
        var forwarded = 0
        var t: UInt64 = 1_000
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        _ = client.take(type: CtrlMessageType.capabilityDeclaration)

        // Reach IDLE the honest way: a frame, convergence, the one-shot
        // ack (the HS-11 flip).
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 900),
            captureTimestampMicroseconds: 42, isKeyframe: false,
            now: t * 1_000
        )
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        _ = session.noteRatchetConverged(
            finalFrame: syntheticFrame(byteCount: 700),
            captureTimestampMicroseconds: 42,
            now: t * 1_000, hostMicroseconds: t
        )
        session.pump(now: t * 1_000)
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        XCTAssertEqual(session.wireMode, .idle, "the ack flipped to IDLE")
        _ = client.take(type: CtrlMessageType.modeTransition)
        XCTAssertFalse(session.takeFreshKeyframeRequest())

        // A keypress lands in IDLE: the pre-arm IS the WAKE — before
        // any damage exists (W4b; the seam HS-11 left unwired).
        var wakeEvents: [SessionEvent] = []
        try client.arq.send(
            message: InputEvent(
                seq: 0, clientMicroseconds: 5,
                body: .keyKeycode(keycode: 30, pressed: true)
            ).encode(),
            now: ClientTimestamp(microseconds: t)
        )
        try settle(session, &client, box, forwarded: &forwarded, t: &t) {
            wakeEvents.append($0)
        }

        XCTAssertEqual(session.wireMode, .active, "input in IDLE wakes")
        XCTAssertTrue(wakeEvents.contains(.modeTransitionSent(.active)))
        XCTAssertTrue(wakeEvents.contains(where: {
            if case .inputReceived(let event, _) = $0 {
                return event.seq == 0
            }
            return false
        }))
        XCTAssertTrue(session.takeFreshKeyframeRequest(),
                      "WAKE arms next-damage-as-IDR before the damage exists")
        let modeMessages = client.take(type: CtrlMessageType.modeTransition)
        XCTAssertEqual(
            try modeMessages.map { try ModeTransition.decode($0).mode },
            [.active],
            "mode=active reaches the client on the reliable stream"
        )
        // The injection report was made by settle's shell; its echo
        // arrived too.
        XCTAssertEqual(client.echoTuples.map(\.seq), [0])

        print("HS-13 gate (wake): keypress in IDLE → mode=active on the "
            + "wire + IDR armed pre-damage + echo tuple delivered — "
            + "notePreArmInput has its caller")
    }
}
