import XCTest
import Foundation
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE GATE (CL-13, the client half of HS-18's host audio routing).
// Pinned behaviors:
//
//   • the 0x18/0x19 codecs are byte-pinned against the SAME hand-built
//     arrays as Host/Tests' AudioRoutingGateTests leg 1 (the cross-pin
//     — mirror-then-promote, the 0x15/0x16/0x17 precedent) and never
//     trap on hostile bytes;
//   • capability key 9 rides the W7 forward-compat spine byte-equal to
//     the host's encoding: the declaration is wireDefault's frozen
//     bytes plus map-head bump plus one appended `09 F5` — nothing
//     else moves — and the session core's DEFAULT config declares it;
//   • in vivo, against a scripted key-9 host in virtual time: the
//     host's starting 0x19 surfaces as the confirmed posture, a
//     requested flip round-trips 0x18 → 0x19 → callback, a FAILED flip
//     reports the old posture (the UI's snap-back), and the
//     session-start posture parameter sends exactly one 0x18 when the
//     desire differs from the host's default;
//   • the rule-3 gate holds: against a no-key-9 host the ask is
//     refused BEFORE a byte leaves, a hostile unnegotiated 0x19 drops
//     loud, and a role-confused 0x18 arriving at the client drops
//     loud;
//   • the per-host default plumbing: pre-CL-13 pinned_hosts.json
//     decodes unchanged, the preference survives a re-pair's dial-hint
//     refresh, and the setter refuses unknown hashes;
//   • CL-18, the flipped default posture: a FRESH config desires
//     hostMuted (sound follows the viewer — the Sunshine/Moonlight
//     posture), so a new session against a key-9 audible host sends
//     exactly one [0x18 0x02] with nothing configured; the per-host
//     preference reads as opt-out (nil/true → muted, explicit false →
//     the "start audible" opt-out, which suppresses the ask against an
//     audible host and still asks [0x18 0x01] against a muted one);
//     migration is by construction — CL-13's setters never wrote
//     false, so stored trues keep their meaning and only the unset
//     default flips.

final class AudioRoutingClientGateTests: XCTestCase {

    // MARK: Leg 1 — the 0x18/0x19 bytes, pinned (the host cross-pin)

    func testRoutingCodecsPinBytes() throws {
        XCTAssertEqual(
            AudioRoutingRequest(mode: .hostAudible).encode(), [0x18, 0x01]
        )
        XCTAssertEqual(
            AudioRoutingRequest(mode: .hostMuted).encode(), [0x18, 0x02]
        )
        XCTAssertEqual(
            AudioRoutingStatus(mode: .hostAudible).encode(), [0x19, 0x01]
        )
        XCTAssertEqual(
            AudioRoutingStatus(mode: .hostMuted).encode(), [0x19, 0x02]
        )
        for mode in HostAudioRoutingMode.allCases {
            XCTAssertEqual(
                try AudioRoutingRequest.decode(
                    AudioRoutingRequest(mode: mode).encode()
                ).mode, mode
            )
            XCTAssertEqual(
                try AudioRoutingStatus.decode(
                    AudioRoutingStatus(mode: mode).encode()
                ).mode, mode
            )
        }
        print("CL-13 gate (codec): 0x18/0x19 pinned byte-exact "
            + "against the host arrays")
    }

    func testHostileRoutingBytesRejectAndNeverTrap() {
        // Truncation.
        XCTAssertThrowsError(try AudioRoutingRequest.decode([0x18]))
        XCTAssertThrowsError(try AudioRoutingStatus.decode([0x19]))
        XCTAssertThrowsError(try AudioRoutingRequest.decode([]))
        // Foreign type byte (each other's, and a stranger's).
        XCTAssertThrowsError(try AudioRoutingRequest.decode([0x19, 0x01]))
        XCTAssertThrowsError(try AudioRoutingStatus.decode([0x18, 0x01]))
        XCTAssertThrowsError(try AudioRoutingRequest.decode([0x7F, 0x01]))
        // Unknown modes: 0, 3, 255.
        for mode: UInt8 in [0x00, 0x03, 0xFF] {
            XCTAssertThrowsError(try AudioRoutingRequest.decode([0x18, mode]))
            XCTAssertThrowsError(try AudioRoutingStatus.decode([0x19, mode]))
        }
        // Trailing bytes.
        XCTAssertThrowsError(try AudioRoutingRequest.decode([0x18, 0x01, 0]))
        XCTAssertThrowsError(try AudioRoutingStatus.decode([0x19, 0x02, 0]))
    }

    // MARK: Leg 2 — key 9 on the spine, zero frozen bytes (client side)

    func testCapabilityKeyRidesTheSpineWithoutMovingFrozenBytes() throws {
        let base = try Capabilities.wireDefault.encodeCbor()
        // wireDefault is an 8-entry map — the frozen v1 shape.
        XCTAssertEqual(base.first, 0xA8)

        // The declaration is EXACTLY the frozen bytes plus one appended
        // entry: map(9) head + trailing `09 F5` (key 9 sorts last in
        // RFC 8949 bytewise order among keys 1–9). Nothing between
        // moves — byte-equal to the host's declaration by construction,
        // which is what lets the intersection's byte-equal rule keep it.
        var expected = base
        expected[0] = 0xA9
        expected += [0x09, 0xF5]
        let declared = Capabilities.wireDefault.declaringHostAudioRouting()
        XCTAssertEqual(try declared.encodeCbor(), expected)

        // Reads back as itself through the v1 decoder: key 9 lands in
        // unknownEntries and the typed accessor sees it.
        let decoded = try Capabilities.decodeCbor(declared.encodeCbor())
        XCTAssertTrue(decoded.hostAudioRouting)
        XCTAssertEqual(decoded, declared)
        XCTAssertEqual(decoded.unknownEntries.count, 1)
        XCTAssertFalse(Capabilities.wireDefault.hostAudioRouting)

        // Idempotent declaration; canonical through the 0x0F codec.
        XCTAssertEqual(declared.declaringHostAudioRouting(), declared)
        let message = try CapabilityDeclaration(capabilities: declared).encode()
        XCTAssertEqual(
            try CapabilityDeclaration.decode(message).capabilities, declared
        )

        // The session core's DEFAULT declaration carries key 9: the
        // client can always render the control, so it always declares
        // (the intersection decides existence).
        XCTAssertTrue(LyteUdpSessionCoreConfig().capabilities.hostAudioRouting)

        print("CL-13 gate (spine): declaration = frozen bytes + `09 F5`, "
            + "nothing else moved; core default declares")
    }

    func testIntersectionEnablesOnlyOnMutualDeclaration() throws {
        let declared = Capabilities.wireDefault.declaringHostAudioRouting()

        // Both declare → survives, both argument orders.
        XCTAssertTrue(declared.intersecting(declared).hostAudioRouting)

        // One-sided → dropped, both orders.
        XCTAssertFalse(declared.intersecting(.wireDefault).hostAudioRouting)
        XCTAssertFalse(
            Capabilities.wireDefault.intersecting(declared).hostAudioRouting
        )

        // A peer declaring key 9 FALSE is not byte-equal to true:
        // absence and refusal are the same posture.
        var refusing = Capabilities.wireDefault
        refusing.unknownEntries.append(CborMapEntry(
            key: .unsigned(CapabilityKey.hostAudioRouting),
            value: .bool(false)
        ))
        XCTAssertFalse(refusing.hostAudioRouting)
        XCTAssertFalse(declared.intersecting(refusing).hostAudioRouting)
    }

    // MARK: - The scripted host (HS-18's discipline from Wire parts)

    /// A key-9-capable host stand-in: Noise responder, host-clock ARQ,
    /// capability negotiator (declaration = first reliable word), and
    /// HS-18's routing rules — the starting 0x19 at agreement, one
    /// 0x19 per applied flip, a scriptable FAILED flip that re-reports
    /// the old posture. No video/beacons: this gate is about the
    /// ordered CTRL stream.
    private final class RoutingHostStandIn: NoiseHandshakeIO {
        let staticKeys = NoiseKeyPair.generate()
        let connectionId: ConnectionId
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var arq: ArqEndpoint<HostClock>
        var negotiator: CapabilityNegotiator
        var capabilitiesDeclared = false
        private var handshakeOutbox: [[UInt8]] = []

        /// The host's shell posture (--host-audio seeds it live).
        var posture: HostAudioRoutingMode = .hostAudible
        /// Scripted failure: a 0x18 is "attempted", the flip fails,
        /// and the 0x19 answer reports the OLD posture (HS-18's rule).
        var flipFails = false

        // Evidence.
        var agreed: Capabilities?
        var requestsReceived: [[UInt8]] = []
        var receivedReliableTypes: [UInt8] = []
        var statusesSent: [HostAudioRoutingMode] = []

        init(localCapabilities: Capabilities) {
            var rng = SplitMix64(seed: 0xC1_13)
            connectionId = ConnectionId.random(using: &rng)
            var config = ArqConfig()
            config.maxSegmentBodyByteCount = min(
                config.maxSegmentBodyByteCount,
                ReliableCtrlEndpoint.ctrlPlaintextBudget
                    - ArqBounds.segmentHeaderByteCount
            )
            arq = ArqEndpoint(channel: .ctrl, config: config)
            negotiator = CapabilityNegotiator(
                role: .host, local: localCapabilities)
        }

        // NoiseHandshakeIO — answered in-process.

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
            // HS-11's rule, load-bearing here: the host's declaration
            // is the FIRST reliable word at establishment — BEFORE any
            // client message can be consumed. Queuing it lazily would
            // let the agreement's 0x19 jump ahead of it on the ordered
            // stream, and the client would (rightly) drop that loud.
            capabilitiesDeclared = true
            try arq.send(
                message: try negotiator.start().encode(),
                now: HostTimestamp(microseconds: 0)
            )
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

        private func sealedCtrl(
            body: [UInt8], hostMicros: UInt64
        ) throws -> [UInt8] {
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
            return try envelope.encode(payload: payload)
        }

        /// One client datagram: unseal → the ARQ ingest → HS-18's
        /// dispatch. Feedback/echoes/IDRs are not this gate's business.
        func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            let (envelope, payload) = try Envelope.decode(bytes)
            guard envelope.channel == .ctrl else { return }
            let aad = bytes[bytes.startIndex..<payload.startIndex]
            let plaintext: [UInt8]
            do {
                plaintext = try transport!.unseal(
                    wirePayload: payload, aad: aad, envelope: envelope
                )
            } catch NoiseError.replayedSequence, NoiseError.staleSequence {
                return
            }
            switch plaintext.first {
            case CtrlMessageType.arqSegment, CtrlMessageType.arqAck:
                for event in arq.ingest(
                    payload: plaintext,
                    now: HostTimestamp(microseconds: nowMicros)
                ) {
                    if case .message(_, let message) = event {
                        receivedReliableTypes.append(message.first ?? 0)
                        try dispatchReliable(message, nowMicros: nowMicros)
                    }
                }
            default:
                break   // beacon echoes etc. — not this gate's business
            }
        }

        private func dispatchReliable(
            _ message: [UInt8], nowMicros: UInt64
        ) throws {
            let instant = HostTimestamp(microseconds: nowMicros)
            switch message.first {
            case CtrlMessageType.capabilityDeclaration:
                guard let declaration =
                    try? CapabilityDeclaration.decode(message)
                else { return XCTFail("malformed client declaration") }
                if case .agreed(let intersection) =
                    try negotiator.receive(declaration) {
                    agreed = intersection
                    // HS-18: the starting posture rides a 0x19 at
                    // capability agreement — negotiated sessions only.
                    if intersection.hostAudioRouting {
                        statusesSent.append(posture)
                        try arq.send(
                            message: AudioRoutingStatus(mode: posture).encode(),
                            now: instant)
                    }
                }
            case CtrlMessageType.audioRoutingRequest:
                requestsReceived.append(message)
                guard agreed?.hostAudioRouting == true else {
                    return   // the host's rule-3 drop, silent here
                }
                let request = try AudioRoutingRequest.decode(message)
                if !flipFails { posture = request.mode }
                // Applied (or failed — old posture) → one 0x19.
                statusesSent.append(posture)
                try arq.send(
                    message: AudioRoutingStatus(mode: posture).encode(),
                    now: instant)
            case CtrlMessageType.sessionTeardown:
                break
            default:
                break
            }
        }

        /// Hostile injection: a raw reliable message, bypassing the
        /// host's own rules (the unnegotiated-0x19 / role-confusion
        /// legs).
        func injectReliable(_ message: [UInt8], nowMicros: UInt64) throws {
            try arq.send(
                message: message,
                now: HostTimestamp(microseconds: nowMicros))
        }

        /// One host beat: first-word declaration + due ARQ output.
        func advance(nowMicros: UInt64) throws -> [[UInt8]] {
            guard transport != nil else { return [] }
            if !capabilitiesDeclared {
                capabilitiesDeclared = true
                try arq.send(
                    message: try negotiator.start().encode(),
                    now: HostTimestamp(microseconds: nowMicros)
                )
            }
            let (payloads, _) = arq.poll(
                now: HostTimestamp(microseconds: nowMicros))
            return try payloads.map {
                try sealedCtrl(body: $0, hostMicros: nowMicros)
            }
        }
    }

    // MARK: - The client harness (the LyteUdpSessionGateTests shape)

    /// The REAL production core minus the socket, on a virtual clock,
    /// piped directly to the stand-in (this gate needs determinism,
    /// not impairment — CL-8's gate owns the storm legs).
    private final class Harness: @unchecked Sendable {
        let host: RoutingHostStandIn
        let crypto: NoiseTransportCrypto
        let demux: ReceiveDemux
        var core: LyteUdpSessionCore!
        private var outbound: [[UInt8]] = []
        private var forwarded = 0
        let clock = LockedClock()

        var events: [LyteUdpSessionEvent] = []

        init(
            host: RoutingHostStandIn,
            coreConfig: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig()
        ) throws {
            self.host = host
            let crypto = try NoiseTransportCrypto(
                hostAddress: "10.0.0.249", hostPort: 41_121,
                hostStaticPublicKey: host.staticKeys.publicKey,
                staticKeys: NoiseKeyPair.generate(),
                attempts: 3, attemptTimeoutMilliseconds: 200)
            try crypto.performHandshake(io: host)
            self.crypto = crypto
            self.demux = ReceiveDemux(crypto: crypto)
            let clock = self.clock
            let sender = TransportSender(crypto: crypto, transmit: {
                [weak self] datagram in
                self?.outbound.append(datagram)
                return true
            })
            self.core = LyteUdpSessionCore(
                demux: demux,
                sender: sender,
                config: coreConfig,
                now: { ClientTimestamp(microseconds: clock.value) },
                videoSink: HeadlessVideoSink(),
                onEvent: { [weak self] event in
                    self?.events.append(event)
                })
        }

        func absorb(_ bytes: [UInt8], tMicros: UInt64) {
            let outcome = demux.ingest(
                datagram: bytes[...], arrivalMicroseconds: tMicros)
            if case .accepted = outcome {
                core.handleDatagram(outcome, arrivalMicroseconds: tMicros)
            }
        }

        /// Direct-pipe beats 2 ms apart until both ends quiesce (the
        /// AudioRoutingGateTests settle shape, roles swapped).
        func settle(t: inout UInt64) throws {
            var idle = 0
            while idle < 3 {
                t += 2_000
                clock.value = t
                let before = (forwarded, host.receivedReliableTypes.count,
                              events.count)
                core.tick(now: ClientTimestamp(microseconds: t))
                while forwarded < outbound.count {
                    try host.absorb(outbound[forwarded], nowMicros: t)
                    forwarded += 1
                }
                for datagram in try host.advance(nowMicros: t) {
                    absorb(datagram, tMicros: t)
                }
                core.tick(now: ClientTimestamp(microseconds: t))
                while forwarded < outbound.count {
                    try host.absorb(outbound[forwarded], nowMicros: t)
                    forwarded += 1
                }
                idle = (forwarded, host.receivedReliableTypes.count,
                        events.count) == before ? idle + 1 : 0
            }
        }

        var postureEvents: [HostAudioRoutingMode] {
            events.compactMap {
                if case .hostAudioRoutingStatus(let mode) = $0 { return mode }
                return nil
            }
        }
    }

    final class LockedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64 = 1_000
        var value: UInt64 {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    // MARK: Leg 3 — the negotiated flip, end to end

    func testGateNegotiatedFlipRoundTripAndFailedFlipReportsOldPosture() throws {
        let host = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        // The NEUTRAL posture, explicit since CL-18 flipped the
        // config default to hostMuted: this leg is about the flip
        // round-trip, so the session-start ask stays out of the way.
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = nil
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        // Mutual key-9 declaration survived intersection, both views.
        XCTAssertEqual(host.agreed?.hostAudioRouting, true,
                       "the host must see key 9 in the client's 0x0F")
        XCTAssertEqual(
            harness.core.agreedCapabilities?.hostAudioRouting, true)
        XCTAssertTrue(harness.core.hostAudioRoutingNegotiated)

        // The starting 0x19 (the host's default) is the confirmed
        // posture — no ask left (no desired posture configured).
        XCTAssertEqual(harness.postureEvents, [.hostAudible])
        XCTAssertEqual(harness.core.hostAudioRoutingPosture, .hostAudible)
        XCTAssertEqual(host.requestsReceived, [],
                       "no desired posture → no session-start 0x18")

        // The flip: ask hostMuted → the host consumes exactly
        // [0x18, 0x02] → answers 0x19 → posture + callback.
        try harness.core.requestHostAudioRouting(
            .hostMuted, now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(host.requestsReceived, [[0x18, 0x02]],
                       "the ask must ride the ordered stream byte-exact")
        XCTAssertEqual(harness.postureEvents, [.hostAudible, .hostMuted])
        XCTAssertEqual(harness.core.hostAudioRoutingPosture, .hostMuted)

        // The FAILED flip: the host attempts, fails, and re-reports
        // the OLD posture — the client renders truth (the UI toggle
        // snaps back), never the ask.
        host.flipFails = true
        try harness.core.requestHostAudioRouting(
            .hostAudible, now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(host.requestsReceived.count, 2)
        XCTAssertEqual(harness.postureEvents,
                       [.hostAudible, .hostMuted, .hostMuted],
                       "a failed flip answers with the old posture")
        XCTAssertEqual(harness.core.hostAudioRoutingPosture, .hostMuted)

        let counters = harness.core.snapshotCounters()
        XCTAssertEqual(counters.audioRoutingRequestsSent, 2)
        XCTAssertEqual(counters.audioRoutingStatusesReceived, 3)
        XCTAssertEqual(counters.audioRoutingDropsLoud, 0)
        XCTAssertEqual(counters.unknownReliableTypes, 0)
        XCTAssertEqual(counters.malformedReliableMessages, 0)

        print("CL-13 gate (in vivo): 0x18 → 0x19 → callback both ways; "
            + "failed flip reports old posture")
    }

    func testGateStreamOffNeedsKeyFourteenAndRoundTripsWhenAgreed() throws {
        // Leg A: a key-9-only host (today's build) — the routing
        // dialect works, but streamOff (key 14, mute-at-source) is
        // refused TYPED, before a byte leaves: 0x04 against a legacy
        // decoder would be a protocol break, so it never travels.
        let legacy = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = nil
        let h1 = try Harness(host: legacy, coreConfig: config)
        var t: UInt64 = 1_000
        h1.clock.value = t
        try h1.core.open(now: ClientTimestamp(microseconds: t))
        try h1.settle(t: &t)
        XCTAssertTrue(h1.core.hostAudioRoutingNegotiated)
        XCTAssertEqual(h1.core.agreedCapabilities?.audioStreamOff, false)
        XCTAssertThrowsError(try h1.core.requestHostAudioRouting(
            .streamOff, now: ClientTimestamp(microseconds: t))
        ) { error in
            XCTAssertEqual(
                error as? AudioRoutingAskError, .streamOffNotNegotiated)
        }
        try h1.settle(t: &t)
        XCTAssertEqual(legacy.requestsReceived, [],
                       "no [0x18 0x04] may ever reach a key-9-only host")

        // Leg B: a key-9+14 host — streamOff round-trips byte-exact
        // ([0x18 0x04] → 0x19) and the posture lands.
        let modern = RoutingHostStandIn(
            localCapabilities: .wireDefault
                .declaringHostAudioRouting().declaringAudioStreamOff())
        let h2 = try Harness(host: modern, coreConfig: config)
        var t2: UInt64 = 1_000
        h2.clock.value = t2
        try h2.core.open(now: ClientTimestamp(microseconds: t2))
        try h2.settle(t: &t2)
        XCTAssertEqual(h2.core.agreedCapabilities?.audioStreamOff, true)
        try h2.core.requestHostAudioRouting(
            .streamOff, now: ClientTimestamp(microseconds: t2))
        try h2.settle(t: &t2)
        XCTAssertEqual(modern.requestsReceived, [[0x18, 0x04]],
                       "streamOff must ride byte-exact as 0x04")
        XCTAssertEqual(h2.core.hostAudioRoutingPosture, .streamOff)

        print("key-14 gate: streamOff refused typed against a "
            + "key-9-only host; [0x18 0x04] round-trips against a "
            + "declaring one")
    }

    // MARK: Leg 4 — the session-start posture parameter

    func testGateSessionStartPostureAsksExactlyOnceWhenDiffering() throws {
        let host = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = .hostMuted
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        // The host's default (audible) differed from the desire
        // (muted): exactly ONE 0x18 left right after the starting
        // 0x19, the host applied it, and the confirmed posture is the
        // desire — the whole negotiation, no shell involvement.
        XCTAssertEqual(host.requestsReceived, [[0x18, 0x02]],
                       "exactly one session-start ask")
        XCTAssertEqual(harness.postureEvents, [.hostAudible, .hostMuted])
        XCTAssertEqual(harness.core.hostAudioRoutingPosture, .hostMuted)
        XCTAssertEqual(
            harness.core.snapshotCounters().audioRoutingRequestsSent, 1)

        // Later statuses never re-trigger the start ask (the host
        // flips back on its own — say its shell did): posture follows,
        // no new 0x18.
        host.posture = .hostAudible
        try host.injectReliable(
            AudioRoutingStatus(mode: .hostAudible).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.core.hostAudioRoutingPosture, .hostAudible)
        XCTAssertEqual(host.requestsReceived.count, 1,
                       "the start ask fires at most once per session")
    }

    func testGateSessionStartPostureStaysQuietWhenMatching() throws {
        let host = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        host.posture = .hostMuted   // --host-audio muted on the shell
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = .hostMuted
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        // Desire == the host's default: nothing to say.
        XCTAssertEqual(host.requestsReceived, [])
        XCTAssertEqual(harness.core.hostAudioRoutingPosture, .hostMuted)
        XCTAssertEqual(harness.postureEvents, [.hostMuted])
    }

    // MARK: Leg 5 — the rule-3 gate against the unnegotiated

    func testGateUnnegotiatedAskSuppressedAndHostileStatusDropsLoud() throws {
        // A v1 host: declares, but never key 9 (an older host build).
        let host = RoutingHostStandIn(localCapabilities: .wireDefault)
        var config = LyteUdpSessionCoreConfig()
        // Even a configured desire must stay quiet without the key.
        config.desiredHostAudioRouting = .hostMuted
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        // Intersection dropped key 9; the strip's button never exists.
        XCTAssertEqual(host.agreed?.hostAudioRouting, false)
        XCTAssertFalse(harness.core.hostAudioRoutingNegotiated)
        XCTAssertNil(harness.core.hostAudioRoutingPosture)
        XCTAssertEqual(harness.postureEvents, [])

        // The ask is refused BEFORE a byte leaves.
        XCTAssertThrowsError(try harness.core.requestHostAudioRouting(
            .hostMuted, now: ClientTimestamp(microseconds: t))
        ) { error in
            XCTAssertEqual(
                error as? AudioRoutingAskError, .notNegotiated)
        }
        try harness.settle(t: &t)
        XCTAssertEqual(host.requestsReceived, [])
        XCTAssertFalse(
            host.receivedReliableTypes
                .contains(CtrlMessageType.audioRoutingRequest),
            "no 0x18 may ever reach an unnegotiated host")

        // A hostile/buggy 0x19 from the no-key-9 host: dropped loud,
        // no posture, no event.
        try host.injectReliable(
            AudioRoutingStatus(mode: .hostMuted).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertNil(harness.core.hostAudioRoutingPosture)
        XCTAssertEqual(harness.postureEvents, [])
        XCTAssertEqual(
            harness.core.snapshotCounters().audioRoutingDropsLoud, 1)

        // Role confusion: a 0x18 arriving AT the client — same loud
        // drop (the host's mirror rule).
        try host.injectReliable(
            AudioRoutingRequest(mode: .hostMuted).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(
            harness.core.snapshotCounters().audioRoutingDropsLoud, 2)
        XCTAssertEqual(
            harness.core.snapshotCounters().audioRoutingRequestsSent, 0)

        print("CL-13 gate (rule 3): unnegotiated ask refused pre-wire, "
            + "hostile 0x19 and role-confused 0x18 dropped loud")
    }

    // MARK: Leg 6 — the per-host default plumbing

    func testPinnedHostPreferenceSurvivesDecodeRepairAndRefusesUnknown() throws {
        // A pre-CL-13 file (no startHostAudioMuted key) decodes
        // unchanged: the preference reads nil, meaning "host default".
        let keyHex = String(repeating: "ab", count: 32)
        let legacy = Data("""
        {"hosts":{"deadbeef":{"name":"pup","address":"10.0.0.249",\
        "port":41000,"staticPublicKeyHex":"\(keyHex)",\
        "pairedAt":"2026-07-21T09:00:00Z"}}}
        """.utf8)
        let store = try JSONDecoder().decode(PinnedHostStore.self, from: legacy)
        XCTAssertNil(store.hosts["deadbeef"]?.startHostAudioMuted)

        // Round trip through the real save/load path, preference set.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cl13-pinned-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var live = PinnedHostStore()
        let staticKey = (0..<32).map { UInt8($0) }
        live.pin(staticPublicKey: staticKey, name: "pup",
                 address: "10.0.0.249", port: 41_000,
                 pairedAt: "2026-07-22T15:00:00Z")
        let pkh = try XCTUnwrap(live.hosts.keys.first)
        XCTAssertTrue(live.setStartHostAudioMuted(
            publicKeyHash: pkh, muted: true))
        try live.save(to: url)
        let reloaded = PinnedHostStore.load(from: url)
        XCTAssertEqual(
            reloaded.host(publicKeyHash: pkh)?.startHostAudioMuted, true)

        // A re-pair refreshes dial hints WITHOUT resetting preferences.
        var repaired = reloaded
        repaired.pin(staticPublicKey: staticKey, name: "pup",
                     address: "10.0.0.77", port: 41_121,
                     pairedAt: "2026-07-23T09:00:00Z")
        XCTAssertEqual(repaired.hosts[pkh]?.address, "10.0.0.77")
        XCTAssertEqual(repaired.hosts[pkh]?.startHostAudioMuted, true,
                       "a re-pair is a trust event, not a settings reset")

        // The setter refuses hashes it has never pinned.
        XCTAssertFalse(repaired.setStartHostAudioMuted(
            publicKeyHash: "0000", muted: true))
    }

    // MARK: Leg 7 — CL-18: the flipped default posture

    func testGateFreshConfigStartsHostMutedByDefault() throws {
        // The flip itself, pinned at the source: a FRESH config —
        // nothing set anywhere — desires hostMuted.
        XCTAssertEqual(
            LyteUdpSessionCoreConfig().desiredHostAudioRouting, .hostMuted)

        // And in vivo: a new session against a key-9 host whose own
        // default is audible sends exactly one [0x18 0x02] — the
        // Sunshine/Moonlight posture with zero configuration. (The
        // no-key-9 case stays pinned by leg 5: the ask only ever
        // fires on the host's first 0x19, which such a host never
        // owes — unnegotiated hosts keep playing, unchanged.)
        let host = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        let harness = try Harness(host: host)   // the DEFAULT config
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        XCTAssertEqual(host.requestsReceived, [[0x18, 0x02]],
                       "an unconfigured session asks for hostMuted now")
        XCTAssertEqual(harness.postureEvents, [.hostAudible, .hostMuted])
        XCTAssertEqual(harness.core.hostAudioRoutingPosture, .hostMuted)
        XCTAssertEqual(
            harness.core.snapshotCounters().audioRoutingRequestsSent, 1)

        print("CL-18 gate (default flip): fresh config → one "
            + "[0x18 0x02] against an audible key-9 host")
    }

    func testGateStoredAudibleOptOutWorksBothDirections() throws {
        // The stored "start audible" opt-out (explicit false) against
        // an AUDIBLE host: postures already match — zero 0x18.
        let audibleHost = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = PinnedHost(
            name: "pup", address: "10.0.0.249", port: 41_000,
            staticPublicKeyHex: String(repeating: "ab", count: 32),
            pairedAt: "2026-07-27T09:00:00Z",
            startHostAudioMuted: false
        ).sessionStartHostAudioRouting
        XCTAssertEqual(config.desiredHostAudioRouting, .hostAudible)

        let quiet = try Harness(host: audibleHost, coreConfig: config)
        var t: UInt64 = 1_000
        quiet.clock.value = t
        try quiet.core.open(now: ClientTimestamp(microseconds: t))
        try quiet.settle(t: &t)
        XCTAssertEqual(audibleHost.requestsReceived, [],
                       "the audible opt-out suppresses the default ask")
        XCTAssertEqual(quiet.core.hostAudioRoutingPosture, .hostAudible)

        // The SAME opt-out against a host whose shell default is
        // muted (--host-audio muted): the preference still means
        // something in both directions — one [0x18 0x01] leaves.
        let mutedHost = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        mutedHost.posture = .hostMuted
        let asking = try Harness(host: mutedHost, coreConfig: config)
        var t2: UInt64 = 1_000
        asking.clock.value = t2
        try asking.core.open(now: ClientTimestamp(microseconds: t2))
        try asking.settle(t: &t2)
        XCTAssertEqual(mutedHost.requestsReceived, [[0x18, 0x01]],
                       "the opt-out ASKS for audible against a muted host")
        XCTAssertEqual(asking.core.hostAudioRoutingPosture, .hostAudible)

        print("CL-18 gate (opt-out): stored audible suppresses the "
            + "muted default and still flips a muted host")
    }

    func testPinnedHostPostureMappingAndMigration() throws {
        let keyHex = String(repeating: "ab", count: 32)
        func pinned(_ startMuted: Bool?) -> PinnedHost {
            PinnedHost(name: "pup", address: "10.0.0.249", port: 41_000,
                       staticPublicKeyHex: keyHex,
                       pairedAt: "2026-07-27T09:00:00Z",
                       startHostAudioMuted: startMuted)
        }
        // The tri-state, read the one sanctioned way: unset takes the
        // flipped default (muted), a stored true KEEPS its CL-13
        // meaning (muted), and only the explicit false — a value no
        // CL-13 setter ever wrote, so no existing file carries it —
        // is the new "start audible" opt-out. That construction IS
        // the migration: nothing stored changes meaning.
        XCTAssertEqual(pinned(nil).sessionStartHostAudioRouting, .hostMuted)
        XCTAssertEqual(pinned(true).sessionStartHostAudioRouting, .hostMuted)
        XCTAssertEqual(pinned(false).sessionStartHostAudioRouting, .hostAudible)

        // A pre-CL-13 file (no key at all) reads as the flipped
        // default through the same accessor.
        let legacy = Data("""
        {"hosts":{"deadbeef":{"name":"pup","address":"10.0.0.249",\
        "port":41000,"staticPublicKeyHex":"\(keyHex)",\
        "pairedAt":"2026-07-21T09:00:00Z"}}}
        """.utf8)
        let store = try JSONDecoder().decode(PinnedHostStore.self, from: legacy)
        XCTAssertEqual(
            store.hosts["deadbeef"]?.sessionStartHostAudioRouting, .hostMuted)

        // The setter now writes BOTH directions explicitly (the UI's
        // uncheck is an opt-out, not a reset), and the explicit false
        // survives the real save/load path.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cl18-pinned-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var live = PinnedHostStore()
        let staticKey = (0..<32).map { UInt8($0) }
        live.pin(staticPublicKey: staticKey, name: "pup",
                 address: "10.0.0.249", port: 41_000,
                 pairedAt: "2026-07-27T09:00:00Z")
        let pkh = try XCTUnwrap(live.hosts.keys.first)
        XCTAssertTrue(live.setStartHostAudioMuted(
            publicKeyHash: pkh, muted: false))
        try live.save(to: url)
        let reloaded = PinnedHostStore.load(from: url)
        XCTAssertEqual(
            reloaded.host(publicKeyHash: pkh)?.startHostAudioMuted, false)
        XCTAssertEqual(
            reloaded.host(publicKeyHash: pkh)?.sessionStartHostAudioRouting,
            .hostAudible)

        // And back to muted, explicitly.
        var flipped = reloaded
        XCTAssertTrue(flipped.setStartHostAudioMuted(
            publicKeyHash: pkh, muted: true))
        XCTAssertEqual(
            flipped.host(publicKeyHash: pkh)?.sessionStartHostAudioRouting,
            .hostMuted)

        print("CL-18 gate (migration): nil/true → muted, explicit "
            + "false → audible; stored prefs keep their meaning")
    }

    // MARK: Leg 8 — the tripwire's 0x25 (key 15), in vivo

    /// One sealed chan-1 datagram — the audio evidence the blackout
    /// detector tightens on (payload content is irrelevant to the
    /// evidence rule; the depacketizer's own counters absorb it).
    private func sealedAudio(
        host: RoutingHostStandIn, seq: UInt16, hostMicros: UInt64
    ) throws -> [UInt8] {
        let envelope = Envelope(
            channel: .audio,
            seq: ChannelSeq(rawValue: seq),
            frame: FrameNumber(rawValue: UInt32(seq)),
            timestamp: hostMicros,
            fec: 0
        )
        let header = try envelope.encode(payload: [])
        let payload = try host.transport!.seal(
            plaintext: [0x00][...], aad: header[...], envelope: envelope
        )
        return try envelope.encode(payload: payload)
    }

    func testGateAnnouncedQuietRelaxesDetectorAndAudioRetightens() throws {
        let host = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting()
                .declaringAudioQuietPosture())
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = nil
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t
        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        // Key 15 survived intersection, both views.
        XCTAssertEqual(host.agreed?.audioQuietPosture, true,
                       "the host must see key 15 in the client's 0x0F")
        XCTAssertEqual(
            harness.core.agreedCapabilities?.audioQuietPosture, true)

        // Audio evidence tightens the detector (the existing rule).
        XCTAssertFalse(harness.core.detectorTightened)
        harness.absorb(
            try sealedAudio(host: host, seq: 0, hostMicros: t), tMicros: t)
        XCTAssertTrue(harness.core.detectorTightened,
                      "chan-1 evidence must tighten to 350 ms")

        // The gate closes: 0x25 quiet relaxes the detector — gated
        // silence is contract, not a dark path.
        try host.injectReliable(
            AudioTrackState(state: .quiet).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertFalse(harness.core.detectorTightened,
                       "announced quiet must relax the blackout detector")
        XCTAssertEqual(
            harness.core.snapshotCounters().audioTrackStatesReceived, 1)

        // A still-quiet check-in repeats harmlessly (idempotent).
        try host.injectReliable(
            AudioTrackState(state: .quiet).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertFalse(harness.core.detectorTightened)
        XCTAssertEqual(
            harness.core.snapshotCounters().audioTrackStatesReceived, 2)

        // Wake: 0x25 active, then the pre-roll's first packet — the
        // audio evidence re-tightens through the existing rule.
        try host.injectReliable(
            AudioTrackState(state: .active).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(
            harness.core.snapshotCounters().audioTrackStatesReceived, 3)
        harness.absorb(
            try sealedAudio(host: host, seq: 1, hostMicros: t), tMicros: t)
        XCTAssertTrue(harness.core.detectorTightened,
                      "the wake burst's evidence must re-tighten")

        XCTAssertEqual(
            harness.core.snapshotCounters().malformedReliableMessages, 0)
        print("tripwire gate (in vivo): quiet relaxes to beacon-bounded, "
            + "check-ins idempotent, wake evidence re-tightens to 350 ms")
    }

    func testGateUnnegotiatedTrackStateDropsLoud() throws {
        // A key-9-only host (no key 15) injecting 0x25 anyway: the
        // client drops it before any contract switches — the rule-3
        // gate, tripwire verse.
        let host = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = nil
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t
        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(
            harness.core.agreedCapabilities?.audioQuietPosture, false)

        harness.absorb(
            try sealedAudio(host: host, seq: 0, hostMicros: t), tMicros: t)
        XCTAssertTrue(harness.core.detectorTightened)

        try host.injectReliable(
            AudioTrackState(state: .quiet).encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertTrue(harness.core.detectorTightened,
                      "an unnegotiated 0x25 must not relax anything")
        XCTAssertEqual(
            harness.core.snapshotCounters().audioTrackStatesReceived, 0)
        XCTAssertTrue(harness.events.contains {
            if case .protocolNote(let note) = $0 {
                return note.contains("0x25 without negotiated key 15")
            }
            return false
        }, "the drop must be loud")
    }

    // MARK: Leg 9 — the video posture's 0x26 (key 16), in vivo
    // (shares this file's scripted-host harness with the audio track;
    // the posture announcements are one family).

    func testGateVideoPostureAnnouncementsLandAndUnnegotiatedDrops() throws {
        let host = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting()
                .declaringVideoQuietPosture())
        var config = LyteUdpSessionCoreConfig()
        config.desiredHostAudioRouting = nil
        let harness = try Harness(host: host, coreConfig: config)
        var t: UInt64 = 1_000
        harness.clock.value = t
        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(
            harness.core.agreedCapabilities?.videoQuietPosture, true)
        XCTAssertNil(harness.core.announcedVideoPosture,
                     "no announcement yet — the always-on contract")

        // A ladder step lands: quiet at 30 s.
        try host.injectReliable(
            VideoPostureState(posture: .quiet, keepaliveSeconds: 30).encode(),
            nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(
            harness.core.snapshotCounters().videoPostureStatesReceived, 1)
        XCTAssertEqual(
            harness.core.announcedVideoPosture,
            VideoPostureState(posture: .quiet, keepaliveSeconds: 30))

        // The wake back to active.
        try host.injectReliable(
            VideoPostureState(posture: .active, keepaliveSeconds: 1).encode(),
            nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(
            harness.core.snapshotCounters().videoPostureStatesReceived, 2)
        XCTAssertEqual(harness.core.announcedVideoPosture?.posture, .active)
        XCTAssertEqual(
            harness.core.snapshotCounters().malformedReliableMessages, 0)

        // The rule-3 gate: a key-9-only host injecting 0x26 anyway.
        let legacyHost = RoutingHostStandIn(
            localCapabilities: .wireDefault.declaringHostAudioRouting())
        let legacy = try Harness(host: legacyHost, coreConfig: config)
        var t2: UInt64 = 1_000
        legacy.clock.value = t2
        try legacy.core.open(now: ClientTimestamp(microseconds: t2))
        try legacy.settle(t: &t2)
        try legacyHost.injectReliable(
            VideoPostureState(posture: .quiet, keepaliveSeconds: 30).encode(),
            nowMicros: t2)
        try legacy.settle(t: &t2)
        XCTAssertEqual(
            legacy.core.snapshotCounters().videoPostureStatesReceived, 0)
        XCTAssertNil(legacy.core.announcedVideoPosture)
        XCTAssertTrue(legacy.events.contains {
            if case .protocolNote(let note) = $0 {
                return note.contains("0x26 without negotiated key 16")
            }
            return false
        }, "the drop must be loud")
        print("video-posture gate (in vivo): steps land, wake lands, "
            + "unnegotiated drops loud")
    }
}
