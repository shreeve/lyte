import XCTest
import HostCore
import HostWire
import LyteWire
import LyteWireTestKit

// THE GATE (E3, the host half — the EyeCursorWatcher itself is
// Linux-only and drives the exact seam scripted here). Pinned
// behaviors:
//
//   • the 0x24 codec answers the SAME hand-built arrays Wire's
//     CursorCodecTests anchors (the cross-pin) and never traps on
//     hostile bytes;
//   • capability key 13 rides the W7 forward-compat spine exactly as
//     keys 9–12 did — the declaration is the local set's bytes plus
//     one canonical `0D F5` entry, surviving intersection only on
//     mutual byte-equal declaration;
//   • in vivo: a negotiated client receives each eye-reported shape
//     exactly once as a byte-exact 0x24 (the hidden state included),
//     an identical re-report dedupes, and a contract-breaking shape
//     (over-ceiling crop) is suppressed and counted, never sent and
//     never an error;
//   • the rule-3 gate holds: shapes are never volunteered to a client
//     that never declared key 13, and a 0x24 arriving AT the host
//     drops as role confusion.

final class CursorGateTests: XCTestCase {

    private static let rateBPS = 20_000_000

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_132,
        remoteAddress: "10.0.0.23", remotePort: 61_001
    )

    /// A visible test shape: 2×1, hotspot (1,0), two BGRA pixels.
    private static let arrow = CursorShape(
        width: 2, height: 1, hotspotX: 1, hotspotY: 0,
        pixels: [0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
    )

    // MARK: Leg 1 — the 0x24 bytes, pinned (the Wire cross-pin)

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
        // Hostile bytes reject, never trap.
        XCTAssertThrowsError(try CursorShape.decode([]))
        XCTAssertThrowsError(try CursorShape.decode([0x24, 0x01, 0x00]))
        XCTAssertThrowsError(try CursorShape.decode(
            [0x23, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        ))
        XCTAssertThrowsError(try CursorShape.decode(
            [0x24, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]
        ))
        print("E3 gate (codec): 0x24 pinned byte-exact against the "
            + "Wire arrays")
    }

    // MARK: Leg 2 — key 13 on the spine, mutual-only intersection

    func testCapabilityKeyThirteenRidesTheSpineAndIntersectsMutualOnly(
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
        print("E3 gate (spine): declaration = local bytes + `0D F5`, "
            + "mutual-only survival")
    }

    // MARK: The scripted client (the ClipboardGateTests harness)

    private struct CursorClient {
        var noise: NoiseSession
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var arq = ArqEndpoint<ClientClock>(channel: .ctrl)
        let staticKeys: NoiseKeyPair

        var received: [(group: ArqGroupId, bytes: [UInt8])] = []

        init(hostStaticPublicKey: [UInt8]) throws {
            staticKeys = NoiseKeyPair.generate()
            noise = try NoiseSession(
                role: .initiator,
                staticKeys: staticKeys,
                remoteStaticPublicKey: hostStaticPublicKey
            )
        }

        mutating func message1Datagram(
            clientMicros: UInt64
        ) throws -> [UInt8] {
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
            let (envelope, payload) = try Envelope.decode(bytes)
            if transport == nil {
                XCTAssertEqual(envelope.channel, .ctrl)
                XCTAssertEqual(
                    payload.first, CtrlMessageType.noiseHandshake2)
                _ = try noise.readMessage2(payload.dropFirst())
                transport = try noise.makeTransport()
                return
            }
            guard envelope.channel == .ctrl else { return }
            let aad = bytes[bytes.startIndex..<payload.startIndex]
            let plaintext: [UInt8]
            do {
                plaintext = try transport!.unseal(
                    wirePayload: payload, aad: aad, envelope: envelope
                )
            } catch NoiseError.replayedSequence, NoiseError.staleSequence {
                return // network duplicate; routine
            }
            switch plaintext.first {
            case CtrlMessageType.arqSegment, CtrlMessageType.arqAck:
                for event in arq.ingest(
                    payload: plaintext,
                    now: ClientTimestamp(microseconds: nowMicros)
                ) {
                    if case .message(let group, let bytes) = event {
                        received.append((group, bytes))
                    }
                }
            default:
                break // beacons etc. — not this gate's business
            }
        }

        mutating func pollOut(nowMicros: UInt64) throws -> [[UInt8]] {
            let (payloads, _) = arq.poll(
                now: ClientTimestamp(microseconds: nowMicros)
            )
            return try payloads.map {
                try ctrlDatagram(
                    body: $0, sealed: true, clientMicros: nowMicros)
            }
        }

        mutating func take(type: UInt8) -> [[UInt8]] {
            let hits = received.filter { $0.bytes.first == type }
                .map(\.bytes)
            received.removeAll { $0.bytes.first == type }
            return hits
        }
    }

    private final class DatagramBox {
        var datagrams: [VideoChannelDatagram] = []
    }

    /// Handshake + capability exchange, direct pipe. The host always
    /// declares key 13 (the direct eye in this gate); the client's
    /// declaration is the leg's variable.
    private func establish(
        clientCapabilities: Capabilities
    ) throws -> (session: Session, client: CursorClient, box: DatagramBox) {
        let hostStatic = NoiseKeyPair.generate()
        let box = DatagramBox()
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62,
                capabilities: .wireDefault.declaringCursorShape()
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x24),
            send: { box.datagrams.append($0) }
        )
        var client = try CursorClient(
            hostStaticPublicKey: hostStatic.publicKey)
        _ = session.receive(
            try client.message1Datagram(clientMicros: 500),
            from: Self.tupleA, now: 0, hostMicroseconds: 0
        )
        XCTAssertEqual(session.phase, .established)
        session.pump(now: 0)
        var negotiator = CapabilityNegotiator(
            role: .client, local: clientCapabilities
        )
        try client.arq.send(
            message: try XCTUnwrap(negotiator.start()).encode(),
            now: ClientTimestamp(microseconds: 1_000)
        )
        return (session, client, box)
    }

    /// Exchange passes 2 ms apart until both ends quiesce.
    private func settle(
        _ session: Session, _ client: inout CursorClient,
        _ box: DatagramBox, forwarded: inout Int, t: inout UInt64,
        onEvent: (SessionEvent) -> Void = { _ in }
    ) throws {
        var idle = 0
        while idle < 3 {
            t += 2_000
            let before = (forwarded, client.received.count)
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
                    try client.absorb(
                        box.datagrams[forwarded].bytes, nowMicros: t
                    )
                    forwarded += 1
                }
            }
            for event in events { onEvent(event) }
            idle = (forwarded, client.received.count) == before ? idle + 1 : 0
        }
    }

    // MARK: Leg 3 — the negotiated shape stream, dedupe, the ceiling

    func testGateNegotiatedShapeTravelsOnceDedupesAndHides() throws {
        let (session, clientValue, box) = try establish(
            clientCapabilities: .wireDefault.declaringCursorShape()
        )
        var client = clientValue
        var forwarded = 0
        var t: UInt64 = 1_000

        var agreed: Capabilities?
        try settle(session, &client, box, forwarded: &forwarded, t: &t) {
            if case .capabilitiesAgreed(let set) = $0 { agreed = set }
        }
        XCTAssertEqual(agreed?.cursorShape, true,
                       "mutual key-13 declaration must survive intersection")
        XCTAssertTrue(session.agreedCursorShape)
        _ = client.take(type: CtrlMessageType.capabilityDeclaration)

        // The eye reports a shape: one byte-exact 0x24 reaches the
        // client, exactly once.
        var events = session.noteCursorShapeChanged(
            Self.arrow, now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(events, [.cursorShapeSent(
            pixelByteCount: 8, hidden: false)])
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        XCTAssertEqual(
            client.take(type: CtrlMessageType.cursorShape),
            [try Self.arrow.encode()]
        )

        // The watcher's steady state: an identical re-report dedupes —
        // nothing new on the wire.
        events = session.noteCursorShapeChanged(
            Self.arrow, now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(events, [.cursorShapeSuppressed(.duplicate)])
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        XCTAssertEqual(client.take(type: CtrlMessageType.cursorShape), [])

        // The hidden state is a STATE — it travels.
        events = session.noteCursorShapeChanged(
            .hidden, now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(events, [.cursorShapeSent(
            pixelByteCount: 0, hidden: true)])
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        XCTAssertEqual(
            client.take(type: CtrlMessageType.cursorShape),
            [try CursorShape.hidden.encode()]
        )

        // A contract-breaking shape (a 256×256 opaque crop, past the
        // 65,536 B ceiling) suppresses and counts — the client keeps
        // the previous shape; nothing sends, nothing throws.
        let over = CursorShape(
            width: 256, height: 256, hotspotX: 0, hotspotY: 0,
            pixels: [UInt8](repeating: 0xFF, count: 256 * 256 * 4)
        )
        events = session.noteCursorShapeChanged(
            over, now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(events, [.cursorShapeSuppressed(.overBudget)])
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        XCTAssertEqual(client.take(type: CtrlMessageType.cursorShape), [])

        XCTAssertEqual(session.counters.cursorShapesSent, 2)
        XCTAssertEqual(session.counters.cursorShapesSuppressed, 2)
        print("E3 gate (in vivo): shape → byte-exact 0x24 once; "
            + "duplicate dedupes; hidden travels; over-ceiling "
            + "suppresses and counts")
    }

    // MARK: Leg 4 — the rule-3 gate against the unnegotiated

    func testGateUnnegotiatedStaysSilentAndArrivingShapeDropsLoud() throws {
        // A v1 client: declares, but never key 13.
        let (session, clientValue, box) = try establish(
            clientCapabilities: .wireDefault
        )
        var client = clientValue
        var forwarded = 0
        var t: UInt64 = 1_000

        var agreed: Capabilities?
        try settle(session, &client, box, forwarded: &forwarded, t: &t) {
            if case .capabilitiesAgreed(let set) = $0 { agreed = set }
        }
        XCTAssertEqual(agreed?.cursorShape, false)
        XCTAssertFalse(session.agreedCursorShape)
        _ = client.take(type: CtrlMessageType.capabilityDeclaration)

        // The eye reports — the session stays SILENT (no event, no
        // counter, nothing volunteered to a client without the key).
        let events = session.noteCursorShapeChanged(
            Self.arrow, now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(events, [])
        try settle(session, &client, box, forwarded: &forwarded, t: &t)
        XCTAssertEqual(client.take(type: CtrlMessageType.cursorShape), [])
        XCTAssertEqual(session.counters.cursorShapesSent, 0)
        XCTAssertEqual(session.counters.cursorShapesSuppressed, 0)

        // A 0x24 arriving AT the host is role confusion — dropped
        // loud, never interpreted.
        try client.arq.send(
            message: try Self.arrow.encode(),
            now: ClientTimestamp(microseconds: t)
        )
        var drops: [UInt8] = []
        try settle(session, &client, box, forwarded: &forwarded, t: &t) {
            if case .dropped(.unexpectedCtrlType(let type)) = $0 {
                drops.append(type)
            }
        }
        XCTAssertEqual(drops, [CtrlMessageType.cursorShape])

        print("E3 gate (rule 3): unnegotiated stays silent; "
            + "0x24-at-host drops loud")
    }
}
