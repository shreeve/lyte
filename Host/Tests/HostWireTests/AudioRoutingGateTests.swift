import XCTest
import HostCore
import HostSession
import HostWire
import HostWireTestKit
import LyteWire
import LyteWireTestKit

// THE GATE (HS-18, the in-tree half — the sink lifecycle itself is
// C-leaf/live-gate territory on the reference host). Pinned behaviors:
//
//   • the 0x18/0x19 codecs are byte-pinned against hand-built layouts
//     (mirror-then-promote: these bytes move to Wire/ with the client
//     slice, unchanged) and never trap on hostile bytes;
//   • capability key 9 rides the W7 forward-compat spine EXACTLY as
//     rule 3 designed it: the declaration is wireDefault's frozen
//     bytes plus one appended map entry (09 F5) — no existing byte
//     moves, no vector regenerates — and the capability survives
//     intersection only on mutual byte-equal declaration;
//   • in vivo: a negotiated client's 0x18 surfaces exactly once as
//     .audioRoutingRequested, the shell's noteAudioRoutingApplied
//     answers with a byte-exact 0x19, and a client that never
//     declared key 9 is refused loud (.audioRoutingNotNegotiated) —
//     the rule-3 gate holding at the session layer;
//   • the routing plumbing never touches the audio data path: the
//     framer/pacer cadence machinery is mode-blind by construction
//     (the C leaf owns the graph topology; R-G8 on the virtual sink
//     is the live gate's leg).

final class AudioRoutingGateTests: XCTestCase {

    private static let rateBPS = 20_000_000

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_121,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    // MARK: Leg 1 — the 0x18/0x19 bytes, pinned

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
        print("HS-18 gate (codec): 0x18/0x19 pinned byte-exact")
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

    // MARK: Leg 2 — key 9 on the forward-compat spine, zero frozen bytes

    func testCapabilityKeyRidesTheSpineWithoutMovingFrozenBytes() throws {
        let base = try Capabilities.wireDefault.encodeCbor()
        // wireDefault is an 8-entry map — the frozen v1 shape.
        XCTAssertEqual(base.first, 0xA8)

        // The declaration is EXACTLY the frozen bytes plus one appended
        // entry: map(9) head + trailing `09 F5` (key 9 sorts last in
        // RFC 8949 bytewise order among keys 1–9). Nothing between
        // moves — the "no frozen bytes" claim as data.
        var expected = base
        expected[0] = 0xA9
        expected += [0x09, 0xF5]
        let declared = Capabilities.wireDefault.declaringHostAudioRouting()
        XCTAssertEqual(try declared.encodeCbor(), expected)

        // Reads back as itself through the v1 decoder: key 9 lands in
        // unknownEntries (a v1 build "ignores and preserves"), and the
        // typed accessor sees it.
        let decoded = try Capabilities.decodeCbor(declared.encodeCbor())
        XCTAssertTrue(decoded.hostAudioRouting)
        XCTAssertEqual(decoded, declared)
        XCTAssertEqual(decoded.unknownEntries.count, 1)
        XCTAssertFalse(Capabilities.wireDefault.hostAudioRouting)

        // Idempotent declaration; encode stays canonical through the
        // full 0x0F message codec.
        XCTAssertEqual(declared.declaringHostAudioRouting(), declared)
        let message = try CapabilityDeclaration(capabilities: declared).encode()
        XCTAssertEqual(
            try CapabilityDeclaration.decode(message).capabilities, declared
        )
        print("""
            HS-18 gate (spine): declaration = frozen bytes + `09 F5`, \
            nothing else moved
            """)
    }

    func testIntersectionEnablesOnlyOnMutualDeclaration() throws {
        let declared = Capabilities.wireDefault.declaringHostAudioRouting()

        // Both declare → survives (both argument orders — the W-G8
        // algebra's commutativity applied to key 9).
        XCTAssertTrue(declared.intersecting(declared).hostAudioRouting)

        // One-sided → dropped, both orders.
        XCTAssertFalse(
            declared.intersecting(.wireDefault).hostAudioRouting
        )
        XCTAssertFalse(
            Capabilities.wireDefault.intersecting(declared).hostAudioRouting
        )

        // A peer declaring key 9 FALSE is not byte-equal to true:
        // absence and refusal are the same posture (the accessor's
        // documented rule) and the intersection drops the entry.
        var refusing = Capabilities.wireDefault
        refusing.unknownEntries.append(CborMapEntry(
            key: .unsigned(CapabilityKey.hostAudioRouting),
            value: .bool(false)
        ))
        XCTAssertFalse(refusing.hostAudioRouting)
        XCTAssertFalse(declared.intersecting(refusing).hostAudioRouting)
    }

    // MARK: The negotiated loopback client (the InputGateTests shape)

    /// Handshake + capability exchange, direct pipe. The host always
    /// declares key 9 (the audio leg exists); the client's declaration
    /// is the leg's variable.
    private func establish(
        clientCapabilities: Capabilities
    ) throws -> (host: HostSessionHarness, client: SealedCtrlPeer<ClientClock>) {
        let host = HostSessionHarness(
            config: SessionConfig(
                crypto: .noise(hostStatic: NoiseKeyPair.generate()),
                rateBitsPerSecond: Self.rateBPS,
                beaconIntervalNS: 1 << 62,
                capabilities: .wireDefault.declaringHostAudioRouting()
            ),
            tuple: Self.tupleA,
            rng: SplitMix64(seed: 0x1810)
        )
        let client = try host.connectClient(declaring: clientCapabilities)
        XCTAssertEqual(host.session.phase, .established)
        return (host, client)
    }

