import XCTest
import HostCore
import HostWire
import LyteWire
import LyteWireTestKit

// THE GATE (build plan HS-15 row: "AudioFramer, DSCP 48, priority above
// video" — R-G8's in-tree half). Pinned behaviors, each a leg below:
//
//   • the audio wire layout is FROZEN DATA: hand-built envelope bytes,
//     not codec-vs-codec — chan 1, frame = group id = first packet
//     number, per-packet capture µs on data shards / group-first µs on
//     parity, the video-identical 8-byte fec interior (4+2, scheme RS);
//   • one packet = one data shard = one datagram, emitted immediately;
//     parity emits only when the group completes (cadence before
//     protection);
//   • the 4+2 group survives ANY two losses byte-exact and refuses
//     three, through the same FecDecoder the client will run;
//   • the hard-CBR contract is enforced loud (a mid-group size change
//     would shear shard boundaries off packet boundaries);
//   • audio rides PacerClass.audio in the ONE shared schedule: above
//     every video class, below control;
//   • sealed exactly like video (header bytes as AAD) and unsealable
//     by the LyteWire client build-up; a tampered header fails;
//   • lifecycle: audio flows in ACTIVE, IDLE, and FROZEN (W4b: audio
//     is the path probe; the 5 ms cadence is what lets the client
//     detector tighten to 350 ms) and stops only at closed;
//   • THE CADENCE GATE (audio-continuity §4.1, R-G8's shape in virtual
//     time): audio inter-send stays 5 ms ± 2 ms at p99 while
//     worst-case IDRs drain, and no audio datagram ever waits behind
//     more than one ≤1 ms video batch.

final class AudioGateTests: XCTestCase {

    private static let rateBPS = 20_000_000

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_021,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    /// A hard-CBR-shaped Opus packet stand-in: `byteCount` deterministic
    /// bytes seeded by the packet number (real 128 kbps CBR packets are
    /// a constant 80 B — HS-14's evidence).
    private func opusPacket(_ n: Int, byteCount: Int = 80) -> [UInt8] {
        (0..<byteCount).map { UInt8(truncatingIfNeeded: n &* 31 &+ $0) }
    }

    /// A synthetic frame-shaped Annex-B blob (the SessionGateTests
    /// pattern); `irap: true` makes it a genuine IDR-shaped keyframe.
    private func syntheticFrame(byteCount: Int, irap: Bool = false) -> [UInt8] {
        precondition(byteCount >= 6)
        return [0, 0, 0, 1, irap ? 0x26 : 0x02, 0x01]
            + [UInt8](repeating: 0xAA, count: byteCount - 6)
    }

    // MARK: Leg 1 — the layout, pinned as hand-built bytes

    func testFramerLayoutPinnedAgainstHandBuiltBytes() throws {
        let framer = AudioFramer(config: AudioFramerConfig())
        let packets = (0..<4).map { opusPacket($0, byteCount: 12) }

        var emitted: [(envelope: Envelope, payload: [UInt8])] = []
        for (n, packet) in packets.enumerated() {
            emitted += try framer.ingest(
                packet: packet,
                captureTimestampMicroseconds: 1_000 + UInt64(n) * 5_000
            )
        }
        XCTAssertEqual(emitted.count, 6, "4 data + 2 parity")

        // Hand-assembled wire image of data shard `i`: the layout IS
        // the contract. All fields little-endian (envelope rule).
        func handBuilt(shardIndex i: UInt8, timestamp: UInt64,
                       payload: [UInt8]) -> [UInt8] {
            var out: [UInt8] = []
            out.append(1)                    // chan 1 = audio
            out.append(0)                    // flags: no TLV block
            out += [UInt8(i), 0]             // seq u16 LE (emit order)
            out += [0, 0, 0, 0]              // frame u32 LE = group id 0
            for shift in stride(from: 0, to: 64, by: 8) {
                out.append(UInt8(truncatingIfNeeded: timestamp >> shift))
            }
            // fec u64 LE: shardIndex ‖ k=4 ‖ m=2 ‖ scheme=RS(0x01) ‖
            // groupByteCount u24 = 48 ‖ reserved 0.
            out += [i, 4, 2, 0x01, 48, 0, 0, 0]
            out += payload
            return out
        }

        for i in 0..<4 {
            let wire = try emitted[i].envelope.encode(
                plaintextShard: emitted[i].payload
            )
            XCTAssertEqual(
                wire,
                handBuilt(shardIndex: UInt8(i),
                          timestamp: 1_000 + UInt64(i) * 5_000,
                          payload: packets[i]),
                "data shard \(i) layout drifted"
            )
        }

        // Parity shards: envelope hand-built (group-FIRST capture µs —
        // they correspond to no single packet); payload pinned against
        // the frozen FEC machinery (fec-v1.json owns the matrix math).
        let geometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 48
        )
        let reference = try FecEncoder.encode(
            group: packets.flatMap { $0 }, geometry: geometry
        )
        for (offset, i) in [4, 5].enumerated() {
            let wire = try emitted[i].envelope.encode(
                plaintextShard: emitted[i].payload
            )
            var expected = handBuilt(
                shardIndex: UInt8(i), timestamp: 1_000,
                payload: reference[4 + offset]
            )
            expected[2] = UInt8(i) // seq keeps counting through parity
            XCTAssertEqual(wire, expected, "parity shard \(i) drifted")
        }

