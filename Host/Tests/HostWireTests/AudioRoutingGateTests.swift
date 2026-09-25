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

    // MARK: Leg 2 — key 9 on the forward-compat spine, zero frozen bytes

    // MARK: The negotiated loopback client

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
        XCTAssertEqual(session.agreedCapabilities?.hostAudioRouting, true)
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
        XCTAssertNotEqual(session.agreedCapabilities?.hostAudioRouting, true)
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
    }
}