    // MARK: Leg 3 — the negotiated flip, end to end

    func testGateNegotiatedRequestSurfacesAndStatusAnswersByteExact() throws {
        let (host, clientValue) = try establish(
            clientCapabilities: .wireDefault.declaringHostAudioRouting()
        )
        var client = clientValue
        let session = host.session
        var t: UInt64 = 1_000

        var agreed: Capabilities?
        try host.settle(&client, t: &t) {
            if case .capabilitiesAgreed(let set) = $0 { agreed = set }
        }
        XCTAssertEqual(agreed?.hostAudioRouting, true,
                       "mutual key-9 declaration must survive intersection")
        XCTAssertTrue(session.agreedHostAudioRouting)
        _ = client.take(type: CtrlMessageType.capabilityDeclaration)

        // The client asks for hostMuted on the reliable stream.
        try client.arq.send(
            message: AudioRoutingRequest(mode: .hostMuted).encode(),
            now: ClientTimestamp(microseconds: t)
        )
        var requests: [HostAudioRoutingMode] = []
        try host.settle(&client, t: &t) {
            if case .audioRoutingRequested(let mode) = $0 {
                requests.append(mode)
            }
        }
        XCTAssertEqual(requests, [.hostMuted],
                       "exactly one request, exactly once")
        XCTAssertEqual(session.counters.audioRoutingRequestsReceived, 1)

        // The shell reports the applied posture; the client hears the
        // 0x19 byte-exact.
        let statusEvents = session.noteAudioRoutingApplied(
            .hostMuted, now: t * 1_000, hostMicroseconds: t
        )
        XCTAssertEqual(statusEvents, [.audioRoutingStatusSent(.hostMuted)])
        try host.settle(&client, t: &t)
        XCTAssertEqual(client.take(type: CtrlMessageType.audioRoutingStatus),
                       [[0x19, 0x02]])
        XCTAssertEqual(session.counters.audioRoutingStatusesSent, 1)

        // Flip back — the other direction rides the same rails.
        try client.arq.send(
            message: AudioRoutingRequest(mode: .hostAudible).encode(),
            now: ClientTimestamp(microseconds: t)
        )
        requests.removeAll()
        try host.settle(&client, t: &t) {
            if case .audioRoutingRequested(let mode) = $0 {
                requests.append(mode)
            }
        }
        XCTAssertEqual(requests, [.hostAudible])
        _ = session.noteAudioRoutingApplied(
            .hostAudible, now: t * 1_000, hostMicroseconds: t
        )
        try host.settle(&client, t: &t)
        XCTAssertEqual(client.take(type: CtrlMessageType.audioRoutingStatus),
                       [[0x19, 0x01]])

        print("""
            HS-18 gate (in vivo): negotiated 0x18 → event → 0x19 \
            byte-exact, both directions
            """)
    }

    // MARK: Leg 4 — the rule-3 gate holds against the unnegotiated

    func testGateUnnegotiatedRequestRefusedLoudAndStatusStaysSilent() throws {
        // A v1 client: declares, but never key 9.
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
        XCTAssertEqual(agreed?.hostAudioRouting, false)
        XCTAssertFalse(session.agreedHostAudioRouting)
        _ = client.take(type: CtrlMessageType.capabilityDeclaration)

        // It asks anyway (hostile or buggy): dropped loud, no event,
        // no counter movement.
        try client.arq.send(
            message: AudioRoutingRequest(mode: .hostMuted).encode(),
            now: ClientTimestamp(microseconds: t)
        )
        var requests = 0
        var refusals = 0
        try host.settle(&client, t: &t) {
            if case .audioRoutingRequested = $0 { requests += 1 }
            if case .dropped(.audioRoutingNotNegotiated) = $0 { refusals += 1 }
        }
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(refusals, 1)
        XCTAssertEqual(session.counters.audioRoutingRequestsReceived, 0)

        // The status side of the same gate: the session refuses to
        // narrate postures to a client that never asked for the key.
        XCTAssertEqual(
            session.noteAudioRoutingApplied(
                .hostMuted, now: t * 1_000, hostMicroseconds: t
            ), []
        )
        try host.settle(&client, t: &t)
        XCTAssertEqual(
            client.take(type: CtrlMessageType.audioRoutingStatus), []
        )
        XCTAssertEqual(session.counters.audioRoutingStatusesSent, 0)

        // A 0x19 arriving AT the host (role confusion) drops loud.
        try client.arq.send(
            message: AudioRoutingStatus(mode: .hostMuted).encode(),
            now: ClientTimestamp(microseconds: t)
        )
        var confused = 0
        try host.settle(&client, t: &t) {
            if case .dropped(.unexpectedCtrlType(0x19)) = $0 { confused += 1 }
        }
        XCTAssertEqual(confused, 1)

        print("""
            HS-18 gate (rule 3): unnegotiated 0x18 refused loud, \
            0x19 never volunteered, role confusion dropped
            """)
    }
}
