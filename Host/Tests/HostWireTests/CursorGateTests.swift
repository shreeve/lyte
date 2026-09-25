import XCTest
import HostCore
import HostSession
import HostWire
import HostWireTestKit
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
    }

    // MARK: The scripted client (the ClipboardGateTests harness)

    /// Handshake + capability exchange, direct pipe. The host always
    /// declares key 13 (the direct eye in this gate); the client's
    /// declaration is the leg's variable.
    private func establish(
        clientCapabilities: Capabilities
    ) throws -> (host: HostSessionHarness, client: SealedCtrlPeer<ClientClock>) {
        let host = HostSessionHarness(
            config: SessionConfig(
                crypto: .noise(hostStatic: NoiseKeyPair.generate()),
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62,
                capabilities: .wireDefault.declaringCursorShape()
            ),
            tuple: Self.tupleA,
            rng: SplitMix64(seed: 0x24)
        )
        let client = try host.connectClient(declaring: clientCapabilities)
        XCTAssertEqual(host.session.phase, .established)
        return (host, client)
    }

    // MARK: Leg 3 — the negotiated shape stream, dedupe, the ceiling

    func testGateNegotiatedShapeTravelsOnceDedupesAndHides() throws {
        let (host, clientValue) = try establish(
            clientCapabilities: .wireDefault.declaringCursorShape()
        )
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000

        var agreed: Capabilities?
        try host.settle(&client, t: &t) {
            if case .capabilitiesAgreed(let set) = $0 { agreed = set }
        }
        XCTAssertEqual(agreed?.cursorShape, true,
                       "mutual key-13 declaration must survive intersection")
        XCTAssertEqual(session.agreedCapabilities?.cursorShape, true)
        _ = client.take(type: CtrlMessageType.capabilityDeclaration)

        // The eye reports a shape: one byte-exact 0x24 reaches the
        // client, exactly once.
        var events = session.noteCursorShapeChanged(
            Self.arrow, now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(events, [.cursorShapeSent(
            pixelByteCount: 8, hidden: false)])
        try host.settle(&client, t: &t)
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
        try host.settle(&client, t: &t)
        XCTAssertEqual(client.take(type: CtrlMessageType.cursorShape), [])

        // The hidden state is a STATE — it travels.
        events = session.noteCursorShapeChanged(
            .hidden, now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(events, [.cursorShapeSent(
            pixelByteCount: 0, hidden: true)])
        try host.settle(&client, t: &t)
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
        try host.settle(&client, t: &t)
        XCTAssertEqual(client.take(type: CtrlMessageType.cursorShape), [])

        XCTAssertEqual(session.counters.cursorShapesSent, 2)
        XCTAssertEqual(session.counters.cursorShapesSuppressed, 2)
    }

    // MARK: Leg 4 — the rule-3 gate against the unnegotiated

    func testGateUnnegotiatedStaysSilentAndArrivingShapeDropsLoud() throws {
        // A v1 client: declares, but never key 13.
        let (host, clientValue) = try establish(
            clientCapabilities: .wireDefault
        )
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000

        var agreed: Capabilities?
        try host.settle(&client, t: &t) {
            if case .capabilitiesAgreed(let set) = $0 { agreed = set }
        }
        XCTAssertEqual(agreed?.cursorShape, false)
        XCTAssertNotEqual(session.agreedCapabilities?.cursorShape, true)
        _ = client.take(type: CtrlMessageType.capabilityDeclaration)

        // The eye reports — the session stays SILENT (no event, no
        // counter, nothing volunteered to a client without the key).
        let events = session.noteCursorShapeChanged(
            Self.arrow, now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(events, [])
        try host.settle(&client, t: &t)
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
        try host.settle(&client, t: &t) {
            if case .dropped(.unexpectedCtrlType(let type)) = $0 {
                drops.append(type)
            }
        }
        XCTAssertEqual(drops, [CtrlMessageType.cursorShape])
    }
}