        // The next group starts at packet number 4 and seq 6.
        let next = try framer.ingest(
            packet: opusPacket(4, byteCount: 12),
            captureTimestampMicroseconds: 21_000
        )
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].envelope.frame.rawValue, 4,
                       "group id = the group's first packet number")
        XCTAssertEqual(next[0].envelope.seq.rawValue, 6)
        XCTAssertEqual(framer.counters.groupsCompleted, 1)
    }

    func testConnectionIdTlvRidesEveryAudioDatagram() throws {
        var rng = SplitMix64(seed: 0xA15)
        let connId = ConnectionId.random(using: &rng)
        let framer = AudioFramer(
            config: AudioFramerConfig(connectionId: connId)
        )
        var emitted: [(envelope: Envelope, payload: [UInt8])] = []
        for n in 0..<4 {
            emitted += try framer.ingest(
                packet: opusPacket(n),
                captureTimestampMicroseconds: UInt64(n) * 5_000
            )
        }
        XCTAssertEqual(emitted.count, 6)
        for (envelope, payload) in emitted {
            XCTAssertEqual(
                try ConnectionId.decode(extensions: envelope.extensions),
                connId
            )
            let wire = try envelope.encode(plaintextShard: payload)
            XCTAssertLessThanOrEqual(
                wire.count + WireBudget.aeadTagByteCount,
                WireBudget.maxDatagramByteCount
            )
        }
    }

    // MARK: Leg 2 — FEC geometry and recovery

    func testGroupSurvivesAnyTwoLossesAndRefusesThree() throws {
        let framer = AudioFramer(config: AudioFramerConfig())
        let packets = (0..<4).map { opusPacket($0) }
        var shards: [[UInt8]] = []
        for (n, packet) in packets.enumerated() {
            for (_, payload) in try framer.ingest(
                packet: packet,
                captureTimestampMicroseconds: UInt64(n) * 5_000
            ) {
                shards.append(payload)
            }
        }
        XCTAssertEqual(shards.count, 6)
        let geometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 4 * 80
        )

        // Every 2-of-6 loss pattern recovers the packets byte-exact.
        for a in 0..<6 {
            for b in (a + 1)..<6 {
                var slots: [[UInt8]?] = shards
                slots[a] = nil
                slots[b] = nil
                let group = try FecDecoder.decode(
                    shards: slots, geometry: geometry
                )
                for (n, packet) in packets.enumerated() {
                    XCTAssertEqual(
                        Array(group[(n * 80)..<((n + 1) * 80)]), packet,
                        "packet \(n) after losing shards \(a),\(b)"
                    )
                }
            }
        }

        // Three losses (two of them data) are honestly refused.
        var slots: [[UInt8]?] = shards
        slots[0] = nil
        slots[1] = nil
        slots[4] = nil
        XCTAssertThrowsError(
            try FecDecoder.decode(shards: slots, geometry: geometry)
        )
    }

    // MARK: Leg 3 — contract enforcement

    func testHardCbrContractViolationThrowsLoud() throws {
        let framer = AudioFramer(config: AudioFramerConfig())
        _ = try framer.ingest(
            packet: opusPacket(0, byteCount: 80),
            captureTimestampMicroseconds: 0
        )
        XCTAssertThrowsError(try framer.ingest(
            packet: opusPacket(1, byteCount: 81),
            captureTimestampMicroseconds: 5_000
        )) {
            XCTAssertEqual(
                $0 as? AudioFramerError,
                .packetSizeChangedMidGroup(expected: 80, actual: 81)
            )
        }
        // A completed group resets the contract: the NEXT group may
        // open at a new constant size (a bitrate change at a group
        // boundary is legal; mid-group is not).
        for n in 1..<4 {
            _ = try framer.ingest(
                packet: opusPacket(n, byteCount: 80),
                captureTimestampMicroseconds: UInt64(n) * 5_000
            )
        }
        XCTAssertEqual(
            try framer.ingest(
                packet: opusPacket(4, byteCount: 96),
                captureTimestampMicroseconds: 20_000
            ).count, 1
        )
    }

    func testEmptyAndOversizedPacketsRefused() {
        let framer = AudioFramer(config: AudioFramerConfig())
        XCTAssertThrowsError(try framer.ingest(
            packet: [], captureTimestampMicroseconds: 0
        )) {
            XCTAssertEqual($0 as? AudioFramerError, .emptyPacket)
        }
        let over = framer.config.packetBudgetByteCount + 1
        XCTAssertThrowsError(try framer.ingest(
            packet: [UInt8](repeating: 0, count: over),
            captureTimestampMicroseconds: 0
        )) {
            XCTAssertEqual(
                $0 as? AudioFramerError, .packetOverBudget(over)
            )
        }
    }

    // MARK: Leg 4 — class assignment in the shared schedule

    func testAudioOutranksQueuedVideoInTheOneSchedule() throws {
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .insecure, rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x15)
        ) { sent.append($0) }

        // A frame's shards queue first; audio arrives after — and must
        // still leave FIRST (strict priority, not FIFO across classes).
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 8_000),
            captureTimestampMicroseconds: 1, isKeyframe: false, now: 0
        )
        _ = try session.ingestAudioPacket(
            opusPacket(0), captureTimestampMicroseconds: 2, now: 0
        )
        session.pump(now: 0)

        let audioIndex = sent.firstIndex { $0.pacerClass == .audio }
        let videoIndex = sent.firstIndex { $0.pacerClass == .freshVideo }
        XCTAssertNotNil(audioIndex)
        XCTAssertNotNil(videoIndex)
        XCTAssertLessThan(audioIndex!, videoIndex!,
            "audio must dispatch ahead of already-queued video")
        for datagram in sent where datagram.pacerClass == .audio {
            let (envelope, _) = try Envelope.decode(datagram.bytes)
            XCTAssertEqual(envelope.channel, .audio)
        }
    }

    /// HS-31 (squeeze review §1, consult-corrected shape): at the
    /// 500 kbps estimator floor one max-size video datagram drives the
    /// shared bucket ~19 ms negative — and audio used to wait the
    /// whole deficit out (22.9–53.6 ms measured live vs §4.1's
    /// 5 ± 2 ms bound). Through the REAL ingest → pacer → sink path:
    /// audio enqueued mid-deficit emits at once, `nextWake` is NOW
    /// while audio is queued (what the sender thread's signalDrain
    /// wake relies on — the fix-2 seam), and the video tail stays
    /// parked until the deficit is truly repaid.
    func testAudioEmitsThroughVideoIncurredDeficitAtRateFloor() throws {
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .insecure, rateBitsPerSecond: 500_000,
                beaconIntervalNS: 1 << 62
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x31)
        ) { sent.append($0) }
        let ms: UInt64 = 1_000_000

        // A multi-shard frame at t=0: the first max-size datagram
        // emits alone (oversize-alone clause) and the bucket goes
        // ~19 ms negative; the rest of the frame parks.
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 8_000),
            captureTimestampMicroseconds: 1, isKeyframe: false, now: 0
        )
        session.pump(now: 0)
        let videoSentAtOpen = sent.count { $0.pacerClass == .freshVideo }
        XCTAssertEqual(videoSentAtOpen, 1,
            "exactly the one oversize datagram leaves; the tail parks "
            + "behind the deficit")
        XCTAssertGreaterThan(session.queuedVideoBytes, 0)

        // Audio lands 1 ms into the deficit. The wake must be NOW —
        // not the deficit's repayment instant ~19 ms out.
        _ = try session.ingestAudioPacket(
            opusPacket(0), captureTimestampMicroseconds: 1_000, now: 1 * ms
        )
        XCTAssertGreaterThan(session.queuedAudioDatagramCount, 0)
        let wake = session.nextWake(now: 1 * ms)
        XCTAssertNotNil(wake)
        XCTAssertLessThanOrEqual(wake ?? .max, 1 * ms,
            "a parked sender thread woken by signalDrain must find "
            + "immediate work, not a 19 ms sleep")

        session.pump(now: 1 * ms)
        XCTAssertEqual(sent.count { $0.pacerClass == .audio }, 1,
            "audio must emit through the video-incurred deficit")
        XCTAssertEqual(session.queuedAudioDatagramCount, 0)
        XCTAssertEqual(sent.count { $0.pacerClass == .freshVideo },
                       videoSentAtOpen,
                       "video must not borrow audio's exemption")

        // The 5 ms cadence holds while the deficit repays.
        _ = try session.ingestAudioPacket(
            opusPacket(1), captureTimestampMicroseconds: 6_000, now: 6 * ms
        )
        session.pump(now: 6 * ms)
        XCTAssertEqual(sent.count { $0.pacerClass == .audio }, 2)
        XCTAssertLessThanOrEqual(
            session.pacerTelemetry[.audio].maxQueueDelayNS, 2 * ms,
            "audio queue delay must hold §4.1's bound through the "
            + "deficit")
    }

    // MARK: Leg 5 — sealed round trip through the LyteWire client build-up

    /// The minimal client far end (the SessionGateTests discipline):
    /// NoiseSession initiator + unseal; audio datagrams collected with
    /// their plaintext payloads; an ArqEndpoint for the lifecycle legs.
    private struct AudioClient {
        var noise: NoiseSession
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var feedbackSeq: UInt16 = 0
        var arq = ArqEndpoint<ClientClock>(channel: .ctrl)
        let staticKeys: NoiseKeyPair

        var audio: [(envelope: Envelope, payload: [UInt8])] = []
        var videoDatagrams = 0
        var reliable: [(group: ArqGroupId, bytes: [UInt8])] = []

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
            return try datagram(
                channel: .ctrl,
                body: [CtrlMessageType.noiseHandshake1] + message1,
                sealed: false, clientMicros: clientMicros
            )
        }

        mutating func datagram(
            channel: ChannelId, body: [UInt8], sealed: Bool,
            clientMicros: UInt64
        ) throws -> [UInt8] {
            let seq: UInt16
            if channel == .feedback {
                seq = feedbackSeq
                feedbackSeq &+= 1
            } else {
                seq = ctrlSeq
                ctrlSeq &+= 1
            }
            let envelope = Envelope(
                channel: channel,
                seq: ChannelSeq(rawValue: seq),
                frame: FrameNumber(rawValue: 0),
                timestamp: clientMicros,
                fec: 0
            )
            guard sealed else { return try envelope.encode(payload: body) }
            let header = try envelope.encode(payload: [])
            let payload = try transport!.seal(
                plaintext: body[...], aad: header[...], envelope: envelope
            )
            return try envelope.encode(payload: payload)
        }

        mutating func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            let (envelope, payload) = try Envelope.decode(bytes)
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
                return
            }
            switch envelope.channel {
            case .audio:
                audio.append((envelope, plaintext))
            case .videoActive:
                videoDatagrams += 1
            case .ctrl:
                switch plaintext.first {
                case CtrlMessageType.arqSegment, CtrlMessageType.arqAck:
                    for event in arq.ingest(
                        payload: plaintext,
                        now: ClientTimestamp(microseconds: nowMicros)
                    ) {
                        if case .message(let group, let bytes) = event {
                            reliable.append((group, bytes))
                        }
                    }
                case CtrlMessageType.clockBeacon:
                    break
                default:
                    XCTFail("unexpected CTRL type \(plaintext.first ?? 0)")
                }
            default:
                XCTFail("unexpected channel \(envelope.channel.rawValue)")
            }
        }

        mutating func pollOut(nowMicros: UInt64) throws -> [[UInt8]] {
            let (payloads, _) = arq.poll(
                now: ClientTimestamp(microseconds: nowMicros)
            )
            return try payloads.map {
                try datagram(
                    channel: .ctrl, body: $0, sealed: true,
                    clientMicros: nowMicros
                )
            }
        }
    }

    private final class DatagramBox {
        var datagrams: [VideoChannelDatagram] = []
    }

    /// Handshake + settle: an established Noise session with the audio
    /// path live and the client's ARQ answering (so lifecycle flips can
    /// be exercised).
    private func establish() throws -> (
        session: Session, client: AudioClient, box: DatagramBox
    ) {
        let hostStatic = NoiseKeyPair.generate()
        let box = DatagramBox()
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x1515),
            send: { box.datagrams.append($0) }
        )
        var client = try AudioClient(hostStaticPublicKey: hostStatic.publicKey)
        _ = session.receive(
            try client.message1Datagram(clientMicros: 500),
            from: Self.tupleA, now: 0, hostMicroseconds: 0
        )
        XCTAssertEqual(session.phase, .established)
        session.pump(now: 0)
        return (session, client, box)
    }

    /// Lossless exchange passes until both ends quiesce (the lifecycle
    /// harness's settle, trimmed).
    private func settle(
        _ session: Session, _ client: inout AudioClient,
        _ box: DatagramBox, forwarded: inout Int, t: inout UInt64
    ) throws {
        var idle = 0
        while idle < 3 {
            t += 2_000
            let before = forwarded
            _ = session.advance(now: t * 1_000, hostMicroseconds: t)
            session.pump(now: t * 1_000)
            while forwarded < box.datagrams.count {
                try client.absorb(box.datagrams[forwarded].bytes, nowMicros: t)
                forwarded += 1
            }
            for datagram in try client.pollOut(nowMicros: t) {
                _ = session.receive(
                    datagram, from: Self.tupleA,
                    now: t * 1_000, hostMicroseconds: t
                )
                session.pump(now: t * 1_000)
                while forwarded < box.datagrams.count {
                    try client.absorb(
                        box.datagrams[forwarded].bytes, nowMicros: t
                    )
                    forwarded += 1
                }
            }
            idle = forwarded == before ? idle + 1 : 0
        }
    }

    func testSealedAudioRoundTripsAndRecoversThroughTheClientStack() throws {
        let (session, clientValue, box) = try establish()
        var client = clientValue
        var forwarded = 0
        var t: UInt64 = 1_000
        try settle(session, &client, box, forwarded: &forwarded, t: &t)

        // Two full groups of real-shaped packets through the sealed path.
        let audioStart = forwarded
        let packets = (0..<8).map { opusPacket($0) }
        var captureStamps: [UInt64] = []
        for packet in packets {
            t += 5_000
            captureStamps.append(t)
            _ = try session.ingestAudioPacket(
                packet,
                captureTimestampMicroseconds: t,
                now: t * 1_000
            )
            session.pump(now: t * 1_000)
        }
        while forwarded < box.datagrams.count {
            try client.absorb(box.datagrams[forwarded].bytes, nowMicros: t)
            forwarded += 1
        }
        let audioDatagrams = box.datagrams[audioStart...].filter {
            $0.pacerClass == .audio
        }
        XCTAssertEqual(client.audio.count, 12, "2 × (4 data + 2 parity)")
        XCTAssertEqual(audioDatagrams.count, 12)
        for datagram in audioDatagrams {
            let (envelope, payload) = try Envelope.decode(datagram.bytes)
            XCTAssertEqual(
                datagram.bytes,
                try envelope.encode(payload: Array(payload)),
                "in-place AAD-buffer assembly must remain byte-identical "
                    + "to the canonical envelope encoder"
            )
        }
        XCTAssertEqual(
            audioDatagrams.map(\.seq.rawValue),
            Array(0..<UInt16(audioDatagrams.count)),
            "assembly must not perturb audio sequence allocation"
        )
        XCTAssertEqual(session.counters.audioPacketsIngested, packets.count)
        XCTAssertEqual(session.counters.audioDatagramsEnqueued, 12)
        XCTAssertEqual(session.counters.audioGroupsCompleted, 2)
        XCTAssertEqual(
            session.counters.audioSealedDatagramsAssembledInPlace, 12,
            "every audio datagram must avoid the final envelope copy"
        )

        // Every unsealed data shard is its packet byte-verbatim, with
        // packet number = frame + shardIndex and its own capture µs.
        var byGroup: [UInt32: [[UInt8]?]] = [:]
        let geometry = try FecGeometry(
            dataShards: 4, parityShards: 2, groupByteCount: 4 * 80
        )
        for (envelope, plaintext) in client.audio {
            let field = try FecField.decode(envelope.fec)
            guard case .reedSolomon(let index, let g) = field else {
                return XCTFail("audio datagram without an RS fec field")
            }
            XCTAssertEqual(g, geometry)
            var slots = byGroup[envelope.frame.rawValue]
                ?? [[UInt8]?](repeating: nil, count: 6)
            slots[Int(index)] = plaintext
            byGroup[envelope.frame.rawValue] = slots
            if Int(index) < 4 {
                let packetNumber = Int(envelope.frame.rawValue) + Int(index)
                XCTAssertEqual(plaintext, packets[packetNumber])
                XCTAssertEqual(
                    envelope.timestamp, captureStamps[packetNumber],
                    "data shards carry their own packet's capture µs"
                )
            } else {
                XCTAssertEqual(
                    envelope.timestamp,
                    captureStamps[Int(envelope.frame.rawValue)],
                    "parity shards carry the group's FIRST capture µs"
                )
            }
        }
        XCTAssertEqual(Set(byGroup.keys), [0, 4],
                       "group ids are first packet numbers")

        // Drop any two shards of group 0 — the client's FecDecoder
        // still yields the packets byte-exact (the wire-format
        // round-trip the live gate reproduces under netem).
        var slots = byGroup[0]!
        slots[1] = nil
        slots[4] = nil
        let recovered = try FecDecoder.decode(shards: slots, geometry: geometry)
        for n in 0..<4 {
            XCTAssertEqual(Array(recovered[(n * 80)..<((n + 1) * 80)]),
                           packets[n])
        }

        // A tampered header dies at the AAD check, like every channel.
        let sample = box.datagrams.last { $0.pacerClass == .audio }!
        var tampered = sample.bytes
        tampered[8] ^= 0x01 // one timestamp bit
        XCTAssertThrowsError(try {
            let (envelope, payload) = try Envelope.decode(tampered)
            let aad = tampered[tampered.startIndex..<payload.startIndex]
            _ = try client.transport!.unseal(
                wirePayload: payload, aad: aad, envelope: envelope
            )
        }())
    }

    // MARK: Leg 6 — lifecycle: the probe never stops (except closed)

    func testAudioFlowsInIdleAndStopsOnlyWhenClosed() throws {
        let (session, clientValue, box) = try establish()
        var client = clientValue
        var forwarded = 0
        var t: UInt64 = 1_000
        try settle(session, &client, box, forwarded: &forwarded, t: &t)

        // Reach IDLE the honest way (the lifecycle suite's recipe):
        // a frame, convergence, the one-shot ack.
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
        XCTAssertEqual(session.wireMode, .idle)

        // IDLE: datagram video is off — audio keeps flowing (the 5 ms
        // probe that lets the client detector tighten to 350 ms).
        let audioBefore = client.audio.count
        for n in 0..<4 {
            t += 5_000
            _ = try session.ingestAudioPacket(
                opusPacket(n), captureTimestampMicroseconds: t,
                now: t * 1_000
            )
            session.pump(now: t * 1_000)
        }
        while forwarded < box.datagrams.count {
            try client.absorb(box.datagrams[forwarded].bytes, nowMicros: t)
            forwarded += 1
        }
        XCTAssertEqual(session.wireMode, .idle, "audio must not wake IDLE")
        XCTAssertEqual(client.audio.count - audioBefore, 6)

        // closed: teardown, then audio is suppressed — counted, silent.
        _ = session.beginTeardown(
            reason: .shuttingDown, now: t * 1_000, hostMicroseconds: t
        )
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        XCTAssertEqual(session.lifecycleState, .closed)
        let sent = session.counters.audioDatagramsEnqueued
        XCTAssertEqual(try session.ingestAudioPacket(
            opusPacket(9), captureTimestampMicroseconds: t, now: t * 1_000
        ), 0)
        XCTAssertEqual(session.counters.audioDatagramsEnqueued, sent)
        XCTAssertEqual(session.counters.audioPacketsSuppressed, 1)
    }

    func testAudioFlowsThroughFrozenWhileVideoIsSuppressed() throws {
        // Insecure mode reaches establishment (and arms the machine)
        // without a client; 400 ms of silence trips the 350 ms
        // blackout detector honestly.
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .insecure, rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0xF0)
        ) { sent.append($0) }
        let t: UInt64 = 400_000 // µs
        let events = session.advance(now: t * 1_000, hostMicroseconds: t)
        XCTAssertTrue(events.contains(.lifecycleChanged(.frozen)))

        // Video: suppressed, counted. Audio: flows — the path probe.
        XCTAssertEqual(try session.ingestVideoFrame(
            syntheticFrame(byteCount: 500),
            captureTimestampMicroseconds: t, isKeyframe: false,
            now: t * 1_000
        ), 0)
        XCTAssertEqual(session.counters.videoFramesSuppressed, 1)
        XCTAssertEqual(try session.ingestAudioPacket(
            opusPacket(0), captureTimestampMicroseconds: t, now: t * 1_000
        ), 1)
        session.pump(now: t * 1_000)
        XCTAssertTrue(sent.contains { $0.pacerClass == .audio })
        XCTAssertEqual(session.counters.audioPacketsSuppressed, 0)
    }

    func testAudioBeforeEstablishmentThrows() throws {
        let hostStatic = NoiseKeyPair.generate()
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: Self.rateBPS
            ),
            clientTuple: Self.tupleA,
            now: 0
        ) { _ in }
        XCTAssertThrowsError(try session.ingestAudioPacket(
            opusPacket(0), captureTimestampMicroseconds: 0, now: 0
        )) {
            XCTAssertEqual($0 as? SessionError, .notEstablished)
        }
    }

    // MARK: Leg 7 — THE CADENCE GATE (audio-continuity §4.1 in virtual time)

    /// 5 s of virtual time at 20 Mbps: 5 ms audio, steady 60 fps damage
    /// frames, and a worst-case conforming IDR every 2 s (R-G8's forced
    /// IDR profile). The pass criteria are the audio-continuity doc's,
    /// verbatim: data-shard inter-send 5 ms ± 2 ms at p99, and no audio
    /// datagram waits behind more than one ≤1 ms video batch.
    func testGateAudioCadenceHoldsThroughWorstCaseIdrs() throws {
        let box = DatagramBox()
        var sendInstant: UInt64 = 0
        var audioSends: [(at: UInt64, envelope: Envelope)] = []
        let session = Session(
            config: SessionConfig(
                crypto: .insecure, rateBitsPerSecond: Self.rateBPS
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x0815)
        ) { datagram in
            box.datagrams.append(datagram)
            if datagram.pacerClass == .audio {
                let (envelope, _) = try! Envelope.decode(datagram.bytes)
                audioSends.append((sendInstant, envelope))
            }
        }

        let ms: UInt64 = 1_000_000
        let horizonNS = 5_000 * ms

        enum Arrival { case audio, damage, idr }
        var events: [(at: UInt64, what: Arrival)] = []
        var t: UInt64 = 0
        while t < horizonNS {
            events.append((t, .audio))
            t += 5 * ms
        }
        t = 8 * ms
        while t < horizonNS {
            events.append((t, .damage))
            t += 16_666_667
        }
        t = 100 * ms
        while t < horizonNS {
            events.append((t, .idr))
            t += 2_000 * ms
        }
        events.sort { $0.at < $1.at }

        var audioPacketNumber = 0
        var now: UInt64 = 0
        for event in events {
            // Pump at the session's own wake instants up to the event —
            // the sans-IO event loop, minus the syscalls.
            while let wake = session.nextWake(now: now), wake < event.at {
                now = max(now &+ 1, wake)
                sendInstant = now
                _ = session.advance(
                    now: now, hostMicroseconds: now / 1_000
                )
                session.pump(now: now)
            }
            now = event.at
            sendInstant = now
            switch event.what {
            case .audio:
                _ = try session.ingestAudioPacket(
                    opusPacket(audioPacketNumber),
                    captureTimestampMicroseconds: now / 1_000,
                    now: now
                )
                audioPacketNumber += 1
            case .damage:
                _ = try session.ingestVideoFrame(
                    syntheticFrame(byteCount: 4_000),
                    captureTimestampMicroseconds: now / 1_000,
                    isKeyframe: false, now: now
                )
            case .idr:
                // The HS-6 gate's conforming worst case: 59,904 B at
                // 20 Mbps fills the whole 25 ms drain budget — the
                // burst that traps audio on an unpaced sender.
                _ = try session.ingestVideoFrame(
                    syntheticFrame(byteCount: 59_904, irap: true),
                    captureTimestampMicroseconds: now / 1_000,
                    isKeyframe: true, now: now
                )
            }
            session.pump(now: now)
        }
        while let wake = session.nextWake(now: now), wake < horizonNS {
            now = max(now &+ 1, wake)
            sendInstant = now
            _ = session.advance(now: now, hostMicroseconds: now / 1_000)
            session.pump(now: now)
        }

        // ── The criteria ────────────────────────────────────────────
        // Data shards only: parity deliberately rides out back-to-back
        // behind its group's 4th packet, so it is excluded from the
        // cadence figure by the same rule the live tcpdump filter uses
        // (fec shardIndex < 4).
        let dataSends = try audioSends.filter {
            let field = try FecField.decode($0.envelope.fec)
            guard case .reedSolomon(let index, _) = field else { return false }
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
        let worst = deviations.last!
        XCTAssertLessThanOrEqual(p99, 2 * ms,
            "audio inter-send p99 deviation \(Double(p99) / 1e6) ms > 2 ms")

        // "No audio packet waits behind more than one in-flight video
        // batch": one batch is ≤ 1 ms of wire time, so the audio
        // class's worst queue delay must stay within one quantum (+ ε
        // for the wake-instant walk).
        let audioWait = session.pacerTelemetry[.audio].maxQueueDelayNS
        XCTAssertLessThanOrEqual(
            audioWait, ms + ms / 10,
            "audio waited \(Double(audioWait) / 1e6) ms — more than one batch"
        )
        // And the batches themselves held the ≤1 ms quantum.
        XCTAssertLessThanOrEqual(
            session.pacerTelemetry.maxBatchWireTimeNS, ms
        )
        XCTAssertEqual(
            session.counters.audioSealedDatagramsAssembledInPlace,
            session.counters.audioDatagramsEnqueued
        )

        print("HS-15 gate @20 Mbps, 5 s virtual, IDR every 2 s: "
            + "\(dataSends.count) audio packets; inter-send deviation "
            + "p99 \(Double(p99) / 1e6) ms, worst \(Double(worst) / 1e6) ms; "
            + "max audio queue delay \(Double(audioWait) / 1e6) ms; "
            + "max batch wire time "
            + "\(Double(session.pacerTelemetry.maxBatchWireTimeNS) / 1e6) ms")
    }

    /// The executable publishes audio without taking its broad Session
    /// lock, then uses this interleave seam while a large IDR is being
    /// sealed. This pure gate forces every checkpoint to represent a
    /// newly due 5 ms packet: each must emit immediately through the
    /// video backlog, while the IDR tail remains paced.
    func testLargeIdrCooperativelyServicesAudioSchedulingIsland() throws {
        var now: UInt64 = 0
        var audioSendTimes: [UInt64] = []
        var videoSends = 0
        let session = Session(
            config: SessionConfig(
                crypto: .insecure, rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0xA11D)
        ) { datagram in
            if datagram.pacerClass == .audio {
                let (envelope, _) = try! Envelope.decode(datagram.bytes)
                let field = try! FecField.decode(envelope.fec)
                if case .reedSolomon(let index, _) = field, index < 4 {
                    audioSendTimes.append(now)
                }
            } else if datagram.pacerClass == .freshVideo {
                videoSends += 1
            }
        }

        var checkpoints = 0
        var packetNumber = 0
        _ = try session.ingestVideoFrame(
            syntheticFrame(byteCount: 59_904, irap: true),
            captureTimestampMicroseconds: 0,
            isKeyframe: true,
            interleave: {
                checkpoints += 1
                now = UInt64(packetNumber) * 5_000_000
                _ = try! session.ingestAudioPacket(
                    self.opusPacket(packetNumber),
                    captureTimestampMicroseconds: now / 1_000,
                    now: now
                )
                packetNumber += 1
                session.pump(now: now)
            },
            now: 0
        )

        XCTAssertGreaterThan(checkpoints, 8,
            "a worst-case IDR must expose repeated audio service points")
        XCTAssertEqual(audioSendTimes.count, checkpoints,
            "every due packet must leave during the video ingest")
        XCTAssertGreaterThan(videoSends, 0)
        for i in 1..<audioSendTimes.count {
            XCTAssertEqual(audioSendTimes[i] - audioSendTimes[i - 1], 5_000_000)
        }
        XCTAssertLessThanOrEqual(
            session.pacerTelemetry[.audio].maxQueueDelayNS, 2_000_000
        )
        XCTAssertEqual(
            session.counters.audioSealedDatagramsAssembledInPlace,
            session.counters.audioDatagramsEnqueued,
            "cooperative IDR service must retain the in-place audio path"
        )
    }
}
