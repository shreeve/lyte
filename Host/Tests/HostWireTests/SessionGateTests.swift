import XCTest
import Foundation
import HostCore
import HostSession
import HostWire
import LyteCore
import LyteWire
import LyteWireTestKit

// THE GATE (build plan HS-7 row): a full loopback-in-process session.
// The host Session (Noise IK responder, statics pinned out-of-band) and a
// test client built from LyteWire's own NoiseSession (initiator) complete
// the handshake; corpus frames ride VideoChannel → Session.seal → the
// paced sink; the client unseals via its NoiseTransport and reassembles
// byte-exact frames through VideoAssembler. Beacons seal/emit at 1 Hz
// plus session start, a synthesized BeaconEcho updates the host's offset
// estimate (and the next beacon mirrors it per W4a), every datagram
// carries the conn-id TLV within the 1152 B budget, a client 0x10 IDR
// request raises the encoder-loop keyframe poll, and a conn-id-bearing
// datagram from a new tuple draws a sealed path challenge on that exact
// tuple. The `--insecure` CP-3 path delivers the same frames through the
// same wiring with the passthrough seal — geometry identical by design.

final class SessionGateTests: XCTestCase {

    func testCapabilityNegotiatorAloneOwnsDeclarationOnceState() throws {
        let source = try sessionSource()

        XCTAssertFalse(source.contains("capabilitiesDeclared"))
        XCTAssertTrue(source.contains(
            "guard let declaration = negotiator.start() else { return [] }"))
    }

    func testLastAdmittedFrameAloneOwnsTheVideoCursor() throws {
        let source = try sessionSource()

        XCTAssertFalse(source.contains(
            "private var nextVideoFrameNumber ="))
        XCTAssertFalse(source.contains("nextVideoFrameNumber ="))
        XCTAssertTrue(source.contains(
            "lastAdmittedVideoFrameNumber?.next ?? FrameNumber(rawValue: 0)"))
        XCTAssertTrue(source.contains(
            "lastAdmittedVideoFrameNumber.next.rawValue > 0"))
        XCTAssertTrue(source.contains(
            "frame: lastAdmittedVideoFrameNumber"))
    }

