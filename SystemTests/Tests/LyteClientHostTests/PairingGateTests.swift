import XCTest
import Foundation
import HostWire
import LyteClientTestKit
import LyteTransport
import LyteWire
import LyteWireTestKit

// The cross-role pairing gate: the client's production pairing
// composition (LytePairingFlow — ReliableCtrlEndpoint, the sealed sender
// and PairingInitiatorService over a persistent-static Noise session) and
// the real HostWire Session with PairingResponderService complete the
// CPace exchange through the fault model (SimNet loss, duplication,
// jitter-reorder): exactly-once pairing, both ends pinning the statics the
// Noise session authenticated. A wrong PIN is learned client-side from the
// host's tag one message early, answered with the typed no-oracle reject,
// and leaves nothing pinned.

final class PairingGateTests: XCTestCase {

    // MARK: The harness

    /// The client's pairing flow over a demux and a captured transmit,
    /// in virtual time against the real host session.
    private final class Harness: @unchecked Sendable {
        let host: SystemHostSession
        let hostService: PairingResponderService
        let clientStatic = NoiseKeyPair.generate()
        let crypto: NoiseTransportCrypto
        let demux: ReceiveDemux
        let flow: LytePairingFlow
        let outbound = LockedBytePile()
        var hostEvents: [PairingResponderService.Event] = []

        init(hostPin: [UInt8], clientPin: [UInt8]) throws {
            let host = SystemHostSession()
            let hostService = PairingResponderService(
                pin: hostPin,
                hostStaticPublicKey: host.staticKeys.publicKey
            )
            let crypto = try NoiseTransportCrypto(
                hostAddress: "10.0.0.249", hostPort: 41_007,
                hostStaticPublicKey: host.staticKeys.publicKey,
                staticKeys: clientStatic,
                retry: .init(attempts: 2, intervalMicroseconds: 200_000))
            try crypto.performHandshake(io: host)
            self.host = host
            self.hostService = hostService
            self.crypto = crypto
            self.demux = ReceiveDemux(crypto: crypto)
            guard let remote = host.events.compactMap({ event -> [UInt8]? in
                guard case .handshakeCompleted(let key) = event else {
                    return nil
                }
                return key
            }).last,
            let handshakeHash = host.session.handshakeHash else {
                throw NSError(
                    domain: "PairingGateTests.realHostHandshake",
                    code: 1
                )
            }
            hostService.sessionEstablished(
                clientStaticPublicKey: remote,
                noiseHandshakeHash: handshakeHash
            )
            let outbound = self.outbound
            self.flow = try LytePairingFlow(
                crypto: crypto,
                hostStaticPublicKey: host.staticKeys.publicKey,
                pin: clientPin,
                transmit: {
                    outbound.append($0)
                    return true
                })
        }

        func handleHost(
            _ sessionEvents: [SessionEvent], nowMicros: UInt64
        ) throws {
            for event in sessionEvents {
                guard case .reliableCtrl(_, let message) = event else {
                    continue
                }
                guard let output = hostService.handleReliableCtrl(
                    message, now: nowMicros * 1_000
                ) else {
                    XCTFail(
                        "unexpected reliable message type "
                            + "\(message.first ?? 0)"
                    )
                    continue
                }
                for reply in output.replies {
                    try host.session.sendReliable(
                        reply,
                        now: nowMicros * 1_000,
                        hostMicroseconds: nowMicros
                    )
                }
                hostEvents.append(contentsOf: output.events)
            }
        }

        func pollHost(nowMicros: UInt64) throws -> [[UInt8]] {
            try handleHost(
                host.advance(to: nowMicros),
                nowMicros: nowMicros
            )
            return host.takeReadyControlDatagrams()
        }

        func absorb(_ bytes: [UInt8], tMicros: UInt64) {
            let outcome = demux.ingest(
                datagram: bytes[...], arrivalMicroseconds: tMicros)
            switch outcome {
            case .accepted:
                flow.handle(outcome, now: ClientTimestamp(microseconds: tMicros))
            case .unsealFailed:
                break   // byte-identical duplicate: replay window
            default:
                XCTFail("host datagram refused: \(outcome)")
            }
        }
    }

