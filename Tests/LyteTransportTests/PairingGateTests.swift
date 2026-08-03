import XCTest
import Foundation
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE GATE (build plan CL-6, client pairing): the client's real pairing
// stack — NoiseTransportCrypto initiator with a PERSISTENT static,
// ReceiveDemux unseal, TransportSender seal, ReliableCtrlEndpoint, and
// PairingInitiatorService driving LyteWire's PairingPakeInitiator —
// completes the W6 CPace exchange against a host build-up running the
// REAL PairingPakeResponder, through the W-G4 fault model (SimNet loss,
// duplication, jitter-reorder): exactly-once pairing, both ends pinning
// the statics the Noise session authenticated, equal ISKs. Wrong PIN is
// learned client-side from the host's tag one message early, answered
// with the typed no-oracle reject, and leaves nothing pinned. (The root
// package cannot import HostWire; the host-side PairingServiceTests gate
// the mirror image with the real PairingResponderService.)

final class PairingGateTests: XCTestCase {

    // MARK: The host stand-in

    /// The host role, sans-IO: Noise responder, host-clock ARQ endpoint,
    /// conn-id tagging, and HS-9's message discipline — a fresh
    /// PairingPakeResponder per share A, share B out, confirm verified.
    private final class HostStandIn: NoiseHandshakeIO {
        let staticKeys = NoiseKeyPair.generate()
        let connectionId: ConnectionId
        let pin: [UInt8]
        var transport: NoiseTransport?
        var handshakeHash: [UInt8] = []
        var clientStatic: [UInt8] = []
        var ctrlSeq: UInt16 = 0
        var arq: ArqEndpoint<HostClock>
        private var handshakeOutbox: [[UInt8]] = []

        var responder: PairingPakeResponder?
        var result: PairingResult?
        var rejectsSent = 0
        var clientRejectSeen: PairingRejectReason?

        init(pin: [UInt8]) {
            self.pin = pin
            var rng = SplitMix64(seed: 0xC1_06)
            connectionId = ConnectionId.random(using: &rng)
            var config = ArqConfig()
            config.maxSegmentBodyByteCount = min(
                config.maxSegmentBodyByteCount,
                ReliableCtrlEndpoint.ctrlPlaintextBudget
                    - ArqBounds.segmentHeaderByteCount
            )
            arq = ArqEndpoint(channel: .ctrl, config: config)
        }

        // NoiseHandshakeIO — the pre-thread handshake window, answered
        // in-process. The responder learns the client static from
        // message 1 (what HS-9 binds the PAKE to).

        func sendToHost(_ datagram: [UInt8]) throws {
            guard let (envelope, payload) = try? Envelope.decode(datagram[...]),
                  envelope.channel == .ctrl,
                  payload.first == CtrlMessageType.noiseHandshake1
            else { return }
            var session = try NoiseSession(
                role: .responder, staticKeys: staticKeys)
            _ = try session.readMessage1(payload.dropFirst())
            let message2 = try session.writeMessage2()
            clientStatic = session.remoteStaticPublicKey ?? []
            handshakeHash = session.handshakeHash
            transport = try session.makeTransport()
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

        func sealedCtrl(body: [UInt8], hostMicros: UInt64) throws -> [UInt8] {
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

        func beaconDatagram(hostMicros: UInt64) throws -> [UInt8] {
            try sealedCtrl(
                body: ClockBeacon(
                    beaconSeq: 0,
                    hostSend: HostTimestamp(microseconds: hostMicros),
                    lastEcho: nil
                ).encode(),
                hostMicros: hostMicros)
        }

        /// One client datagram: unseal → one-byte peek → the ARQ, whose
        /// deliveries feed HS-9's message discipline.
        func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            let (envelope, payload) = try Envelope.decode(bytes)
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
                    guard case .message(_, let message) = event else {
                        continue
                    }
                    try pairingMessage(message, nowMicros: nowMicros)
                }
            case CtrlMessageType.beaconEcho:
                break   // clock hygiene, not this gate's subject
            default:
                XCTFail("unexpected client CTRL type \(plaintext.first ?? 0)")
            }
        }

