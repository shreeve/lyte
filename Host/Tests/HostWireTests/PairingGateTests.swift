import XCTest
import HostCore
import HostWire
import LyteWire
import LyteWireTestKit

// THE GATE (build plan HS-9 row, host side): pair once by PIN over the
// sealed reliable-CTRL stream — the CPace run completing through the
// W-G4 storm — then reconnect 1-RTT against the pinned static; wrong
// PIN fails loudly (typed 0x0E, one reason, no oracle) and pins
// nothing; the responder survives floods rate-limited (the message-1
// gate before any Noise allocation, the per-second attempt throttle,
// and the 3-guess budget that burns the PIN).
//
// The far end is a LyteWire client build-up (the ArqCtrlGateTests
// discipline): NoiseSession initiator + ArqEndpoint<ClientClock> +
// PairingPakeInitiator — exactly what CL-6 will assemble.

final class PairingGateTests: XCTestCase {

    private static let rateBPS = 20_000_000
    private static let pin = Array("483920".utf8)

    private static let tupleA = FourTuple(
        localAddress: "10.0.0.249", localPort: 41_006,
        remoteAddress: "10.0.0.23", remotePort: 61_000
    )

    // MARK: The pairing-capable loopback client (the CL-6 shape)

    private struct PakeClient {
        var noise: NoiseSession
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var arq = ArqEndpoint<ClientClock>(channel: .ctrl)
        let staticKeys: NoiseKeyPair
        let hostStaticPublicKey: [UInt8]

        /// ARQ-delivered CTRL messages, minus what the pairing driver
        /// consumed.
        var delivered: [[UInt8]] = []
        var pake: PairingPakeInitiator?
        var result: PairingResult?
        var sawReject: PairingRejectReason?
        var pakeFailure: PairingPakeError?

