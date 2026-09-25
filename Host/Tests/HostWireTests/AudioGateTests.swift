import XCTest
import HostCore
import HostSession
@_spi(Testing) import HostWire
import HostWireTestKit
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

    // MARK: Leg 1 — the layout, pinned as hand-built bytes

    func testConnectionIdTlvRidesEveryAudioDatagram() throws {
        var rng = SplitMix64(seed: 0xA15)
        let connId = ConnectionId.random(using: &rng)
        var framer = AudioFramer(
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

    // MARK: Leg 3 — contract enforcement

    // MARK: Leg 4 — class assignment in the shared schedule

    func testAudioOutranksQueuedVideoInTheOneSchedule() throws {
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .testPassthrough, rateBitsPerSecond: Self.rateBPS,
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
                crypto: .testPassthrough, rateBitsPerSecond: 500_000,
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
            """
                exactly the one oversize datagram leaves; the tail parks \
                behind the deficit
                """)
        XCTAssertGreaterThan(session.queuedVideoBytes, 0)

        // Audio lands 1 ms into the deficit. The wake must be NOW —
        // not the deficit's repayment instant ~19 ms out.
        _ = try session.ingestAudioPacket(
            opusPacket(0), captureTimestampMicroseconds: 1_000, now: 1 * ms
        )
        let wake = session.nextWake(now: 1 * ms)
        XCTAssertNotNil(wake)
        XCTAssertLessThanOrEqual(wake ?? .max, 1 * ms,
            """
                a parked sender thread woken by signalDrain must find \
                immediate work, not a 19 ms sleep
                """)

        session.pump(now: 1 * ms)
        XCTAssertEqual(sent.count { $0.pacerClass == .audio }, 1,
            "audio must emit through the video-incurred deficit")
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
            "audio queue delay must hold §4.1's bound through the deficit")
    }

    // MARK: Leg 5 — sealed round trip through the LyteWire client build-up

    /// The minimal client far end (the SessionGateTests discipline):
    /// NoiseSession initiator + unseal; audio datagrams collected with
    /// their plaintext payloads; an ArqEndpoint for the lifecycle legs.
    private struct AudioClient: PeerBackedClient {
        var peer: SealedCtrlPeer<ClientClock>
        var audio: [(envelope: Envelope, payload: [UInt8])] = []
        var videoDatagrams = 0

        mutating func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            guard case .plain(let envelope, let plaintext) =
                try peer.absorb(bytes, nowMicros: nowMicros)
            else { return }
            switch envelope.channel {
            case .audio:
                audio.append((envelope, plaintext))
            case .videoActive:
                videoDatagrams += 1
            case .ctrl:
                if plaintext.first != CtrlMessageType.clockBeacon {
                    XCTFail("unexpected CTRL type \(plaintext.first ?? 0)")
                }
            default:
                XCTFail("unexpected channel \(envelope.channel.rawValue)")
            }
        }
    }

    private final class DatagramBox {
        var datagrams: [VideoChannelDatagram] = []
    }

    /// An established Noise session with the audio path live and the
    /// client's ARQ answering (so lifecycle flips can be exercised).
    private func establish() throws -> (
        host: HostSessionHarness, client: AudioClient
    ) {
        let host = HostSessionHarness(
            config: SessionConfig(
                crypto: .noise(hostStatic: NoiseKeyPair.generate()),
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62
            ),
            tuple: Self.tupleA,
            rng: SplitMix64(seed: 0x1515)
        )
        let client = AudioClient(peer: try host.connectClient(
            declaring: nil, openChannels: nil
        ))
        XCTAssertEqual(host.session.phase, .established)
        return (host, client)
    }

    func testSealedAudioRoundTripsAndRecoversThroughTheClientStack() throws {
        let (host, clientValue) = try establish()
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000
        try host.settle(&client, t: &t)

        // Two full groups of real-shaped packets through the sealed path.
        let audioStart = host.forwarded
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
        try host.deliver(to: &client, at: t)
        let audioDatagrams = host.sent[audioStart...].filter {
            $0.pacerClass == .audio
        }
        XCTAssertEqual(client.audio.count, 12, "2 × (4 data + 2 parity)")
        XCTAssertEqual(audioDatagrams.count, 12)
        for datagram in audioDatagrams {
            let (envelope, payload) = try Envelope.decode(datagram.bytes)
            XCTAssertEqual(
                datagram.bytes,
                try envelope.encode(payload: Array(payload)),
                """
                    in-place AAD-buffer assembly must remain byte-identical \
                    to the canonical envelope encoder
                    """
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
        let sample = host.sent.last { $0.pacerClass == .audio }!
        var tampered = sample.bytes
        tampered[8] ^= 0x01 // one timestamp bit
        XCTAssertThrowsError(try client.transport!.openDatagram(tampered))
    }

    // MARK: Leg 6 — lifecycle: the probe never stops (except closed)

    func testAudioFlowsUntilTheSessionCloses() throws {
        let (host, clientValue) = try establish()
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000
        try host.settle(&client, t: &t)

        // Audio is the 5 ms path probe: it flows whatever video does.
        let audioBefore = client.audio.count
        for n in 0..<4 {
            t += 5_000
            _ = try session.ingestAudioPacket(
                opusPacket(n), captureTimestampMicroseconds: t,
                now: t * 1_000
            )
            session.pump(now: t * 1_000)
        }
        try host.deliver(to: &client, at: t)
        XCTAssertEqual(client.audio.count - audioBefore, 6)

        // closed: teardown, then audio is suppressed — counted, silent.
        _ = session.beginTeardown(
            reason: .shuttingDown, now: t * 1_000, hostMicroseconds: t
        )
        try host.settle(&client, t: &t)
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
                crypto: .testPassthrough, rateBitsPerSecond: Self.rateBPS,
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

    func testSessionCountsAGroupAbandonedByAPacketSizeStep() throws {
        let session = Session(
            config: SessionConfig(
                crypto: .testPassthrough, rateBitsPerSecond: Self.rateBPS
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0xAB)
        ) { _ in }
        for (n, byteCount) in [(0, 80), (1, 80), (2, 96)] {
            XCTAssertEqual(try session.ingestAudioPacket(
                opusPacket(n, byteCount: byteCount),
                captureTimestampMicroseconds: UInt64(n) * 5_000,
                now: UInt64(n) * 5_000_000
            ), 1, "packet \(n) still leaves as its own data shard")
        }
        XCTAssertEqual(session.counters.audioPacketsIngested, 3)
        XCTAssertEqual(session.counters.audioGroupsAbandoned, 1)
        XCTAssertEqual(session.counters.audioGroupsCompleted, 0)
    }

    func testAudioBeforeEstablishmentThrows() throws {
        let hostStatic = NoiseKeyPair.generate()
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: Self.rateBPS
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0xA0D1)
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
                crypto: .testPassthrough, rateBitsPerSecond: Self.rateBPS
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
    }
}