        /// HS-9's shape: fresh responder per share A, tag math on
        /// confirm, silence after success.
        private func pairingMessage(
            _ message: [UInt8], nowMicros: UInt64
        ) throws {
            switch message.first {
            case CtrlMessageType.pairingShareA:
                var fresh = try PairingPakeResponder(
                    pin: pin,
                    clientStaticPublicKey: clientStatic,
                    hostStaticPublicKey: staticKeys.publicKey,
                    noiseHandshakeHash: handshakeHash)
                let shareB = try fresh.receiveShareA(
                    try PairingShareA.decode(message))
                responder = fresh
                try arq.send(
                    message: try shareB.encode(),
                    now: HostTimestamp(microseconds: nowMicros))
            case CtrlMessageType.pairingConfirm:
                guard var run = responder else {
                    XCTFail("confirm with no run open")
                    return
                }
                responder = nil
                do {
                    try run.receiveConfirm(try PairingConfirm.decode(message))
                    result = run.result
                } catch {
                    rejectsSent += 1
                    try arq.send(
                        message: PairingReject(
                            reason: .confirmationFailed
                        ).encode(),
                        now: HostTimestamp(microseconds: nowMicros))
                }
            case CtrlMessageType.pairingReject:
                clientRejectSeen =
                    try PairingReject.decode(message).reason
            default:
                XCTFail("unexpected reliable message type \(message.first ?? 0)")
            }
        }

        /// Due ARQ output, sealed (single-frame payloads here — pairing
        /// messages are far under the segment clamp).
        func pollOut(nowMicros: UInt64) throws -> [[UInt8]] {
            let (payloads, _) = arq.poll(
                now: HostTimestamp(microseconds: nowMicros))
            return try payloads.map {
                try sealedCtrl(body: $0, hostMicros: nowMicros)
            }
        }
    }

    // MARK: The client harness

    /// The REAL client stack: persistent-static Noise crypto, demux,
    /// sealed sender, reliable endpoint, and the pairing service wired
    /// exactly as LytePairingSession wires it. (@unchecked Sendable for
    /// the endpoint's @Sendable onEvent hook; the whole gate runs on
    /// one thread of virtual time.)
    private final class Harness: @unchecked Sendable {
        let host: HostStandIn
        let clientStatic = NoiseKeyPair.generate()
        let crypto: NoiseTransportCrypto
        let demux: ReceiveDemux
        let sender: TransportSender
        var reliable: ReliableCtrlEndpoint!
        var service: PairingInitiatorService!
        let outbound = LockedPile()
        var events: [PairingInitiatorService.Event] = []

        init(hostPin: [UInt8], clientPin: [UInt8]) throws {
            let host = HostStandIn(pin: hostPin)
            let crypto = try NoiseTransportCrypto(
                hostAddress: "10.0.0.249", hostPort: 41_007,
                hostStaticPublicKey: host.staticKeys.publicKey,
                staticKeys: clientStatic,
                attempts: 2, attemptTimeoutMilliseconds: 200)
            try crypto.performHandshake(io: host)
            self.host = host
            self.crypto = crypto
            self.demux = ReceiveDemux(crypto: crypto)
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

    final class LockedPile: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[UInt8]] = []
        func append(_ d: [UInt8]) { lock.lock(); stored.append(d); lock.unlock() }
        var all: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return stored }
        var count: Int { lock.lock(); defer { lock.unlock() }; return stored.count }
    }

    /// Drives the exchange over SimNet to quiescence (virtual time).
    private func converge(
        _ harness: Harness, net: inout SimNet,
        horizon: UInt64 = 30_000_000
    ) throws {
        var t: UInt64 = 1_000
        var forwarded = 0
        // The session-start beacon teaches the conn-id first (the real
        // host's control FIFO order), then share A opens the run.
        harness.absorb(
            try harness.host.beaconDatagram(hostMicros: 100), tMicros: t)
        try harness.reliable.send(
            harness.service.start(), now: ClientTimestamp(microseconds: t))
        while t < horizon {
            for delivery in net.deliveries(upTo: t) {
                if delivery.destination == 0 {
                    harness.absorb(delivery.bytes, tMicros: t)
                } else {
                    try harness.host.absorb(delivery.bytes, nowMicros: t)
                }
            }
            harness.reliable.tick(now: ClientTimestamp(microseconds: t))
            while forwarded < harness.outbound.count {
                net.send(from: 0, bytes: harness.outbound.all[forwarded], now: t)
                forwarded += 1
            }
            for datagram in try harness.host.pollOut(nowMicros: t) {
                net.send(from: 1, bytes: datagram, now: t)
            }
            if harness.service.isTerminal,
               harness.reliable.isQuiescent, harness.host.arq.isQuiescent,
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
        let hostResult = try XCTUnwrap(harness.host.result)
        XCTAssertEqual(
            hostResult.peerStaticPublicKeyToPin, harness.clientStatic.publicKey)
        XCTAssertEqual(harness.host.clientStatic, harness.clientStatic.publicKey)
        XCTAssertEqual(harness.host.rejectsSent, 0)

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
        XCTAssertNil(harness.host.result, "nothing must pin on either end")
        XCTAssertEqual(harness.host.clientRejectSeen, .confirmationFailed)
        XCTAssertEqual(harness.host.rejectsSent, 0,
                       "the host never had a confirm to refuse")
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
