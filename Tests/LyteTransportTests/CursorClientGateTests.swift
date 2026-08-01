import XCTest
import Foundation
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE GATE (E3, the client half of cursor-shape sync). Pinned
// behaviors:
//
//   • the 0x24 codec answers the SAME hand-built arrays as Wire's
//     CursorCodecTests and Host/Tests' CursorGateTests (the
//     cross-pin) and never traps on hostile bytes;
//   • capability key 13 rides the W7 spine byte-equal to the host's
//     encoding, and the session core's DEFAULT config declares it
//     (dialect: this client can always wear a shape);
//   • in vivo, against a scripted key-13 host in virtual time: each
//     injected 0x24 surfaces exactly once as .hostCursorShapeChanged
//     (visible and hidden alike), byte-exact through real ARQ;
//   • the rule-3 gate holds: a 0x24 from a host that never declared
//     key 13 is dropped without an event — nothing can dress the
//     view outside the agreement;
//   • malformed 0x24 bytes count as malformed and never trap.

final class CursorClientGateTests: XCTestCase {

    /// The same hand-built shape the host gate pins.
    private static let arrow = CursorShape(
        width: 2, height: 1, hotspotX: 1, hotspotY: 0,
        pixels: [0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    )

    // MARK: Leg 1 — the 0x24 bytes, pinned (the cross-pin)

    func testCursorCodecPinsBytes() throws {
        XCTAssertEqual(
            try Self.arrow.encode(),
            [0x24, 0x02, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00,
             0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        )
        XCTAssertEqual(
            try CursorShape.decode(try Self.arrow.encode()), Self.arrow
        )
        XCTAssertEqual(
            try CursorShape.hidden.encode(),
            [0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        )
        XCTAssertThrowsError(try CursorShape.decode([]))
        XCTAssertThrowsError(try CursorShape.decode([0x24, 0x01]))
        XCTAssertThrowsError(try CursorShape.decode(
            [0x23, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        ))
        print("E3 gate (codec): 0x24 pinned byte-exact against the "
            + "Wire/host arrays")
    }

    // MARK: Leg 2 — key 13 on the spine; the core default declares

    func testCapabilityKeyThirteenOnTheSpineAndCoreDefaultDeclares(
    ) throws {
        let base = try Capabilities.wireDefault.encodeCbor()
        XCTAssertEqual(base.first, 0xA8)
        var expected = base
        expected[0] = 0xA9
        expected += [0x0D, 0xF5]
        let declared = Capabilities.wireDefault.declaringCursorShape()
        XCTAssertEqual(try declared.encodeCbor(), expected)

        XCTAssertTrue(declared.intersecting(declared).cursorShape)
        XCTAssertFalse(declared.intersecting(.wireDefault).cursorShape)
        XCTAssertFalse(
            Capabilities.wireDefault.intersecting(declared).cursorShape
        )

        // The session core's DEFAULT declaration carries key 13:
        // dialect — this client can always wear a shape, and only a
        // direct-eye host answers with its own key.
        let defaults = LyteUdpSessionCoreConfig()
        XCTAssertTrue(defaults.capabilities.cursorShape)
        print("E3 gate (spine): declaration = frozen bytes + `0D F5`; "
            + "core default declares")
    }

    // MARK: - The scripted host (the ClipboardHostStandIn shape)

    private final class CursorHostStandIn: NoiseHandshakeIO {
        let staticKeys = NoiseKeyPair.generate()
        let connectionId: ConnectionId
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var arq: ArqEndpoint<HostClock>
        var negotiator: CapabilityNegotiator
        private var handshakeOutbox: [[UInt8]] = []

        // Evidence.
        var agreed: Capabilities?
        var receivedReliableTypes: [UInt8] = []

        init(localCapabilities: Capabilities) {
            var rng = SplitMix64(seed: 0xE3_24)
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
            guard let (envelope, payload) =
                    try? Envelope.decode(datagram[...]),
                  envelope.channel == .ctrl,
                  payload.first == CtrlMessageType.noiseHandshake1
            else { return }
            var responder = try NoiseSession(
                role: .responder, staticKeys: staticKeys)
            _ = try responder.readMessage1(payload.dropFirst())
            let message2 = try responder.writeMessage2()
            transport = try responder.makeTransport()
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

        func receiveDatagram(
            timeoutMilliseconds: Int
        ) throws -> [UInt8]? {
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
                        if message.first
                            == CtrlMessageType.capabilityDeclaration,
                           let declaration =
                            try? CapabilityDeclaration.decode(message),
                           case .agreed(let intersection) =
                            try negotiator.receive(declaration) {
                            agreed = intersection
                        }
                    }
                }
            default:
                break
            }
        }

        /// A scripted host action: a raw reliable message onto the
        /// ordered stream (genuine shapes AND the hostile legs).
        func injectReliable(
            _ message: [UInt8], nowMicros: UInt64
        ) throws {
            try arq.send(
                message: message,
                now: HostTimestamp(microseconds: nowMicros))
        }

        func advance(nowMicros: UInt64) throws -> [[UInt8]] {
            guard transport != nil else { return [] }
            let (payloads, _) = arq.poll(
                now: HostTimestamp(microseconds: nowMicros))
            return try payloads.map {
                try sealedCtrl(body: $0, hostMicros: nowMicros)
            }
        }
    }

    // MARK: - The client harness (the ClipboardClientGateTests shape)

    private final class Harness: @unchecked Sendable {
        let host: CursorHostStandIn
        let crypto: NoiseTransportCrypto
        let demux: ReceiveDemux
        var core: LyteUdpSessionCore!
        private var outbound: [[UInt8]] = []
        private var forwarded = 0
        let clock = VirtualClock()

        var events: [LyteUdpSessionEvent] = []

        init(host: CursorHostStandIn) throws {
            self.host = host
            let crypto = try NoiseTransportCrypto(
                hostAddress: "10.0.0.249", hostPort: 41_132,
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
                config: LyteUdpSessionCoreConfig(),
                now: { ClientTimestamp(microseconds: clock.value) },
                onSample: { _, _ in },
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

        /// Direct-pipe beats 2 ms apart until both ends quiesce.
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

        var cursorEvents: [CursorShape] {
            events.compactMap {
                if case .hostCursorShapeChanged(let shape) = $0 {
                    return shape
                }
                return nil
            }
        }
    }

    private final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64 = 1_000
        var value: UInt64 {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    // MARK: Leg 3 — negotiated shapes surface exactly once

    func testGateNegotiatedShapesSurfaceByteExact() throws {
        let host = CursorHostStandIn(
            localCapabilities: .wireDefault.declaringCursorShape())
        let harness = try Harness(host: host)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)

        XCTAssertEqual(host.agreed?.cursorShape, true,
                       "the host must see key 13 in the client's 0x0F")

        // A visible shape surfaces exactly once, byte-exact through
        // real ARQ.
        try host.injectReliable(try Self.arrow.encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.cursorEvents, [Self.arrow])

        // The hidden state travels — it is a STATE, not an omission.
        try host.injectReliable(
            try CursorShape.hidden.encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.cursorEvents, [Self.arrow, .hidden])
        XCTAssertTrue(harness.cursorEvents.last?.isHidden == true)

        let counters = harness.core.snapshotCounters()
        XCTAssertEqual(counters.cursorShapesReceived, 2)
        XCTAssertEqual(counters.malformedReliableMessages, 0)
        print("E3 gate (in vivo): 0x24 → event, byte-exact, exactly "
            + "once; hidden travels")
    }

    // MARK: Leg 4 — the rule-3 gate and hostile bytes

    func testGateUnnegotiatedShapeDropsAndMalformedNeverTraps() throws {
        // A host that never declared key 13 (a portal-era host).
        let host = CursorHostStandIn(localCapabilities: .wireDefault)
        let harness = try Harness(host: host)
        var t: UInt64 = 1_000
        harness.clock.value = t

        try harness.core.open(now: ClientTimestamp(microseconds: t))
        try harness.settle(t: &t)
        XCTAssertEqual(host.agreed?.cursorShape, false)

        // An out-of-agreement 0x24: dropped, no event — nothing can
        // dress the view outside the agreement.
        try host.injectReliable(try Self.arrow.encode(), nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.cursorEvents, [])
        XCTAssertEqual(
            harness.core.snapshotCounters().cursorShapesReceived, 0)

        // Malformed 0x24 bytes (truncated header; a lying pixel
        // count): counted as malformed, never trapped, no event.
        try host.injectReliable([0x24, 0x01, 0x00], nowMicros: t)
        try host.injectReliable(
            [0x24, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
             0xFF],
            nowMicros: t)
        try harness.settle(t: &t)
        XCTAssertEqual(harness.cursorEvents, [])
        XCTAssertEqual(
            harness.core.snapshotCounters().malformedReliableMessages, 2)

        print("E3 gate (rule 3): unnegotiated 0x24 drops without an "
            + "event; malformed bytes count, never trap")
    }
}