    private func sessionSource() throws -> String {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false)
        components.removeLast(3)
        let packageRoot = components.joined(separator: "/")
        return try String(
            contentsOfFile: packageRoot + "/Sources/HostWire/Session.swift",
            encoding: .utf8)
    }

    // MARK: Corpus plumbing (the HS-5 gate's, verbatim)

    private static var corpusDirectory: String {
        var components = #filePath.split(
            separator: "/", omittingEmptySubsequences: false)
        components.removeLast(4)
        return components.joined(separator: "/")
            + "/Wire/Vectors/video-corpus-v1"
    }

    private func corpusFrames() throws -> [[UInt8]] {
        try FileManager.default
            .contentsOfDirectory(atPath: Self.corpusDirectory)
            .filter { $0.hasSuffix(".annexb") }
            .sorted()
            .map { name in
                [UInt8](try Data(contentsOf: URL(
                    fileURLWithPath: Self.corpusDirectory + "/" + name
                )))
            }
    }

    private static func captureMicros(_ frameIndex: Int) -> UInt64 {
        5_000_000 + UInt64(frameIndex) * 16_667
    }

    private static let rateBPS = 20_000_000
    private static let frameIntervalNS: UInt64 = 16_666_667

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 47_998,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )
    private static let tupleB = FourTuple(
        localAddress: "10.0.0.249", localPort: 47_998,
        remoteAddress: "172.16.4.9", remotePort: 40_112
    )

    // MARK: The loopback client (LyteWire initiator + unseal side)

    /// The far end of the loopback: LyteWire's NoiseSession as the
    /// initiator (the client role), with the host's static pinned
    /// out-of-band exactly as J-G1's debug client will hold it.
    private struct LoopbackClient {
        var noise: NoiseSession
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        let staticKeys: NoiseKeyPair

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

        /// One client→host CTRL datagram with the client seam's exact
        /// discipline: header bytes as AAD, per-channel seq.
        mutating func ctrlDatagram(
            body: [UInt8],
            sealed: Bool,
            clientMicros: UInt64,
            extensions: [WireExtension] = []
        ) throws -> [UInt8] {
            let envelope = Envelope(
                channel: .ctrl,
                seq: ChannelSeq(rawValue: ctrlSeq),
                frame: FrameNumber(rawValue: 0),
                timestamp: clientMicros,
                fec: 0,
                extensions: extensions
            )
            ctrlSeq &+= 1
            guard sealed else { return try envelope.encode(payload: body) }
            let header = try envelope.encode(payload: [])
            let payload = try transport!.seal(
                plaintext: body[...], aad: header[...], envelope: envelope
            )
            return try envelope.encode(payload: payload)
        }

        /// Decodes one host datagram, completing the handshake on a bare
        /// message 2 and unsealing everything else. Returns the envelope
        /// and the plaintext payload.
        mutating func absorb(
            _ bytes: [UInt8]
        ) throws -> (envelope: Envelope, plaintext: [UInt8]) {
            let (envelope, payload) = try Envelope.decode(bytes)
            if transport == nil {
                guard envelope.channel == .ctrl,
                      payload.first == CtrlMessageType.noiseHandshake2
                else {
                    XCTFail("expected bare message 2 first, got chan "
                        + "\(envelope.channel.rawValue)")
                    throw NoiseError.missingVersionPayload
                }
                _ = try noise.readMessage2(payload.dropFirst())
                transport = try noise.makeTransport()
                return (envelope, Array(payload))
            }
            let aad = bytes[bytes.startIndex..<payload.startIndex]
            let plaintext = try transport!.unseal(
                wirePayload: payload, aad: aad, envelope: envelope
            )
            return (envelope, plaintext)
        }
    }

    /// Pumps the session at its own wake instants up to (not including)
    /// `horizon` — the sans-IO event loop, minus the syscalls.
    private func drain(
        _ session: Session, from start: UInt64, horizon: UInt64,
        hostMicros: (UInt64) -> UInt64 = { $0 / 1_000 }
    ) -> UInt64 {
        var now = start
        session.pump(now: now)
        while let wake = session.nextWake(now: now), wake < horizon {
            now = max(now &+ 1, wake)
            _ = session.advance(now: now, hostMicroseconds: hostMicros(now))
            session.pump(now: now)
        }
        return now
    }

    // MARK: The gate — Noise path

    func testGateNoiseLoopbackSessionEndToEnd() throws {
        let frames = try corpusFrames()
        XCTAssertEqual(frames.count, 13, "the corpus is a frozen artifact")

        let hostStatic = NoiseKeyPair.generate()
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: Self.rateBPS
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x7)
        ) { sent.append($0) }
        XCTAssertEqual(session.phase, .awaitingHandshake)

        // Video may not flow before the handshake.
        XCTAssertThrowsError(try session.ingestVideoFrame(
            frames[0], captureTimestampMicroseconds: 1,
            isKeyframe: true, now: 0
        )) {
            XCTAssertEqual($0 as? SessionError, .notEstablished)
        }

        // ── Handshake: msg1 in, msg2 + session-start beacon out ────────
        var client = try LoopbackClient(hostStaticPublicKey: hostStatic.publicKey)
        let message1 = try client.message1Datagram(clientMicros: 3_500_000)
        let t1Beacon0: UInt64 = 1_000_000
        let handshakeEvents = session.receive(
            message1, from: Self.tupleA, now: 0, hostMicroseconds: t1Beacon0
        )
        XCTAssertEqual(session.phase, .established)
        XCTAssertEqual(handshakeEvents, [
            .handshakeCompleted(remoteStaticPublicKey: client.staticKeys.publicKey),
            .beaconSent(beaconSeq: 0),
        ])

        _ = drain(session, from: 0, horizon: Self.frameIntervalNS)
        XCTAssertEqual(
            sent.count, 3,
            "message 2, the session-start beacon, the capability declaration"
        )
        XCTAssertTrue(sent.allSatisfy { $0.pacerClass == .control })

        let (_, message2Payload) = try client.absorb(sent[0].bytes)
        XCTAssertEqual(message2Payload.first, CtrlMessageType.noiseHandshake2)
        XCTAssertNotNil(client.transport)
        XCTAssertEqual(client.transport!.handshakeHash.count, 32,
                       "the transcript hash the W6 PAKE will bind to")

        let (beacon0Envelope, beacon0Plain) = try client.absorb(sent[1].bytes)
        XCTAssertEqual(beacon0Envelope.channel, .ctrl)
        let beacon0 = try ClockBeacon.decode(beacon0Plain)
        XCTAssertEqual(beacon0.beaconSeq, 0)
        XCTAssertEqual(beacon0.hostSend.microseconds, t1Beacon0)
        XCTAssertNil(beacon0.lastEcho, "no echo has happened yet")

        // The W7 declaration is the first ARQ-carried word: an ARQ
        // segment whose message body is `0x0F ‖ deterministic CBOR` —
        // the host's wireDefault capability set.
        let (_, declarationPlain) = try client.absorb(sent[2].bytes)
        XCTAssertEqual(declarationPlain.first, CtrlMessageType.arqSegment)
        let declarationFrames = try ArqFrame.decodeAll(declarationPlain)
        guard case .segment(let declarationSegment)? = declarationFrames.first
        else {
            return XCTFail("expected the declaration's ARQ segment")
        }
        XCTAssertEqual(
            declarationSegment.body.first,
            CtrlMessageType.capabilityDeclaration,
            "the capability declaration must be the first reliable message"
        )
        XCTAssertEqual(
            try CapabilityDeclaration.decode(Array(declarationSegment.body))
                .capabilities,
            Capabilities.wireDefault
        )

        // ── Echo: one NTP-style sample updates the host's estimate ─────
        // Client clock = host clock + 2.5 s; 5 ms transit each way,
        // 300 µs turnaround.
        let offset: Int64 = 2_500_000
        let t2 = UInt64(Int64(t1Beacon0) + 5_000 + offset)
        let t3 = t2 + 300
        let t4 = t1Beacon0 + 10_300
        let echo = BeaconEcho(
            beaconSeq: 0,
            hostSend: HostTimestamp(microseconds: t1Beacon0),
            clientReceive: ClientTimestamp(microseconds: t2),
            clientSend: ClientTimestamp(microseconds: t3)
        )
        let echoDatagram = try client.ctrlDatagram(
            body: echo.encode(), sealed: true, clientMicros: t3
        )
        let echoEvents = session.receive(
            echoDatagram, from: Self.tupleA, now: 1_000_000, hostMicroseconds: t4
        )
        XCTAssertEqual(echoEvents, [.beaconEchoAccepted(
            beaconSeq: 0, offsetMicroseconds: offset, rttMicroseconds: 10_000
        )])
        XCTAssertEqual(session.clock.samples, 1)
        XCTAssertEqual(session.clock.lastOffsetMicroseconds, offset)
        XCTAssertEqual(session.clock.lastRttMicroseconds, 10_000)
        XCTAssertEqual(session.clock.minRttOffsetMicroseconds, offset)

        // ── Video: corpus → seal → unseal → assembler, byte-exact ──────
        var clock: UInt64 = 2_000_000
        for (i, frame) in frames.enumerated() {
            clock = max(clock, UInt64(i) * Self.frameIntervalNS)
            XCTAssertTrue(session.isIdle,
                          "frame \(i): previous frame still draining")
            try session.ingestVideoFrame(
                frame,
                captureTimestampMicroseconds: Self.captureMicros(i),
                isKeyframe: AnnexBCheck.containsIrap(frame),
                now: clock
            )
            clock = drain(
                session, from: clock,
                horizon: UInt64(i + 1) * Self.frameIntervalNS
            )
        }
        clock = drain(session, from: clock, horizon: 900_000_000)
        XCTAssertTrue(session.isIdle)

        let videoDatagrams = sent.filter { $0.pacerClass == .freshVideo }
        XCTAssertFalse(videoDatagrams.isEmpty)

        // Every datagram this session ever sent — control and video —
        // within budget, conn-id-tagged, primary-path routed.
        for datagram in sent {
            XCTAssertLessThanOrEqual(
                datagram.bytes.count, WireBudget.maxDatagramByteCount,
                "datagram over the 1152 B budget"
            )
            XCTAssertNil(datagram.destination)
            let (envelope, _) = try Envelope.decode(datagram.bytes)
            XCTAssertEqual(
                try ConnectionId.decode(extensions: envelope.extensions),
                session.connectionId,
                "every session datagram carries the conn-id TLV"
            )
        }

        var assembler = VideoAssembler()
        var units: [DecodeUnit] = []
        var rxNow = ClientTimestamp(microseconds: 0)
        for datagram in videoDatagrams {
            rxNow = rxNow.advanced(byMicroseconds: 25)
            let (envelope, plaintext) = try client.absorb(datagram.bytes)
            XCTAssertEqual(envelope.channel, .videoActive)
            for event in assembler.ingest(
                envelope: envelope, payload: plaintext[...], now: rxNow
            ) {
                if case .decoded(let unit) = event { units.append(unit) }
            }
        }
        XCTAssertEqual(units.count, frames.count)
        XCTAssertEqual(
            units.map(\.annexB), frames,
            "frames are not byte-exact through the sealed path"
        )
        for unit in units {
            XCTAssertEqual(
                unit.timestamp.microseconds,
                Self.captureMicros(Int(unit.frameNumber.rawValue)),
                "capture µs must survive the sealed pipeline"
            )
        }
        XCTAssertTrue(units[0].isIDR)

        // ── IDR-on-demand: a client 0x10 raises the encoder poll ───────
        XCTAssertFalse(session.takeFreshKeyframeRequest())
        let request = IdrRequest(
            requestSeq: 0, frame: FrameNumber(rawValue: 7), coalescedCount: 2
        )
        let idrEvents = session.receive(
            try client.ctrlDatagram(
                body: request.encode(), sealed: true, clientMicros: t3 + 1_000
            ),
            from: Self.tupleA, now: clock, hostMicroseconds: t4 + 1_000
        )
        // The long feedback-free drain froze the lifecycle machine (the
        // 350 ms detector — no chan-3 traffic exists in this harness);
        // this first returning CTRL evidence is also the RECOVERY exit,
        // and the HS-16 estimator paces its IDR at the half-stale rate.
        XCTAssertEqual(idrEvents, [
            .lifecycleChanged(.recovery),
            .rateChanged(
                bitsPerSecond: Self.rateBPS / 2,
                reason: .idrPacing(.halfStaleEstimate)
            ),
            .idrRequested(request),
        ])
        XCTAssertTrue(session.takeFreshKeyframeRequest(),
                      "the 0x10 must raise the keyframe poll")
        XCTAssertFalse(session.takeFreshKeyframeRequest(),
                       "the poll fires once per demand")

        // The forced IDR the poll demands, through the sealed path.
        let preIdrCount = sent.count
        try session.ingestVideoFrame(
            frames[0],
            captureTimestampMicroseconds: Self.captureMicros(13),
            isKeyframe: true,
            now: clock
        )
        clock = drain(session, from: clock, horizon: 900_000_000)
        let forced = sent[preIdrCount...]
        XCTAssertFalse(forced.isEmpty)
        XCTAssertTrue(forced.allSatisfy(\.isKeyframe),
                      "the demanded frame reaches the wire as keyframe shards")

        // ── 1 Hz beacon with the W4a mirror of the last echo ───────────
        let t1Beacon1: UInt64 = 2_000_000
        let preBeaconCount = sent.count
        let beaconEvents = session.advance(
            now: 1_000_000_000, hostMicroseconds: t1Beacon1
        )
        // RECOVERY without feedback re-freezes 350 ms later by design
        // (this harness has no chan-3 stream), so the wake may carry a
        // lifecycle event alongside the beacon.
        XCTAssertEqual(beaconEvents.first, .beaconSent(beaconSeq: 1))
        session.pump(now: 1_000_000_000)
        // The unacknowledged declaration may PTO-retransmit alongside
        // the beacon (this harness client has no ARQ endpoint to ack
        // it) — absorb everything new, keep the beacon.
        var beacon1Plain: [UInt8]?
        for datagram in sent[preBeaconCount...]
        where datagram.pacerClass == .control {
            let (_, plain) = try client.absorb(datagram.bytes)
            if plain.first == CtrlMessageType.clockBeacon {
                beacon1Plain = plain
            }
        }
        guard let beacon1Plain else {
            return XCTFail("no beacon left on the 1 s advance")
        }
        let beacon1 = try ClockBeacon.decode(beacon1Plain)
        XCTAssertEqual(beacon1.beaconSeq, 1)
        XCTAssertEqual(beacon1.hostSend.microseconds, t1Beacon1)
        XCTAssertEqual(
            beacon1.lastEcho,
            ClockBeacon.LastEcho(
                beaconSeq: 0,
                clientSend: ClientTimestamp(microseconds: t3),
                hostReceive: HostTimestamp(microseconds: t4)
            ),
            "the beacon mirrors the last echo's t3 verbatim and our t4"
        )

        // ── Migration hook: a conn-id datagram from a new tuple draws a
        // sealed challenge on that exact tuple (HS-12 wiring, in vivo) ──
        let roamEcho = BeaconEcho(
            beaconSeq: 1,
            hostSend: HostTimestamp(microseconds: t1Beacon1),
            clientReceive: ClientTimestamp(microseconds: t3 + 900_000),
            clientSend: ClientTimestamp(microseconds: t3 + 900_400)
        )
        let roamDatagram = try client.ctrlDatagram(
            body: roamEcho.encode(), sealed: true,
            clientMicros: t3 + 900_400,
            extensions: [session.connectionId.wireExtension]
        )
        let preChallengeCount = sent.count
        let roamEvents = session.receive(
            roamDatagram, from: Self.tupleB,
            now: 1_100_000_000, hostMicroseconds: t4 + 900_000
        )
        guard case .path(.sendChallenge(let on, let challenge))? = roamEvents.first
        else {
            return XCTFail("expected a path challenge, got \(roamEvents)")
        }
        XCTAssertEqual(on, Self.tupleB)
        session.pump(now: 1_100_000_000)
        let challengeDatagram = sent[preChallengeCount]
        XCTAssertEqual(challengeDatagram.pacerClass, .control)
        XCTAssertEqual(challengeDatagram.destination, Self.tupleB,
                       "the challenge must travel on the probed tuple")
        let (_, challengePlain) = try client.absorb(challengeDatagram.bytes)
        XCTAssertEqual(
            try PathChallenge.decode(challengePlain), challenge,
            "the sealed challenge decodes to the validator's token"
        )

        let expectedShards = try frames.map {
            try shardCount(frameBytes: $0.count)
        }.reduce(0, +)
        print("HS-7 gate (Noise): handshake 1-RTT, \(frames.count) corpus "
            + "frames → \(videoDatagrams.count) sealed datagrams "
            + "(\(expectedShards) expected shards + forced IDR "
            + "\(forced.count)), \(units.count) frames byte-exact through "
            + "unseal; offset \(offset) µs / rtt 10000 µs recovered exactly; "
            + "beacon 1 mirrored the echo; challenge on \(on.remoteAddress)")
    }

    /// The ladder's shard count at the session's TLV-adjusted budget.
    private func shardCount(frameBytes: Int) throws -> Int {
        let budget = 1_101 // 1128 − 16 (tag) − 11 (conn-id TLV block)
        let k = (frameBytes + budget - 1) / budget
        let m = try FecGeometryTable.parityShards(forDataShards: k, regime: .clean)
        return k + m
    }

    // MARK: The gate — `--insecure` CP-3 path

    func testGateInsecureLoopbackDeliversFrames() throws {
        let frames = try Array(corpusFrames().prefix(4))
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .insecure,
                rateBitsPerSecond: Self.rateBPS
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x11)
        ) { sent.append($0) }
        XCTAssertEqual(session.phase, .established,
                       "insecure mode has no handshake to wait for")

        // First timer wake: the capability declaration (insecure mode
        // reaches establishment without a handshake, so the first wake
        // is where the W7 first-word rule lands) and the session-start
        // beacon, both plaintext.
        let startEvents = session.advance(now: 0, hostMicroseconds: 77_000)
        XCTAssertEqual(startEvents, [.beaconSent(beaconSeq: 0)])
        session.pump(now: 0)
        XCTAssertEqual(sent.count, 2, "capability declaration + beacon")
        let (declarationEnvelope, declarationPayload) =
            try Envelope.decode(sent[0].bytes)
        XCTAssertEqual(declarationEnvelope.channel, .ctrl)
        XCTAssertEqual(declarationPayload.first, CtrlMessageType.arqSegment)
        let (beaconEnvelope, beaconPayload) = try Envelope.decode(sent[1].bytes)
        XCTAssertEqual(beaconEnvelope.channel, .ctrl)
        let beacon = try ClockBeacon.decode(beaconPayload)
        XCTAssertEqual(beacon.beaconSeq, 0)
        XCTAssertEqual(beacon.hostSend.microseconds, 77_000)

        // Corpus frames, passthrough seal: the payload IS the shard.
        var clock: UInt64 = 1
        for (i, frame) in frames.enumerated() {
            clock = max(clock, UInt64(i) * Self.frameIntervalNS)
            try session.ingestVideoFrame(
                frame,
                captureTimestampMicroseconds: Self.captureMicros(i),
                isKeyframe: AnnexBCheck.containsIrap(frame),
                now: clock
            )
            clock = drain(
                session, from: clock,
                horizon: UInt64(i + 1) * Self.frameIntervalNS
            )
        }
        clock = drain(session, from: clock, horizon: 900_000_000)

        var assembler = VideoAssembler()
        var units: [DecodeUnit] = []
        var rxNow = ClientTimestamp(microseconds: 0)
        for datagram in sent where datagram.pacerClass == .freshVideo {
            XCTAssertLessThanOrEqual(
                datagram.bytes.count, WireBudget.maxDatagramByteCount
            )
            let (envelope, payload) = try Envelope.decode(datagram.bytes)
            XCTAssertEqual(
                try ConnectionId.decode(extensions: envelope.extensions),
                session.connectionId,
                "insecure datagrams still carry the conn-id TLV"
            )
            rxNow = rxNow.advanced(byMicroseconds: 25)
            for event in assembler.ingest(
                envelope: envelope, payload: payload, now: rxNow
            ) {
                if case .decoded(let unit) = event { units.append(unit) }
            }
        }
        XCTAssertEqual(units.map(\.annexB), frames,
                       "insecure path must deliver byte-exact frames")

        // A plaintext echo still feeds the clock estimate.
        let echo = BeaconEcho(
            beaconSeq: 0,
            hostSend: HostTimestamp(microseconds: 77_000),
            clientReceive: ClientTimestamp(microseconds: 80_000),
            clientSend: ClientTimestamp(microseconds: 80_500)
        )
        let echoEnvelope = Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0), timestamp: 80_500, fec: 0
        )
        let echoEvents = session.receive(
            try echoEnvelope.encode(payload: echo.encode()),
            from: Self.tupleA, now: clock, hostMicroseconds: 84_000
        )
        // The feedback-free drain froze the machine; this first CTRL
        // evidence is also the RECOVERY exit (the Noise gate's pattern),
        // with the HS-16 half-stale pacing applied on the way.
        XCTAssertEqual(echoEvents, [
            .lifecycleChanged(.recovery),
            .rateChanged(
                bitsPerSecond: Self.rateBPS / 2,
                reason: .idrPacing(.halfStaleEstimate)
            ),
            .beaconEchoAccepted(
                beaconSeq: 0,
                offsetMicroseconds: Int64(3_000 + (-3_500)) / 2,
                rttMicroseconds: 6_500
            ),
        ])
        XCTAssertEqual(session.clock.samples, 1)

        print("HS-7 gate (--insecure): \(units.count) frames byte-exact, "
            + "beacon + echo through the passthrough seal")
    }

    // MARK: Budget boundary and mode-independent geometry

    /// A synthetic frame-shaped Annex-B blob of exactly `byteCount`
    /// bytes: start code + a TRAIL_R VCL NAL padded with bytes that can
    /// never form a start code.
    private func syntheticFrame(byteCount: Int) -> [UInt8] {
        precondition(byteCount >= 6)
        // NAL header 0x02 0x01: type (0x02 >> 1) & 0x3F = 1 = TRAIL_R.
        return [0, 0, 0, 1, 0x02, 0x01]
            + [UInt8](repeating: 0xAA, count: byteCount - 6)
    }

    // MARK: The capture gate's backlog surface (the fps-ceiling fix)

    /// `queuedVideoBytes` is what the capture loop's backpressure gate
    /// reads now that the pacer drain runs off the capture thread: a
    /// multi-quantum frame shows up as standing video backlog the
    /// moment it is ingested, and the surface reads zero again once
    /// the pacer has walked it out at its own wake instants.
    func testQueuedVideoBytesSurfacesTheCaptureGateBacklog() throws {
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .insecure,
                rateBitsPerSecond: Self.rateBPS
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x22)
        ) { sent.append($0) }
        XCTAssertEqual(session.queuedVideoBytes, 0,
                       "an idle session holds no video backlog")
        // The opening declaration + beacon leave first — CTRL traffic
        // must never read as video backlog.
        _ = session.advance(now: 0, hostMicroseconds: 0)
        session.pump(now: 0)
        XCTAssertEqual(session.queuedVideoBytes, 0,
                       "CTRL bytes are not the capture gate's business")

        // One 40 KB frame at 20 Mbps spans ~16 pacer quanta: after the
        // first pump only one quantum has left, the rest is exactly
        // the standing backlog the gate reads.
        let frame = syntheticFrame(byteCount: 40_000)
        try session.ingestVideoFrame(
            frame, captureTimestampMicroseconds: 1,
            isKeyframe: false, now: 1
        )
        session.pump(now: 1)
        let backlog = session.queuedVideoBytes
        XCTAssertGreaterThan(
            backlog, frame.count - 5_000,
            "a just-ingested multi-quantum frame stands as backlog "
                + "(shard bytes minus at most the burst quantum)"
        )

        // The pacer walks it out at its own wakes; the gate reopens.
        _ = drain(session, from: 1, horizon: 900_000_000)
        XCTAssertEqual(session.queuedVideoBytes, 0,
                       "a drained pacer means no standing backlog")
    }

    /// EAGAIN is not a send. The Linux shell may retain pacer-released
    /// datagrams for a later socket retry; until confirmation they must remain
    /// backlog (for admission and NACK recusal) and must not enter the
    /// estimator under the earlier pacer timestamp.
    func testSocketConfirmedSendAccountingKeepsEagainOutboxPending() throws {
        var outbox: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .insecure,
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0xEA61),
            sendAccounting: .socketConfirmed
        ) { outbox.append($0) }

        let frame = syntheticFrame(byteCount: 20_000)
        try session.ingestVideoFrame(
            frame, captureTimestampMicroseconds: 1,
            isKeyframe: false, now: 1
        )
        _ = drain(session, from: 1, horizon: 900_000_000)

        let pendingBytes = outbox
            .filter {
                $0.pacerClass == .freshVideo || $0.pacerClass == .videoTail
                    || $0.pacerClass == .refinement
            }
            .reduce(0) { $0 + $1.bytes.count }
        XCTAssertGreaterThan(pendingBytes, 0)
        XCTAssertEqual(session.queuedVideoBytes, pendingBytes,
            "pacer drain cannot erase an EAGAIN-retained socket outbox")
        XCTAssertEqual(session.estimatorStats.dispersionSamplesMatched, 0,
            "unconfirmed datagrams must not exist in the send ledger")

        _ = try session.ingestAudioPacket(
            [0xF8, 0xFF, 0xFE],
            captureTimestampMicroseconds: 1_000_000,
            now: 1_000_000_000
        )
        XCTAssertGreaterThan(session.pumpLatency(now: 1_000_000_000), 0,
            "audio must leave the pacer despite a blocked video outbox")
        let originalVideoOrder = outbox
            .filter { $0.pacerClass == .freshVideo }
            .map(\.seq)
        let prioritized = Session.prioritizeLatency(outbox)
        let audioIndex = try XCTUnwrap(
            prioritized.firstIndex { $0.pacerClass == .audio })
        let videoIndex = try XCTUnwrap(
            prioritized.firstIndex { $0.pacerClass == .freshVideo })
        XCTAssertLessThan(audioIndex, videoIndex,
            "sealed audio crosses channels ahead of retained video")
        XCTAssertEqual(
            prioritized.filter { $0.pacerClass == .freshVideo }.map(\.seq),
            originalVideoOrder,
            "latency bypass must not reorder channel-2 datagrams")
        XCTAssertEqual(
            prioritized.first { $0.pacerClass == .audio }?.bytes,
            outbox.first { $0.pacerClass == .audio }?.bytes,
            "priority partition must preserve authenticated bytes exactly")

        for datagram in prioritized {
            session.confirmDatagramSent(datagram, now: 1_000_000_000)
        }
        XCTAssertEqual(session.queuedVideoBytes, 0,
            "kernel acceptance completes the send and releases backlog")
    }

    /// The Linux lock split's deterministic contract: pure RS-FEC
    /// preparation reserves no frame/channel/Noise state, so the Session
    /// owner may service a 5 ms audio packet before committing the frame.
    /// Commit then advances video exactly once; replaying the context is loud.
    func testPreparedVideoLeavesSessionServiceableUntilOrderedCommit() throws {
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .insecure,
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0xFEC)
        ) { sent.append($0) }
        let frame = syntheticFrame(byteCount: 80_000)
        let context = try XCTUnwrap(
            session.beginVideoFramePreparation(encodedByteCount: frame.count)
        )
        XCTAssertNil(session.lastAdmittedVideoFrameNumber)

        let prepared = try Session.prepareVideoFrame(
            frame, isKeyframe: false, context: context
        )
        XCTAssertGreaterThan(prepared.shardCount, 64)
        XCTAssertEqual(session.videoCounters.framesIngested, 0)
        XCTAssertEqual(session.queuedVideoBytes, 0)

        _ = try session.ingestAudioPacket(
            [0xF8, 0xFF, 0xFE],
            captureTimestampMicroseconds: 5_000,
            now: 5_000_000
        )
        session.pump(now: 5_000_000)
        XCTAssertEqual(sent.count { $0.pacerClass == .audio }, 1)
        XCTAssertEqual(sent.count { $0.pacerClass == .freshVideo }, 0)

        let shards = try session.commitPreparedVideoFrame(
            prepared,
            context: context,
            captureTimestampMicroseconds: 1,
            now: 5_000_001,
            isBorrowed: true
        )
        XCTAssertEqual(shards, prepared.shardCount)
        XCTAssertEqual(session.videoCounters.framesIngested, 1)
        XCTAssertEqual(session.videoCounters.borrowedFramesIngested, 1)
        XCTAssertEqual(
            session.lastAdmittedVideoFrameNumber,
            FrameNumber(rawValue: 0))

        XCTAssertThrowsError(try session.commitPreparedVideoFrame(
            prepared,
            context: context,
            captureTimestampMicroseconds: 1,
            now: 5_000_002
        )) {
            XCTAssertEqual($0 as? SessionError, .staleVideoPreparation)
        }
        XCTAssertEqual(session.videoCounters.framesIngested, 1)

        let nextContext = try XCTUnwrap(
            session.beginVideoFramePreparation(encodedByteCount: frame.count)
        )
        _ = try session.commitPreparedVideoFrame(
            prepared,
            context: nextContext,
            captureTimestampMicroseconds: 2,
            now: 5_000_003
        )
        XCTAssertEqual(
            session.lastAdmittedVideoFrameNumber,
            FrameNumber(rawValue: 1))
    }

    func testShardBudgetLandsExactlyOnTheDatagramCeiling() throws {
        // With the conn-id TLV the plaintext budget is 1101 B: a
        // single-shard frame + a real 16 B tag lands on 1152 exactly.
        var rng = SplitMix64(seed: 0x2)
        let connId = ConnectionId.random(using: &rng)
        let config = VideoChannelConfig(
            rateBitsPerSecond: Self.rateBPS, connectionId: connId
        )
        XCTAssertEqual(config.shardBudgetByteCount, 1_101)

        // A tag-sized fake seal proves the arithmetic without a
        // handshake: plaintext ‖ 16 zero bytes, exactly Noise's growth.
        var emitted: [VideoChannelDatagram] = []
        let channel = VideoChannel(
            config: config,
            now: 0,
            seal: { plaintext, _, _ in
                Array(plaintext) + [UInt8](repeating: 0, count: 16)
            }
        ) { emitted.append($0) }

        try channel.ingest(
            frame: syntheticFrame(byteCount: 1_101),
            frameNumber: FrameNumber(rawValue: 0),
            captureTimestampMicroseconds: 1, isKeyframe: false, now: 0
        )
        var now: UInt64 = 0
        channel.pump(now: 0)
        while let wake = channel.nextWake(now: now) {
            now = max(now &+ 1, wake)
            channel.pump(now: now)
        }
        // k = 1 + the ladder's 1 parity shard; the data shard is full.
        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(
            emitted[0].bytes.count, WireBudget.maxDatagramByteCount,
            "24 + 11 (TLV) + 1101 + 16 (tag) must land exactly on 1152"
        )

        // One byte more splits into two data shards, still in budget.
        emitted.removeAll()
        try channel.ingest(
            frame: syntheticFrame(byteCount: 1_102),
            frameNumber: FrameNumber(rawValue: 1),
            captureTimestampMicroseconds: 2, isKeyframe: false, now: now
        )
        channel.pump(now: now)
        while let wake = channel.nextWake(now: now) {
            now = max(now &+ 1, wake)
            channel.pump(now: now)
        }
        XCTAssertEqual(emitted.count, 3, "k = 2 + 1 parity")
        for datagram in emitted {
            XCTAssertLessThanOrEqual(
                datagram.bytes.count, WireBudget.maxDatagramByteCount
            )
        }

        // Without the TLV the budget stays the frozen 1112 (HS-5's
        // geometry, unchanged): 24 + 1112 + 16 = 1152 exactly.
        XCTAssertEqual(
            VideoChannelConfig(rateBitsPerSecond: Self.rateBPS)
                .shardBudgetByteCount,
            WireBudget.maxPlaintextShardByteCount
        )
    }

    func testGeometryIsIdenticalWithAndWithoutSeal() throws {
        // §4.2's rule, held by construction: the `--insecure` passthrough
        // and the no-seal HS-5 shape emit byte-identical datagrams, so
        // FEC geometry and gate results never depend on the crypto mode.
        var rng = SplitMix64(seed: 0x3)
        let connId = ConnectionId.random(using: &rng)
        let frame = syntheticFrame(byteCount: 4_321)

        func emit(seal: VideoChannelSealer?) throws -> [[UInt8]] {
            var out: [[UInt8]] = []
            let channel = VideoChannel(
                config: VideoChannelConfig(
                    rateBitsPerSecond: Self.rateBPS, connectionId: connId
                ),
                now: 0,
                seal: seal
            ) { out.append($0.bytes) }
            try channel.ingest(
                frame: frame, frameNumber: FrameNumber(rawValue: 0),
                captureTimestampMicroseconds: 9, isKeyframe: false, now: 0
            )
            var now: UInt64 = 0
            channel.pump(now: 0)
            while let wake = channel.nextWake(now: now) {
                now = max(now &+ 1, wake)
                channel.pump(now: now)
            }
            return out
        }

        let bare = try emit(seal: nil)
        let passthrough = try emit(seal: { plaintext, _, _ in Array(plaintext) })
        XCTAssertEqual(bare, passthrough)
        XCTAssertFalse(bare.isEmpty)
    }

    func testKernelPressureFrameShedArmsOneFreshIDR() {
        let session = Session(
            config: SessionConfig(
                crypto: .insecure,
                rateBitsPerSecond: Self.rateBPS
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x51ED)
        ) { _ in }
        XCTAssertFalse(session.takeFreshKeyframeRequest())
        session.noteKernelPressureFreshVideoShed(
            datagrams: 12, bytes: 13_824)
        XCTAssertEqual(session.counters.kernelPressureShedFrames, 1)
        XCTAssertEqual(session.counters.kernelPressureShedDatagrams, 12)
        XCTAssertEqual(session.counters.kernelPressureShedBytes, 13_824)
        XCTAssertTrue(session.takeFreshKeyframeRequest())
        XCTAssertFalse(session.takeFreshKeyframeRequest(),
            "socket shedding shares the coalesced one-shot IDR latch")
    }
}
