import XCTest
import Foundation
import HostWire
import LyteClientTestKit
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE GATE (build plan CL-6, client pairing): the client's real pairing
// stack — NoiseTransportCrypto initiator with a PERSISTENT static,
// ReceiveDemux unseal, TransportSender seal, ReliableCtrlEndpoint, and
// PairingInitiatorService driving LyteWire's PairingPakeInitiator —
// completes the W6 CPace exchange through the real HostWire Session and
// PairingResponderService, through the W-G4 fault model (SimNet loss,
// duplication, jitter-reorder): exactly-once pairing, both ends pinning
// the statics the Noise session authenticated, equal ISKs. Wrong PIN is
// learned client-side from the host's tag one message early, answered
// with the typed no-oracle reject, and leaves nothing pinned. This is the
// first cross-end composition gate: neither end reimplements the other's
// session carriage or pairing policy.

final class PairingGateTests: XCTestCase {

    // MARK: The client harness

    /// The REAL client stack: persistent-static Noise crypto, demux,
    /// sealed sender, reliable endpoint, and the pairing service wired
    /// exactly as LytePairingSession wires it. (@unchecked Sendable for
    /// the endpoint's @Sendable onEvent hook; the whole gate runs on
    /// one thread of virtual time.)
    private final class Harness: @unchecked Sendable {
        let host: SystemHostSession
        let hostService: PairingResponderService
        let clientStatic = NoiseKeyPair.generate()
        let crypto: NoiseTransportCrypto
        let demux: ReceiveDemux
        let sender: TransportSender
        var reliable: ReliableCtrlEndpoint!
        var service: PairingInitiatorService!
        let outbound = LockedBytePile()
        var events: [PairingInitiatorService.Event] = []
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
                attempts: 2, attemptTimeoutMilliseconds: 200)
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
            self.sender = TransportSender(crypto: crypto, transmit: {
                outbound.append($0)
                return true
            })
            self.service = try PairingInitiatorService(
                pin: clientPin,
                clientStaticPublicKey: crypto.clientStaticPublicKey,
                hostStaticPublicKey: host.staticKeys.publicKey,
                noiseHandshakeHash: crypto.handshakeHashSnapshot!)
            self.reliable = ReliableCtrlEndpoint(
                sender: sender,
                onEvent: { [weak self] event in
                    guard let self,
                          case .message(_, let bytes) = event,
                          let output = self.service.handleReliableCtrl(bytes)
                    else { return }
                    for reply in output.replies {
                        try? self.reliable.send(reply)
                    }
                    self.events.append(contentsOf: output.events)
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
            case .accepted(let envelope, let payload):
                _ = reliable.handleCtrlDatagram(
                    envelope: envelope, payload: payload,
                    now: ClientTimestamp(microseconds: tMicros))
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
        try harness.reliable.send(
            harness.service.start(), now: ClientTimestamp(microseconds: t))
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
            harness.reliable.tick(now: ClientTimestamp(microseconds: t))
            while forwarded < harness.outbound.count {
                net.send(from: 0, bytes: harness.outbound.all[forwarded], now: t)
                forwarded += 1
            }
            for datagram in try harness.pollHost(nowMicros: t) {
                net.send(from: 1, bytes: datagram, now: t)
            }
            if harness.service.isTerminal,
               harness.reliable.isQuiescent,
               harness.host.session.arqIsQuiescent,
               net.nextArrivalTime == nil {
                return
            }
            var next = t + 5_000
            if let arrival = net.nextArrivalTime {
                next = min(next, max(arrival, t + 1))
            }
            if let deadline = harness.reliable.nextDeadline {
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
        XCTAssertEqual(harness.events, [
            .paired(hostStaticPublicKey: harness.host.staticKeys.publicKey),
        ])
        XCTAssertEqual(
            harness.service.pairedHostStaticPublicKey,
            harness.host.staticKeys.publicKey)

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
        XCTAssertEqual(harness.events, [.pinMismatch])
        XCTAssertNil(harness.service.pairedHostStaticPublicKey)
        XCTAssertNil(
            harness.hostService.pairedClientStaticPublicKey,
            "nothing must pin on either end")
        XCTAssertEqual(harness.hostEvents, [
            .attemptOpened(attempt: 1, of: 3),
            .clientAborted(.confirmationFailed),
        ], "the host saw the client's typed abort, never a confirm")
    }

    // MARK: Host reject and machine discipline

    func testHostRejectSurfacesAndKillsTheRun() throws {
        let service = try PairingInitiatorService(
            pin: Array("111111".utf8),
            clientStaticPublicKey: NoiseKeyPair.generate().publicKey,
            hostStaticPublicKey: NoiseKeyPair.generate().publicKey,
            noiseHandshakeHash: [UInt8](repeating: 7, count: 32))
        _ = try service.start()
        let output = try XCTUnwrap(service.handleReliableCtrl(
            PairingReject(reason: .confirmationFailed).encode()))
        XCTAssertEqual(output.events, [.hostRejected(.confirmationFailed)])
        XCTAssertTrue(output.replies.isEmpty)
        XCTAssertTrue(service.isTerminal)

        // Dead machine: a late share B draws silence, not state.
        let late = try XCTUnwrap(service.handleReliableCtrl(
            try PairingShareB(
                share: [UInt8](repeating: 1, count: 32),
                confirmationTag: [UInt8](repeating: 2, count: 64)
            ).encode()))
        XCTAssertTrue(late.events.isEmpty)
        XCTAssertTrue(late.replies.isEmpty)
        XCTAssertNil(service.pairedHostStaticPublicKey)
    }

    func testForeignAndHostileBytesNeverThrow() throws {
        let service = try PairingInitiatorService(
            pin: Array("222222".utf8),
            clientStaticPublicKey: NoiseKeyPair.generate().publicKey,
            hostStaticPublicKey: NoiseKeyPair.generate().publicKey,
            noiseHandshakeHash: [UInt8](repeating: 9, count: 32))
        _ = try service.start()

        // Non-pairing types are not ours: nil, untouched.
        XCTAssertNil(service.handleReliableCtrl([0x7F, 1, 2, 3]))
        XCTAssertNil(service.handleReliableCtrl([]))

        // Client-role messages arriving at the client: hostile/confused.
        XCTAssertEqual(
            service.handleReliableCtrl(
                try PairingShareA(
                    share: [UInt8](repeating: 3, count: 32)).encode()
            )?.events,
            [.malformed])

        // A truncated share B: malformed, run still alive.
        XCTAssertEqual(
            service.handleReliableCtrl(
                [CtrlMessageType.pairingShareB, 0x01, 0x02])?.events,
            [.malformed])
        XCTAssertFalse(service.isTerminal)

        // start() is once-only.
        XCTAssertThrowsError(try service.start())
    }

    // MARK: The pinned-host keystore

    func testPinnedHostStoreRoundTripAndLookups() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cl6-pinned-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let key = NoiseKeyPair.generate().publicKey
        var store = PinnedHostStore.load(from: url)
        XCTAssertTrue(store.hosts.isEmpty)
        XCTAssertTrue(store.pin(
            staticPublicKey: key, name: "pup", address: "10.0.0.249",
            port: 41_007, pairedAt: "2026-07-22T08:00:00Z"))
        try store.save(to: url)

        var loaded = PinnedHostStore.load(from: url)
        XCTAssertEqual(loaded, store)

        // Recognition is the TXT pkh — the LyteDiscovery hash, exactly.
        let pkh = LyteDiscovery.publicKeyHash(ofStaticPublicKey: key)
        let byHash = try XCTUnwrap(loaded.host(publicKeyHash: pkh))
        XCTAssertEqual(byHash.staticPublicKey, key)
        XCTAssertEqual(byHash.publicKeyHash, pkh)
        var malformed = byHash
        malformed.staticPublicKeyHex = String(repeating: "ab", count: 31) + "  "
        XCTAssertNil(malformed.staticPublicKey,
                     "stored keys stay exact-width, not CLI-tolerant")
        let advertisement = DiscoveredLyteHost(
            name: "pup", address: "10.0.0.249", port: 41_007,
            wireVersion: WireVersion.major, publicKeyHash: pkh)
        XCTAssertTrue(advertisement.matches(pinnedStaticPublicKey: key))

        // Manual-dial lookups, by address and by name, case-insensitive.
        XCTAssertEqual(loaded.host(address: "10.0.0.249")?.name, "pup")
        XCTAssertEqual(loaded.host(address: "PUP")?.name, "pup")
        XCTAssertNil(loaded.host(address: "10.0.0.1"))

        // Re-pin the same key: refreshed hints, not a new entry.
        XCTAssertFalse(loaded.pin(
            staticPublicKey: key, name: "pup", address: "10.0.0.250",
            port: 41_008, pairedAt: "2026-07-23T08:00:00Z"))
        XCTAssertEqual(loaded.hosts.count, 1)
        XCTAssertEqual(loaded.host(publicKeyHash: pkh)?.address, "10.0.0.250")

        // Unpair: the entry is gone; unknown hashes are a nil no-op.
        XCTAssertNotNil(loaded.unpin(publicKeyHash: pkh))
        XCTAssertNil(loaded.unpin(publicKeyHash: pkh))
        XCTAssertTrue(loaded.hosts.isEmpty)
    }
}