    /// Drives the exchange over SimNet to quiescence (virtual time).
    private func converge(
        _ harness: Harness, net: inout SimNet,
        horizon: UInt64 = 30_000_000
    ) throws {
        var t: UInt64 = 1_000
        var forwarded = 0
        // The real Session's startup flight teaches the conn-id first;
        // then share A opens the pairing run on the same ARQ lane.
        for datagram in try harness.pollHost(nowMicros: t) {
            harness.absorb(datagram, tMicros: t)
        }
        try harness.flow.start(now: ClientTimestamp(microseconds: t))
        while t < horizon {
            for delivery in net.deliveries(upTo: t) {
                if delivery.destination == 0 {
                    harness.absorb(delivery.bytes, tMicros: t)
                } else {
                    try harness.handleHost(
                        harness.host.absorb(
                            delivery.bytes, clientMicros: t
                        ),
                        nowMicros: t
                    )
                }
            }
            harness.flow.tick(now: ClientTimestamp(microseconds: t))
            while forwarded < harness.outbound.count {
                net.send(from: 0, bytes: harness.outbound.all[forwarded], now: t)
                forwarded += 1
            }
            for datagram in try harness.pollHost(nowMicros: t) {
                net.send(from: 1, bytes: datagram, now: t)
            }
            if harness.flow.settledOutcome != nil,
               harness.host.session.arqIsQuiescent,
               net.nextArrivalTime == nil {
                return
            }
            var next = t + 5_000
            if let arrival = net.nextArrivalTime {
                next = min(next, max(arrival, t + 1))
            }
            if let deadline = harness.flow.nextDeadline {
                next = min(next, max(deadline.microseconds, t + 1))
            }
            t = next
        }
        XCTFail("pairing did not converge within \(horizon) virtual µs")
    }

    // MARK: The gate — correct PIN through the W-G4 storm

    func testGatePairingCompletesThroughStorm() throws {
        let pin = Array("428519".utf8)
        let harness = try Harness(hostPin: pin, clientPin: pin)
        var net = SimNet(
            config: SimNetConfig(
                lossRate: 0.05,
                duplicateRate: 0.02,
                baseDelayMicroseconds: 3_000,
                jitterMicroseconds: 4_000
            ),
            seed: 0xC1_60_07
        )
        try converge(harness, net: &net)

        // Client verdict: paired, exactly one event, the host static
        // this session dialed is the key to pin.
        XCTAssertEqual(harness.flow.events, [
            .paired(hostStaticPublicKey: harness.host.staticKeys.publicKey),
        ])
        XCTAssertEqual(
            harness.flow.settledOutcome,
            .paired(hostStaticPublicKey: harness.host.staticKeys.publicKey))

        // Host verdict: confirm verified, and it pins the SAME client
        // static the Noise session authenticated — the promotion rule.
        XCTAssertEqual(
            harness.hostService.pairedClientStaticPublicKey,
            harness.clientStatic.publicKey)
        XCTAssertEqual(harness.host.session.phase, .established)
        XCTAssertEqual(
            harness.host.session.handshakeHash,
            harness.crypto.handshakeHashSnapshot
        )
        XCTAssertEqual(harness.hostEvents, [
            .attemptOpened(attempt: 1, of: 3),
            .paired(clientStaticPublicKey: harness.clientStatic.publicKey),
        ])

        // The storm was real, and the reliable carriage healed it.
        XCTAssertGreaterThan(net.lostCount + net.duplicatedCount, 0,
                             "the fault model must have fired")
    }

    // MARK: Wrong PIN — loud, oracle-free, nothing pinned

    func testWrongPinAbortsClientSideWithTypedReject() throws {
        let harness = try Harness(
            hostPin: Array("428519".utf8),
            clientPin: Array("428510".utf8))
        var net = SimNet(config: SimNetConfig(), seed: 1)
        try converge(harness, net: &net)

        // The client learned the mismatch from Tb — one message early,
        // no confirm ever sent, the typed reject went back instead.
        XCTAssertEqual(harness.flow.events, [.pinMismatch])
        XCTAssertEqual(harness.flow.settledOutcome, .pinMismatch)
        XCTAssertNil(harness.flow.pairedHostStaticPublicKey)
        XCTAssertNil(
            harness.hostService.pairedClientStaticPublicKey,
            "nothing must pin on either end")
        XCTAssertEqual(harness.hostEvents, [
            .attemptOpened(attempt: 1, of: 3),
            .clientAborted(.confirmationFailed),
        ], "the host saw the client's typed abort, never a confirm")
    }
}
