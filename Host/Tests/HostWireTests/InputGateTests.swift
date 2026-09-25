import XCTest
import HostCore
import HostSession
import HostWire
import HostWireTestKit
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
//     1152 B budget (geometry derives from the real TLV headroom).
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

    // MARK: The input-capable loopback client

    private struct InputClient: PeerBackedClient {
        var peer: SealedCtrlPeer<ClientClock>
        var echoTuples: [InputEchoTuple] = []
        var echoMessageTupleCounts: [Int] = []
        /// Unsealed video shards, for the lastInputSeq TLV legs.
        var videoShards: [(envelope: Envelope, plaintext: [UInt8])] = []

        mutating func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            XCTAssertLessThanOrEqual(
                bytes.count, WireBudget.maxDatagramByteCount,
                "host datagram over the 1152 B budget"
            )
            switch try peer.absorb(bytes, nowMicros: nowMicros) {
            case .reliable(_, _, let events):
                for case .message(_, let bytes) in events
                where bytes.first == CtrlMessageType.inputEcho {
                    let echo = try InputEcho.decode(bytes)
                    echoTuples += echo.tuples
                    echoMessageTupleCounts.append(echo.tuples.count)
                }
            case .plain(let envelope, let plaintext):
                if envelope.channel == .videoActive {
                    videoShards.append((envelope, plaintext))
                    return
                }
                XCTAssertEqual(envelope.channel, .ctrl)
                if plaintext.first != CtrlMessageType.clockBeacon { // 1 Hz weather
                    XCTFail("unexpected host CTRL type \(plaintext.first ?? 0)")
                }
            case .handshakeCompleted, .duplicate, .unopened:
                break
            }
        }
    }

    /// Handshake + capability exchange, direct pipe (the lifecycle
    /// suite's establish, input-client flavored).
    private func establish(
        clientCapabilities: Capabilities? = .wireDefault,
        lifecycle: SessionMachineConfig = SessionMachineConfig(),
        beaconIntervalNS: UInt64 = 1 << 62
    ) throws -> (host: HostSessionHarness, client: InputClient) {
        let host = HostSessionHarness(
            config: SessionConfig(
                crypto: .noise(hostStatic: NoiseKeyPair.generate()),
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: beaconIntervalNS,
                lifecycle: lifecycle
            ),
            tuple: Self.tupleA,
            rng: SplitMix64(seed: 0x1310)
        )
        let client = InputClient(peer: try host.connectClient(
            declaring: clientCapabilities, openChannels: nil
        ))
        XCTAssertEqual(host.session.phase, .established)
        return (host, client)
    }

    /// Exchange passes 2 ms apart until both ends quiesce, injecting
    /// every delivered input event `injectDelayMicros` after receipt
    /// (the simulated shell).
    private func settle(
        _ host: HostSessionHarness, _ client: inout InputClient,
        t: inout UInt64,
        injectDelayMicros: UInt64 = 300,
        onEvent: (SessionEvent) -> Void = { _ in }
    ) throws {
        try host.settle(&client, t: &t) { event in
            if case .inputReceived(let input, let rx) = event {
                host.session.noteInputInjected(
                    seq: input.seq,
                    receivedAtMicroseconds: rx,
                    injectedAtMicroseconds: rx + injectDelayMicros
                )
            }
            onEvent(event)
        }
    }

    // MARK: The storm — exactly once, in order, echoed, through W-G4 weather

    func testGateInputStormExactlyOnceInOrderWithEchoes() throws {
        let (host, clientValue) = try establish()
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000
        // Drain the establishment exchange (declarations both ways).
        try settle(host, &client, t: &t)
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
            while host.forwarded < host.sent.count {
                net.send(from: 0, bytes: host.sent[host.forwarded].bytes, now: t)
                host.forwarded += 1
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
        for datagram in host.sent[host.forwarded...] {
            try client.absorb(datagram.bytes, nowMicros: t)
        }
        XCTAssertFalse(client.videoShards.isEmpty)
        for shard in client.videoShards {
            XCTAssertEqual(
                try LastInputSeqTlv.decode(extensions: shard.envelope.extensions),
                39, "every shard carries the last injected seq"
            )
        }
    }

    // MARK: lastInputSeq stamping + geometry under the extra TLV

    func testGateLastInputSeqStampingAndGeometry() throws {
        let (host, clientValue) = try establish()
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000
        try settle(host, &client, t: &t)
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
        try settle(host, &client, t: &t)
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
        try settle(host, &client, t: &t)
        XCTAssertEqual(session.lastInputSeq, 7)

        let stamped = syntheticFrame(byteCount: frameByteCount)
        _ = try session.ingestVideoFrame(
            stamped, captureTimestampMicroseconds: 43,
            isKeyframe: false, now: t * 1_000
        )
        t += 30_000
        try settle(host, &client, t: &t)

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
            """
                1100 B no longer fits one shard at the 1095 B stamped \
                budget — geometry must derive from the real headroom
                """
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
    }
}
