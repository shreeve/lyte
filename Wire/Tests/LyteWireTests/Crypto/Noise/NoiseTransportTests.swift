import XCTest
import LyteWire
import LyteWireTestKit

// W-G6's transport half: the extended-counter nonce (ROC reconstruction
// across the u16 wrap), the replay window, tamper rejection on both
// ciphertext and AAD, the byte budgets, and the rekey/epoch primitive
// with its receive-grace window. The nonce-uniqueness proof (no
// (key, nonce) pair ever repeats across seq wrap and rekey) is the
// ExtendedCounterTracker + epoch tests together.

final class NoiseTransportTests: XCTestCase {

    private func counting(from offset: Int, count: Int) -> [UInt8] {
        (0..<count).map { UInt8((offset + $0) & 0xFF) }
    }

    private func makeTransports() throws -> (client: NoiseTransport, host: NoiseTransport) {
        let clientStatic = NoiseKeyPair.generate()
        let hostStatic = NoiseKeyPair.generate()
        var client = try NoiseSession(
            role: .initiator,
            staticKeys: clientStatic,
            remoteStaticPublicKey: hostStatic.publicKey
        )
        var host = try NoiseSession(role: .responder, staticKeys: hostStatic)
        _ = try host.readMessage1(try client.writeMessage1()[...])
        _ = try client.readMessage2(try host.writeMessage2()[...])
        return (try client.makeTransport(), try host.makeTransport())
    }

    private func envelope(
        chan: UInt8 = 2, seq: UInt16, frame: UInt32 = 1
    ) -> Envelope {
        Envelope(
            channel: ChannelId(rawValue: chan),
            seq: ChannelSeq(rawValue: seq),
            frame: FrameNumber(rawValue: frame),
            timestamp: 1_000_000,
            fec: 0
        )
    }

    private func aad(_ envelope: Envelope) throws -> [UInt8] {
        try envelope.encode(payload: [])
    }

    // MARK: Round trip + tamper

    func testSealUnsealRoundTripBothDirections() throws {
        var (client, host) = try makeTransports()
        let env = envelope(seq: 0)
        let headerBytes = try aad(env)
        let plaintext = Array("shard payload".utf8)

        let up = try client.seal(
            plaintext: plaintext[...], aad: headerBytes[...], envelope: env
        )
        XCTAssertEqual(up.count, plaintext.count + 16)
        XCTAssertEqual(
            try host.unseal(wirePayload: up[...], aad: headerBytes[...], envelope: env),
            plaintext
        )

        let down = try host.seal(
            plaintext: plaintext[...], aad: headerBytes[...], envelope: env
        )
        XCTAssertNotEqual(up, down, "direction keys must differ")
        XCTAssertEqual(
            try client.unseal(wirePayload: down[...], aad: headerBytes[...], envelope: env),
            plaintext
        )
    }

    func testTamperedCiphertextTagAndAadFail() throws {
        var (client, host) = try makeTransports()
        let env = envelope(seq: 5)
        let headerBytes = try aad(env)
        let plaintext = counting(from: 0, count: 100)
        let sealed = try client.seal(
            plaintext: plaintext[...], aad: headerBytes[...], envelope: env
        )

        // Ciphertext bit flip, tag bit flip.
        for index in [0, sealed.count - 17, sealed.count - 16, sealed.count - 1] {
            var tampered = sealed
            tampered[index] ^= 0x01
            var freshHost = host
            XCTAssertThrowsError(
                try freshHost.unseal(
                    wirePayload: tampered[...], aad: headerBytes[...], envelope: env
                ),
                "byte \(index)"
            ) { error in
                XCTAssertEqual(error as? NoiseError, .authenticationFailure)
            }
        }

        // AAD flip: the envelope header is authenticated even though it
        // rides in the clear.
        var tamperedAad = headerBytes
        tamperedAad[8] ^= 0x01  // a timestamp byte
        XCTAssertThrowsError(
            try host.unseal(
                wirePayload: sealed[...], aad: tamperedAad[...], envelope: env
            )
        ) { error in
            XCTAssertEqual(error as? NoiseError, .authenticationFailure)
        }

        // A forged seq in both envelope and AAD: the nonce moves with it,
        // so authentication still fails — a datagram cannot be replayed
        // into a different sequence slot.
        var shifted = env
        shifted.seq = ChannelSeq(rawValue: 6)
        let shiftedAad = try aad(shifted)
        XCTAssertThrowsError(
            try host.unseal(
                wirePayload: sealed[...], aad: shiftedAad[...], envelope: shifted
            )
        ) { error in
            XCTAssertEqual(error as? NoiseError, .authenticationFailure)
        }

        // And the genuine datagram still opens (failures committed no state).
        XCTAssertEqual(
            try host.unseal(
                wirePayload: sealed[...], aad: headerBytes[...], envelope: env
            ),
            plaintext
        )
    }