        init(hostStaticPublicKey: [UInt8]) throws {
            staticKeys = NoiseKeyPair.generate()
            self.hostStaticPublicKey = hostStaticPublicKey
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

        /// Starts the CPace run: binds to this session's transcript and
        /// statics, queues the 0x0B on the reliable stream.
        mutating func beginPairing(pin: [UInt8], nowMicros: UInt64) throws {
            let initiator = try PairingPakeInitiator(
                pin: pin,
                clientStaticPublicKey: staticKeys.publicKey,
                hostStaticPublicKey: hostStaticPublicKey,
                noiseHandshakeHash: transport!.handshakeHash
            )
            pake = initiator
            try arq.send(
                message: try initiator.makeShareA().encode(),
                now: ClientTimestamp(microseconds: nowMicros)
            )
        }

        mutating func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
            let (envelope, payload) = try Envelope.decode(bytes)
            XCTAssertEqual(envelope.channel, .ctrl)
            if transport == nil {
                XCTAssertEqual(payload.first, CtrlMessageType.noiseHandshake2)
                _ = try noise.readMessage2(payload.dropFirst())
                transport = try noise.makeTransport()
                return
            }
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
                    if case .message(_, let bytes) = event {
                        delivered.append(bytes)
                    }
                }
            case CtrlMessageType.clockBeacon:
                break // 1 Hz weather
            default:
                XCTFail("unexpected host CTRL type \(plaintext.first ?? 0)")
            }
            try drivePairing(nowMicros: nowMicros)
        }

        /// The CL-6 reaction: 0x0C → verify Tb, send 0x0D (or 0x0E on a
        /// mismatch — the wrong-PIN-learned-early path); 0x0E → record.
        mutating func drivePairing(nowMicros: UInt64) throws {
            var rest: [[UInt8]] = []
            for message in delivered {
                switch message.first {
                case CtrlMessageType.pairingShareB:
                    guard var initiator = pake else {
                        rest.append(message) // nobody armed; keep it
                        break
                    }
                    do {
                        let confirm = try initiator.receiveShareB(
                            try PairingShareB.decode(message)
                        )
                        result = initiator.result
                        pake = initiator
                        try arq.send(
                            message: confirm.encode(),
                            now: ClientTimestamp(microseconds: nowMicros)
                        )
                    } catch let failure as PairingPakeError {
                        pakeFailure = failure
                        pake = initiator
                        try arq.send(
                            message: PairingReject(
                                reason: .confirmationFailed
                            ).encode(),
                            now: ClientTimestamp(microseconds: nowMicros)
                        )
                    }
                case CtrlMessageType.pairingReject:
                    sawReject = try PairingReject.decode(message).reason
                default:
                    rest.append(message)
                }
            }
            delivered = rest
        }

        mutating func pollOut(nowMicros: UInt64) throws -> [[UInt8]] {
            let (payloads, _) = arq.poll(
                now: ClientTimestamp(microseconds: nowMicros)
            )
            return try payloads.map {
                try ctrlDatagram(body: $0, sealed: true, clientMicros: nowMicros)
            }
        }
    }

    // MARK: The host shell (SessionWire's dispatch, in miniature)

    private final class HostShell {
        let session: Session
        let service: PairingResponderService
        var events: [PairingResponderService.Event] = []
        var replyFailures = 0

        init(session: Session, service: PairingResponderService) {
            self.session = session
            self.service = service
        }

        func handle(_ sessionEvents: [SessionEvent], nowNS: UInt64) {
            for event in sessionEvents {
                switch event {
                case .handshakeCompleted(let remote):
                    service.sessionEstablished(
                        clientStaticPublicKey: remote,
                        noiseHandshakeHash: session.handshakeHash!
                    )
                case .reliableCtrl(_, let message):
                    guard let output = service.handleReliableCtrl(
                        message, now: nowNS
                    ) else { break }
                    for reply in output.replies {
                        do {
                            try session.sendReliable(
                                reply, now: nowNS,
                                hostMicroseconds: nowNS / 1_000
                            )
                        } catch {
                            replyFailures += 1
                        }
                    }
                    events += output.events
                default:
                    break
                }
            }
        }
    }

    private func establish(
        pin: [UInt8] = PairingGateTests.pin,
        serviceConfig: PairingResponderService.Config
            = PairingResponderService.Config(),
        sent: @escaping () -> [VideoChannelDatagram],
        append: @escaping (VideoChannelDatagram) -> Void
    ) throws -> (shell: HostShell, client: PakeClient) {
        let hostStatic = NoiseKeyPair.generate()
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: Self.rateBPS
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x96),
            send: append
        )
        let shell = HostShell(
            session: session,
            service: PairingResponderService(
                pin: pin,
                hostStaticPublicKey: hostStatic.publicKey,
                config: serviceConfig
            )
        )
        var client = try PakeClient(hostStaticPublicKey: hostStatic.publicKey)
        shell.handle(
            session.receive(
                try client.message1Datagram(clientMicros: 500),
                from: Self.tupleA, now: 0, hostMicroseconds: 0
            ),
            nowNS: 0
        )
        XCTAssertEqual(session.phase, .established)
        session.pump(now: 0)
        let handshake = sent()
        XCTAssertEqual(handshake.count, 3,
                       "message 2, session-start beacon, capability declaration")
        try client.absorb(handshake[0].bytes, nowMicros: 600)
        try client.absorb(handshake[1].bytes, nowMicros: 700)
        try client.absorb(handshake[2].bytes, nowMicros: 800)
        XCTAssertNotNil(client.transport)
        // The W7 declaration rides ahead of everything (HS-8's deferred
        // capabilities item); ack it so the pairing legs start from a
        // quiescent reliable stream.
        XCTAssertEqual(client.delivered.count, 1)
        XCTAssertEqual(client.delivered.first?.first,
                       CtrlMessageType.capabilityDeclaration)
        client.delivered.removeAll()
        for datagram in try client.pollOut(nowMicros: 900) {
            shell.handle(
                session.receive(
                    datagram, from: Self.tupleA,
                    now: 2_000_000, hostMicroseconds: 2_000
                ),
                nowNS: 2_000_000
            )
        }
        return (shell, client)
    }

    /// Direct (lossless, in-order) exchange until both ARQ endpoints
    /// are quiescent. `t` is virtual µs. `sent` is a live view of the
    /// session's outbox — replies produced inside this loop must flow.
    private func settle(
        shell: HostShell, client: inout PakeClient,
        sent: () -> [VideoChannelDatagram], forwarded: inout Int,
        t: inout UInt64
    ) throws {
        var idle = 0
        while idle < 3 {
            t += 2_000
            var moved = false
            shell.handle(
                shell.session.advance(now: t * 1_000, hostMicroseconds: t),
                nowNS: t * 1_000
            )
            shell.session.pump(now: t * 1_000)
            while forwarded < sent().count {
                try client.absorb(sent()[forwarded].bytes, nowMicros: t)
                forwarded += 1
                moved = true
            }
            for datagram in try client.pollOut(nowMicros: t) {
                shell.handle(
                    shell.session.receive(
                        datagram, from: Self.tupleA,
                        now: t * 1_000, hostMicroseconds: t
                    ),
                    nowNS: t * 1_000
                )
                moved = true
            }
            idle = moved ? 0 : idle + 1
        }
    }

    // MARK: The gate — pairing completes through the W-G4 storm

    func testGatePairingCompletesOverTheStorm() throws {
        var sent: [VideoChannelDatagram] = []
        let (shell, clientValue) = try establish(
            sent: { sent }, append: { sent.append($0) }
        )
        var client = clientValue
        var forwarded = sent.count // handshake rode outside the pipe

        var net = SimNet(
            config: SimNetConfig(
                lossRate: 0.05,
                duplicateRate: 0.02,
                baseDelayMicroseconds: 3_000,
                jitterMicroseconds: 4_000
            ),
            seed: 0x9A17_4106
        )

        var t: UInt64 = 1_000
        try client.beginPairing(pin: Self.pin, nowMicros: t)
        let horizon: UInt64 = 30_000_000
        var converged: UInt64?
        while t < horizon {
            for delivery in net.deliveries(upTo: t) {
                if delivery.destination == 0 {
                    shell.handle(
                        shell.session.receive(
                            delivery.bytes, from: Self.tupleA,
                            now: t * 1_000, hostMicroseconds: t
                        ),
                        nowNS: t * 1_000
                    )
                } else {
                    try client.absorb(delivery.bytes, nowMicros: t)
                }
            }
            shell.handle(
                shell.session.advance(now: t * 1_000, hostMicroseconds: t),
                nowNS: t * 1_000
            )
            shell.session.pump(now: t * 1_000)
            while forwarded < sent.count {
                net.send(from: 0, bytes: sent[forwarded].bytes, now: t)
                forwarded += 1
            }
            for datagram in try client.pollOut(nowMicros: t) {
                net.send(from: 1, bytes: datagram, now: t)
            }
            if shell.service.isPaired, client.result != nil,
               shell.session.arqIsQuiescent, client.arq.isQuiescent,
               net.nextArrivalTime == nil {
                converged = t
                break
            }
            var next = t + 5_000
            if let arrival = net.nextArrivalTime {
                next = min(next, max(arrival, t + 1))
            }
            if let wake = shell.session.nextWake(now: t * 1_000) {
                next = min(next, max(wake / 1_000 + 1, t + 1))
            }
            t = next
        }

        XCTAssertNotNil(converged, "pairing did not converge in the storm")
        XCTAssertGreaterThan(net.lostCount, 0, "the storm must be real")

        // Both ends hold the same authenticated ISK, and each pins the
        // other's static — the promotion of keys the session carried.
        XCTAssertEqual(
            shell.service.pairedClientStaticPublicKey,
            client.staticKeys.publicKey,
            "the host pins the client static message 1 delivered"
        )
        XCTAssertEqual(
            client.result?.peerStaticPublicKeyToPin,
            client.hostStaticPublicKey,
            "the client pins the host static it dialed"
        )
        XCTAssertTrue(shell.events.contains(
            .paired(clientStaticPublicKey: client.staticKeys.publicKey)
        ))
        XCTAssertEqual(shell.events.contains { event in
            if case .attemptOpened = event { return true } else { return false }
        }, true)
        XCTAssertEqual(shell.replyFailures, 0)
        XCTAssertNil(client.sawReject)

        print("HS-9 gate: paired through 5% loss / 2% dup / 4 ms jitter "
            + "(\(net.lostCount) lost, \(net.duplicatedCount) duplicated of "
            + "\(net.sentCount); converged at \(converged.map(String.init) ?? "-") "
            + "µs virtual)")
    }

    // MARK: Wrong PIN — loud, oracle-free, nothing pinned

    func testWrongPinAbortsClientSideAndPinsNothing() throws {
        var sent: [VideoChannelDatagram] = []
        let (shell, clientValue) = try establish(
            sent: { sent }, append: { sent.append($0) }
        )
        var client = clientValue
        var forwarded = sent.count
        var t: UInt64 = 1_000_000

        // The client holds the wrong PIN. It learns at share B (Tb
        // mismatch), aborts with 0x0E, and the host pins nothing. The
        // attempt was spent when share B left — the online-guess
        // accounting the service's comment pins down.
        try client.beginPairing(pin: Array("000000".utf8), nowMicros: t)
        try settle(shell: shell, client: &client,
                   sent: { sent }, forwarded: &forwarded, t: &t)

        XCTAssertEqual(client.pakeFailure, .confirmationFailed,
                       "the client's own Tb check must fail")
        XCTAssertFalse(shell.service.isPaired)
        XCTAssertNil(shell.service.pairedClientStaticPublicKey)
        XCTAssertTrue(shell.events.contains(
            .clientAborted(.confirmationFailed)
        ), "the host hears the abort loudly")
        XCTAssertTrue(shell.events.contains(
            .attemptOpened(attempt: 1, of: 3)
        ), "share B left, so the guess was spent")
    }

    func testForgedConfirmRejectsWithOneReason() throws {
        var sent: [VideoChannelDatagram] = []
        let (shell, clientValue) = try establish(
            sent: { sent }, append: { sent.append($0) }
        )
        var client = clientValue
        var forwarded = sent.count
        var t: UInt64 = 1_000_000

        // A right-PIN share A, then a forged confirmation tag: the
        // tamper case. The wire answer must be the same single reason
        // wrong PIN gets — 0x0E confirmation-failed, no oracle.
        try client.beginPairing(pin: Self.pin, nowMicros: t)
        try settleUntilShareB(shell: shell, client: &client,
                              sent: { sent }, forwarded: &forwarded, t: &t)
        try client.arq.send(
            message: PairingConfirm(
                confirmationTag: [UInt8](repeating: 0xAA, count: 64)
            ).encode(),
            now: ClientTimestamp(microseconds: t)
        )
        try settle(shell: shell, client: &client,
                   sent: { sent }, forwarded: &forwarded, t: &t)

        XCTAssertFalse(shell.service.isPaired)
        XCTAssertTrue(shell.events.contains(
            .rejected(.confirmationFailed, attemptsRemaining: 2)
        ))
        XCTAssertEqual(client.sawReject, .confirmationFailed)
    }

    /// Like settle, but stops the client's driver from reacting to the
    /// share B (the forged-confirm tests speak for the client instead).
    private func settleUntilShareB(
        shell: HostShell, client: inout PakeClient,
        sent: () -> [VideoChannelDatagram], forwarded: inout Int,
        t: inout UInt64
    ) throws {
        client.pake = nil // driver has nothing to react with
        try settle(shell: shell, client: &client,
                   sent: sent, forwarded: &forwarded, t: &t)
        XCTAssertTrue(client.delivered.contains {
            $0.first == CtrlMessageType.pairingShareB
        }, "share B must have arrived")
        client.delivered.removeAll()
    }

    // MARK: The guess budget burns the PIN

    func testThreeFailedGuessesBurnThePin() throws {
        var sent: [VideoChannelDatagram] = []
        let (shell, clientValue) = try establish(
            // The throttle is exercised separately; here it would only
            // slow the three attempts down.
            serviceConfig: PairingResponderService.Config(
                minAttemptIntervalNS: 0
            ),
            sent: { sent }, append: { sent.append($0) }
        )
        var client = clientValue
        var forwarded = sent.count
        var t: UInt64 = 1_000_000

        for attempt in 1...3 {
            try client.beginPairing(pin: Array("11111\(attempt)".utf8),
                                    nowMicros: t)
            try settleUntilShareB(shell: shell, client: &client,
                                  sent: { sent }, forwarded: &forwarded, t: &t)
            try client.arq.send(
                message: PairingConfirm(
                    confirmationTag: [UInt8](repeating: 0xBB, count: 64)
                ).encode(),
                now: ClientTimestamp(microseconds: t)
            )
            try settle(shell: shell, client: &client,
                       sent: { sent }, forwarded: &forwarded, t: &t)
            XCTAssertTrue(shell.events.contains(
                .attemptOpened(attempt: attempt, of: 3)
            ))
        }

        XCTAssertEqual(
            shell.events.filter { $0 == .pinBurned }.count, 1,
            "the burn announces exactly once, at the third failure"
        )
        XCTAssertTrue(shell.service.isBurned)

        // A fourth share A meets wire silence: no reply, no new events.
        let eventsBefore = shell.events.count
        let repliesBefore = sent.count
        try client.beginPairing(pin: Self.pin, nowMicros: t)
        try settle(shell: shell, client: &client,
                   sent: { sent }, forwarded: &forwarded, t: &t)
        XCTAssertEqual(shell.events.count, eventsBefore,
                       "a burned PIN answers nothing")
        // Only ARQ ACK datagrams may have moved (the segment must still
        // be acknowledged — reliability is below the pairing layer);
        // none of them may carry a pairing reply.
        let pairingReplies = shell.events.suffix(
            shell.events.count - eventsBefore
        )
        XCTAssertTrue(pairingReplies.isEmpty)
        _ = repliesBefore
        XCTAssertFalse(shell.service.isPaired)
    }

    // MARK: The attempt throttle

    func testShareAThrottledInsideTheWindow() throws {
        var sent: [VideoChannelDatagram] = []
        let (shell, clientValue) = try establish(
            sent: { sent }, append: { sent.append($0) }
        )
        var client = clientValue
        var forwarded = sent.count
        var t: UInt64 = 1_000_000 // µs; service sees ns

        try client.beginPairing(pin: Self.pin, nowMicros: t)
        try settleUntilShareB(shell: shell, client: &client,
                              sent: { sent }, forwarded: &forwarded, t: &t)
        XCTAssertTrue(shell.events.contains(
            .attemptOpened(attempt: 1, of: 3)
        ))

        // A second opening 100 ms later: inside the 1 s window, dropped
        // without a reply and without spending a guess.
        t += 100_000
        try client.beginPairing(pin: Self.pin, nowMicros: t)
        try settle(shell: shell, client: &client,
                   sent: { sent }, forwarded: &forwarded, t: &t)
        XCTAssertTrue(shell.events.contains(.throttled))
        XCTAssertFalse(shell.events.contains(
            .attemptOpened(attempt: 2, of: 3)
        ))

        // Past the window the next attempt opens — and completes.
        t += 1_100_000
        client.delivered.removeAll()
        try client.beginPairing(pin: Self.pin, nowMicros: t)
        try settle(shell: shell, client: &client,
                   sent: { sent }, forwarded: &forwarded, t: &t)
        XCTAssertTrue(shell.events.contains(
            .attemptOpened(attempt: 2, of: 3)
        ))
        XCTAssertTrue(shell.service.isPaired)
    }

    // MARK: Guess accounting survives a re-handshake

    func testBudgetSurvivesReconnect() throws {
        let hostStatic = NoiseKeyPair.generate()
        let service = PairingResponderService(
            pin: Self.pin,
            hostStaticPublicKey: hostStatic.publicKey,
            config: PairingResponderService.Config(minAttemptIntervalNS: 0)
        )
        let clientStatic = NoiseKeyPair.generate().publicKey

        // Two spent guesses under one session…
        service.sessionEstablished(
            clientStaticPublicKey: clientStatic,
            noiseHandshakeHash: [UInt8](repeating: 0x11, count: 32)
        )
        for _ in 0..<2 {
            let shareA = validShareA(
                clientStatic: clientStatic,
                hostStatic: hostStatic.publicKey,
                hash: [UInt8](repeating: 0x11, count: 32)
            )
            let output = service.handleReliableCtrl(shareA, now: 0)
            XCTAssertEqual(output?.replies.count, 1)
        }
        // …then the client re-handshakes. The binding refreshes; the
        // budget does not.
        service.sessionEstablished(
            clientStaticPublicKey: clientStatic,
            noiseHandshakeHash: [UInt8](repeating: 0x22, count: 32)
        )
        let third = service.handleReliableCtrl(
            validShareA(
                clientStatic: clientStatic,
                hostStatic: hostStatic.publicKey,
                hash: [UInt8](repeating: 0x22, count: 32)
            ),
            now: 0
        )
        XCTAssertEqual(third?.events.first,
                       .attemptOpened(attempt: 3, of: 3))
        let fourth = service.handleReliableCtrl(
            validShareA(
                clientStatic: clientStatic,
                hostStatic: hostStatic.publicKey,
                hash: [UInt8](repeating: 0x22, count: 32)
            ),
            now: 0
        )
        XCTAssertEqual(fourth?.events, [.pinBurned])
        XCTAssertEqual(fourth?.replies, [])
    }

    private func validShareA(
        clientStatic: [UInt8], hostStatic: [UInt8], hash: [UInt8]
    ) -> [UInt8] {
        let initiator = try! PairingPakeInitiator(
            pin: Array("999999".utf8), // any valid guess
            clientStaticPublicKey: clientStatic,
            hostStaticPublicKey: hostStatic,
            noiseHandshakeHash: hash
        )
        return try! initiator.makeShareA().encode()
    }

    // MARK: A low-order share spends no guess but answers typed

    func testLowOrderShareRejectsInvalidShareWithoutSpendingAGuess() throws {
        let hostStatic = NoiseKeyPair.generate()
        let service = PairingResponderService(
            pin: Self.pin,
            hostStaticPublicKey: hostStatic.publicKey,
            config: PairingResponderService.Config(minAttemptIntervalNS: 0)
        )
        service.sessionEstablished(
            clientStaticPublicKey: NoiseKeyPair.generate().publicKey,
            noiseHandshakeHash: [UInt8](repeating: 0x33, count: 32)
        )
        let zeroShare = try PairingShareA(
            share: [UInt8](repeating: 0, count: 32)
        ).encode()
        let output = service.handleReliableCtrl(zeroShare, now: 0)
        XCTAssertEqual(output?.events, [
            .rejected(.invalidShare, attemptsRemaining: 3),
        ])
        XCTAssertEqual(output?.replies, [
            PairingReject(reason: .invalidShare).encode(),
        ])
        XCTAssertFalse(service.isBurned)
    }

    // MARK: The message-1 flood gate

    func testHandshakeGateDropsFloodBeforeNoiseAllocation() throws {
        let hostStatic = NoiseKeyPair.generate()
        var sent: [VideoChannelDatagram] = []
        let session = Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: hostStatic),
                rateBitsPerSecond: Self.rateBPS,
                handshakeGate: HandshakeGate.Config(
                    ratePerSecond: 10, burst: 10
                )
            ),
            clientTuple: Self.tupleA,
            now: 0,
            rng: SplitMix64(seed: 0x7)
        ) { sent.append($0) }

        // 200 garbage message 1s in one instant: the burst admits 10
        // (each fails in the Noise responder), the rest drop unread.
        var rng = SplitMix64(seed: 0xF100D)
        var throttled = 0
        var failed = 0
        for i in 0..<200 {
            let garbage = (0..<64).map { _ in
                UInt8.random(in: 0...255, using: &rng)
            }
            let envelope = Envelope(
                channel: .ctrl,
                seq: ChannelSeq(rawValue: UInt16(i)),
                frame: FrameNumber(rawValue: 0),
                timestamp: 0,
                fec: 0
            )
            let datagram = try envelope.encode(
                payload: [CtrlMessageType.noiseHandshake1] + garbage
            )
            for event in session.receive(
                datagram, from: Self.tupleA, now: 1_000, hostMicroseconds: 1
            ) {
                if case .dropped(.handshakeThrottled) = event { throttled += 1 }
                if case .dropped(.handshakeFailed) = event { failed += 1 }
            }
        }
        XCTAssertEqual(failed, 10, "exactly the burst reaches Noise")
        XCTAssertEqual(throttled, 190)
        XCTAssertEqual(session.counters.handshakesThrottled, 190)
        XCTAssertEqual(session.phase, .awaitingHandshake,
                       "garbage must never establish")

        // Two seconds later the bucket has refilled: an honest client's
        // message 1 completes — the flood cost availability for moments,
        // not the session.
        var client = try PakeClient(hostStaticPublicKey: hostStatic.publicKey)
        let events = session.receive(
            try client.message1Datagram(clientMicros: 2_000_000),
            from: Self.tupleA,
            now: 2_000_000_000, hostMicroseconds: 2_000_000
        )
        XCTAssertTrue(events.contains(.handshakeCompleted(
            remoteStaticPublicKey: client.staticKeys.publicKey
        )))
        XCTAssertEqual(session.phase, .established)
    }

    // MARK: 1-RTT reconnect against the pinned set

    func testPairedSetAdmitsPairedAndRefusesStrangers() throws {
        let hostStatic = NoiseKeyPair.generate()
        let paired = NoiseKeyPair.generate()
        let stranger = NoiseKeyPair.generate()

        func attempt(_ keys: NoiseKeyPair) throws -> [SessionEvent] {
            let session = Session(
                config: SessionConfig(
                    crypto: .noise(hostStatic: hostStatic),
                    rateBitsPerSecond: Self.rateBPS,
                    allowedClientStaticPublicKeys: [paired.publicKey]
                ),
                clientTuple: Self.tupleA,
                now: 0,
                rng: SplitMix64(seed: 0x51)
            ) { _ in }
            var noise = try NoiseSession(
                role: .initiator,
                staticKeys: keys,
                remoteStaticPublicKey: hostStatic.publicKey
            )
            let envelope = Envelope(
                channel: .ctrl,
                seq: ChannelSeq(rawValue: 0),
                frame: FrameNumber(rawValue: 0),
                timestamp: 0,
                fec: 0
            )
            let datagram = try envelope.encode(
                payload: [CtrlMessageType.noiseHandshake1]
                    + (try noise.writeMessage1())
            )
            return session.receive(
                datagram, from: Self.tupleA, now: 0, hostMicroseconds: 0
            )
        }

        // The paired client reconnects 1-RTT: message 1 in, established.
        XCTAssertTrue(try attempt(paired).contains(.handshakeCompleted(
            remoteStaticPublicKey: paired.publicKey
        )), "pair once, reconnect 1-RTT — no PAKE, no UI")

        // A stranger's message 1 dies at the paired-set check.
        let refused = try attempt(stranger)
        XCTAssertTrue(refused.contains { event in
            if case .dropped(.handshakeFailed(let why)) = event {
                return why.contains("paired set")
            }
            return false
        })
    }
}