    // MARK: Budgets

    func testBudgetsEnforced() throws {
        var (client, host) = try makeTransports()
        let env = envelope(seq: 0)
        let headerBytes = try aad(env)

        // 1112 B seals to exactly 1128 B; 1113 B refuses.
        let maxShard = counting(from: 0, count: WireBudget.maxPlaintextShardByteCount)
        let sealed = try client.seal(
            plaintext: maxShard[...], aad: headerBytes[...], envelope: env
        )
        XCTAssertEqual(sealed.count, WireBudget.maxWirePayloadByteCount)
        XCTAssertEqual(
            try host.unseal(wirePayload: sealed[...], aad: headerBytes[...], envelope: env),
            maxShard
        )

        let overShard = counting(from: 0, count: WireBudget.maxPlaintextShardByteCount + 1)
        XCTAssertThrowsError(
            try client.seal(
                plaintext: overShard[...], aad: headerBytes[...],
                channel: env.channel, seq: ChannelSeq(rawValue: 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? NoiseError,
                .plaintextOverBudget(WireBudget.maxPlaintextShardByteCount + 1)
            )
        }

        // Unseal bounds: under one tag, and over the wire ceiling.
        XCTAssertThrowsError(
            try host.unseal(
                wirePayload: [UInt8](repeating: 0, count: 15)[...],
                aad: headerBytes[...], envelope: env
            )
        ) { error in
            XCTAssertEqual(error as? NoiseError, .wirePayloadOutOfBounds(15))
        }
        let oversize = [UInt8](repeating: 0, count: WireBudget.maxWirePayloadByteCount + 1)
        XCTAssertThrowsError(
            try host.unseal(
                wirePayload: oversize[...], aad: headerBytes[...], envelope: env
            )
        ) { error in
            XCTAssertEqual(
                error as? NoiseError,
                .wirePayloadOutOfBounds(WireBudget.maxWirePayloadByteCount + 1)
            )
        }
    }

    // MARK: ROC across the u16 wrap

    func testRocReconstructionAcrossSeqWrap() throws {
        var (client, host) = try makeTransports()

        // Walk the sender straight through the wrap; deliver everything.
        var sealedDatagrams: [(env: Envelope, aad: [UInt8], wire: [UInt8], plaintext: [UInt8])] = []
        var seq = ChannelSeq(rawValue: 65533)
        for i in 0..<6 {
            let env = envelope(seq: seq.rawValue)
            let headerBytes = try aad(env)
            let plaintext = counting(from: i, count: 32)
            let wire = try client.seal(
                plaintext: plaintext[...], aad: headerBytes[...], envelope: env
            )
            sealedDatagrams.append((env, headerBytes, wire, plaintext))
            seq = seq.next
        }
        // Deliver out of order across the wrap boundary: 65533, 65535,
        // 65534, 0, 2, 1 — reorder inside the window is admitted, and the
        // extended counter (not the raw seq) picks the right nonce.
        for index in [0, 2, 1, 3, 5, 4] {
            let d = sealedDatagrams[index]
            XCTAssertEqual(
                try host.unseal(
                    wirePayload: d.wire[...], aad: d.aad[...], envelope: d.env
                ),
                d.plaintext,
                "delivery of seq \(d.env.seq.rawValue)"
            )
        }
    }

    func testSenderRefusesNonMonotonicSeq() throws {
        var (client, _) = try makeTransports()
        let env = envelope(seq: 10)
        let headerBytes = try aad(env)
        _ = try client.seal(
            plaintext: [1, 2, 3][...], aad: headerBytes[...], envelope: env
        )
        // Same seq again — deterministic re-seal is refused; a retransmit
        // resends the already-sealed bytes (core plan §2 decision 2).
        XCTAssertThrowsError(
            try client.seal(
                plaintext: [9, 9, 9][...], aad: headerBytes[...], envelope: env
            )
        ) { error in
            XCTAssertEqual(error as? NoiseError, .sendSequenceNotMonotonic)
        }
        // And a seq behind the high-water mark likewise.
        XCTAssertThrowsError(
            try client.seal(
                plaintext: [7][...], aad: headerBytes[...],
                channel: env.channel, seq: ChannelSeq(rawValue: 9)
            )
        ) { error in
            XCTAssertEqual(error as? NoiseError, .sendSequenceNotMonotonic)
        }
    }

    // MARK: Replay and staleness

    func testReplayRejectedOutOfOrderAdmitted() throws {
        var (client, host) = try makeTransports()
        var datagrams: [(env: Envelope, aad: [UInt8], wire: [UInt8])] = []
        for seq in 0..<5 {
            let env = envelope(seq: UInt16(seq))
            let headerBytes = try aad(env)
            let wire = try client.seal(
                plaintext: counting(from: seq, count: 10)[...],
                aad: headerBytes[...], envelope: env
            )
            datagrams.append((env, headerBytes, wire))
        }

        // In-window reorder: 0, 2, 4, then the stragglers 1 and 3.
        for index in [0, 2, 4, 1, 3] {
            let d = datagrams[index]
            XCTAssertNoThrow(
                try host.unseal(wirePayload: d.wire[...], aad: d.aad[...], envelope: d.env)
            )
        }
        // Every replay — the byte-identical retransmit that lost the
        // race — rejects as replayedSequence, exactly once admitted.
        for d in datagrams {
            XCTAssertThrowsError(
                try host.unseal(wirePayload: d.wire[...], aad: d.aad[...], envelope: d.env)
            ) { error in
                XCTAssertEqual(error as? NoiseError, .replayedSequence)
            }
        }
    }

    func testStaleSequenceBeyondWindowRejected() throws {
        var (client, host) = try makeTransports()

        // Seal seq 0, hold it back, advance the channel far past the
        // 64-deep window, then deliver the straggler.
        let heldEnv = envelope(seq: 0)
        let heldAad = try aad(heldEnv)
        let held = try client.seal(
            plaintext: [1][...], aad: heldAad[...], envelope: heldEnv
        )

        for seq in 1...80 {
            let env = envelope(seq: UInt16(seq))
            let headerBytes = try aad(env)
            let wire = try client.seal(
                plaintext: [2][...], aad: headerBytes[...], envelope: env
            )
            _ = try host.unseal(
                wirePayload: wire[...], aad: headerBytes[...], envelope: env
            )
        }

        XCTAssertThrowsError(
            try host.unseal(wirePayload: held[...], aad: heldAad[...], envelope: heldEnv)
        ) { error in
            XCTAssertEqual(error as? NoiseError, .staleSequence)
        }
    }

    func testFailedOpenCommitsNoReceiverState() throws {
        var (client, host) = try makeTransports()
        let env = envelope(seq: 0)
        let headerBytes = try aad(env)
        let wire = try client.seal(
            plaintext: [42][...], aad: headerBytes[...], envelope: env
        )
        var forged = wire
        forged[0] ^= 0xFF
        XCTAssertThrowsError(
            try host.unseal(wirePayload: forged[...], aad: headerBytes[...], envelope: env)
        )
        // The genuine datagram is not "replayed" — the forgery must not
        // have burned its window slot.
        XCTAssertEqual(
            try host.unseal(wirePayload: wire[...], aad: headerBytes[...], envelope: env),
            [42]
        )
    }

    // MARK: Rekey

    func testRekeyChangesKeyAndGraceWindowCoversInFlight() throws {
        var (client, host) = try makeTransports()

        // A datagram sealed before the rekey but delivered after it.
        let inFlightEnv = envelope(seq: 0)
        let inFlightAad = try aad(inFlightEnv)
        let inFlight = try client.seal(
            plaintext: Array("in flight".utf8)[...],
            aad: inFlightAad[...], envelope: inFlightEnv
        )

        try client.rekeySend()
        try host.rekeyReceive()
        XCTAssertEqual(client.sendEpoch, 1)
        XCTAssertEqual(host.receiveEpoch, 1)
        XCTAssertEqual(client.datagramsSealedSinceRekey, 0)

        // Post-rekey traffic flows on the new epoch key…
        let env1 = envelope(seq: 1)
        let aad1 = try aad(env1)
        let post = try client.seal(
            plaintext: Array("post rekey".utf8)[...], aad: aad1[...], envelope: env1
        )
        XCTAssertEqual(
            try host.unseal(wirePayload: post[...], aad: aad1[...], envelope: env1),
            Array("post rekey".utf8)
        )
        // …and the in-flight datagram still opens via the grace key.
        XCTAssertEqual(
            try host.unseal(
                wirePayload: inFlight[...], aad: inFlightAad[...], envelope: inFlightEnv
            ),
            Array("in flight".utf8)
        )
        // The reverse direction is untouched.
        XCTAssertEqual(host.sendEpoch, 0)
        XCTAssertEqual(client.receiveEpoch, 0)
    }

    func testRekeyProducesDifferentCiphertextForSameNonceSlot() throws {
        // Two sessions from the same fixed keys: one rekeys, one does
        // not; sealing the identical (chan, seq, plaintext, aad) must
        // differ — the epoch changed both key and nonce, so no
        // (key, nonce) pair repeats across a rekey.
        let clientStatic = NoiseKeyPair.generate()
        let hostStatic = NoiseKeyPair.generate()
        let ephemeralC = NoiseKeyPair.generate()
        let ephemeralH = NoiseKeyPair.generate()

        func makeClientTransport() throws -> NoiseTransport {
            var client = try NoiseSession(
                role: .initiator,
                staticKeys: clientStatic,
                remoteStaticPublicKey: hostStatic.publicKey,
                fixedEphemeral: ephemeralC
            )
            var host = try NoiseSession(
                role: .responder, staticKeys: hostStatic, fixedEphemeral: ephemeralH
            )
            _ = try host.readMessage1(try client.writeMessage1()[...])
            _ = try client.readMessage2(try host.writeMessage2()[...])
            return try client.makeTransport()
        }

        let env = envelope(seq: 0)
        let headerBytes = try aad(env)
        let plaintext = Array("same slot".utf8)

        var plain = try makeClientTransport()
        var rekeyed = try makeClientTransport()
        try rekeyed.rekeySend()

        let a = try plain.seal(
            plaintext: plaintext[...], aad: headerBytes[...], envelope: env
        )
        let b = try rekeyed.seal(
            plaintext: plaintext[...], aad: headerBytes[...], envelope: env
        )
        XCTAssertNotEqual(a, b)
    }

    func testRekeyThresholdConstantIsSane() {
        // The transport-doc policy input: 2^24 datagrams per direction.
        XCTAssertEqual(NoiseTransport.rekeyDatagramThreshold, 16_777_216)
    }

    // MARK: ARQ retransmits vs the replay window (the W3 concern)

    func testArqRetransmitSurvivesReplayWindowAdvance() throws {
        // The invariant the pre-H1 review verifies as implemented: an
        // ARQ retransmit rides a FRESH sealed datagram (fresh seq,
        // fresh nonce), so the 64-deep replay window can never starve
        // it — while the dropped ORIGINAL datagram, arriving late after
        // the channel moved on, is exactly what the window kills.
        var (client, host) = try makeTransports()
        var sender = ArqEndpoint<HostClock>(channel: .ctrl)
        var receiver = ArqEndpoint<HostClock>(channel: .ctrl)
        var nextSeq: UInt16 = 0

        func sealFresh(
            _ payload: [UInt8]
        ) throws -> (env: Envelope, aad: [UInt8], wire: [UInt8]) {
            let env = envelope(seq: nextSeq)
            nextSeq &+= 1
            let headerBytes = try aad(env)
            let wire = try client.seal(
                plaintext: payload[...], aad: headerBytes[...], envelope: env
            )
            return (env, headerBytes, wire)
        }

        // First transmission: sealed, then lost in flight.
        let message: [UInt8] = [0x20, 42, 43, 44]
        try sender.send(message: message, now: HostTimestamp(microseconds: 0))
        let (firstPayloads, deadline) = sender.poll(
            now: HostTimestamp(microseconds: 0)
        )
        XCTAssertEqual(firstPayloads.count, 1)
        let dropped = try sealFresh(firstPayloads[0])
        let ptoDeadline = try XCTUnwrap(deadline)

        // The channel keeps talking: 80 unrelated datagrams advance the
        // receiver's replay window far past the dropped seq.
        for _ in 0..<80 {
            let filler = try sealFresh([0x01])
            _ = try host.unseal(
                wirePayload: filler.wire[...], aad: filler.aad[...],
                envelope: filler.env
            )
        }

        // The lost original straggles in now: stale, dead — a
        // byte-identical datagram resend would share this fate.
        XCTAssertThrowsError(
            try host.unseal(
                wirePayload: dropped.wire[...], aad: dropped.aad[...],
                envelope: dropped.env
            )
        ) { error in
            XCTAssertEqual(error as? NoiseError, .staleSequence)
        }

        // PTO fires; the retransmit is the same SEGMENT in a fresh
        // datagram — it seals under a fresh seq and delivers.
        let retryAt = HostTimestamp(
            microseconds: ptoDeadline.microseconds + 1
        )
        let (retryPayloads, _) = sender.poll(now: retryAt)
        XCTAssertFalse(retryPayloads.isEmpty, "the PTO must retransmit")
        var delivered: [[UInt8]] = []
        for payload in retryPayloads {
            let fresh = try sealFresh(payload)
            let plaintext = try host.unseal(
                wirePayload: fresh.wire[...], aad: fresh.aad[...],
                envelope: fresh.env
            )
            for event in receiver.ingest(payload: plaintext[...], now: retryAt) {
                if case .message(_, let bytes) = event {
                    delivered.append(bytes)
                }
            }
        }
        XCTAssertEqual(delivered, [message], "exactly once, in order")
    }

    func testDatagramCountersFeedRekeyPolicy() throws {
        var (client, host) = try makeTransports()
        for seq in 0..<3 {
            let env = envelope(seq: UInt16(seq))
            let headerBytes = try aad(env)
            let wire = try client.seal(
                plaintext: [0][...], aad: headerBytes[...], envelope: env
            )
            _ = try host.unseal(
                wirePayload: wire[...], aad: headerBytes[...], envelope: env
            )
        }
        XCTAssertEqual(client.datagramsSealedSinceRekey, 3)
        XCTAssertEqual(host.datagramsOpenedSinceRekey, 3)
        try client.rekeySend()
        XCTAssertEqual(client.datagramsSealedSinceRekey, 0)
    }
}
