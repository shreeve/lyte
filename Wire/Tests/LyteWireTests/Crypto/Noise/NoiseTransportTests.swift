import XCTest
import LyteWire
import LyteWireTestKit

// The transport: the extended-counter nonce (ROC reconstruction across
// the u16 wrap), the replay window, tamper rejection on both ciphertext
// and AAD, the byte budgets, and the rekey/epoch primitive with its
// receive-grace window. The pinned round trips in both directions live in
// noise-v1.json's transport vector.

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

    // MARK: Tamper

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
            assertThrows(NoiseError.authenticationFailure, "byte \(index)") {
                try freshHost.unseal(
                    wirePayload: tampered[...], aad: headerBytes[...], envelope: env
                )
            }
        }

        // AAD flip: the envelope header is authenticated even though it
        // rides in the clear.
        var tamperedAad = headerBytes
        tamperedAad[8] ^= 0x01  // a timestamp byte
        assertThrows(NoiseError.authenticationFailure) {
            try host.unseal(
                wirePayload: sealed[...], aad: tamperedAad[...], envelope: env
            )
        }

        // A forged seq in both envelope and AAD: the nonce moves with it,
        // so authentication still fails — a datagram cannot be replayed
        // into a different sequence slot.
        var shifted = env
        shifted.seq = ChannelSeq(rawValue: 6)
        let shiftedAad = try aad(shifted)
        assertThrows(NoiseError.authenticationFailure) {
            try host.unseal(
                wirePayload: sealed[...], aad: shiftedAad[...], envelope: shifted
            )
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

        // One byte over the 1112 B shard refuses.
        let overShard = counting(from: 0, count: WireBudget.maxPlaintextShardByteCount + 1)
        assertThrows(
            NoiseError.plaintextOverBudget(WireBudget.maxPlaintextShardByteCount + 1)
        ) {
            try client.seal(
                plaintext: overShard[...], aad: headerBytes[...],
                channel: env.channel, seq: ChannelSeq(rawValue: 1)
            )
        }

        // Unseal bounds: under one tag, and over the wire ceiling.
        assertThrows(NoiseError.wirePayloadOutOfBounds(15)) {
            try host.unseal(
                wirePayload: [UInt8](repeating: 0, count: 15)[...],
                aad: headerBytes[...], envelope: env
            )
        }
        let oversize = [UInt8](repeating: 0, count: WireBudget.maxWirePayloadByteCount + 1)
        assertThrows(
            NoiseError.wirePayloadOutOfBounds(WireBudget.maxWirePayloadByteCount + 1)
        ) {
            try host.unseal(
                wirePayload: oversize[...], aad: headerBytes[...], envelope: env
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
        assertThrows(NoiseError.sendSequenceNotMonotonic) {
            try client.seal(
                plaintext: [9, 9, 9][...], aad: headerBytes[...], envelope: env
            )
        }
        // And a seq behind the high-water mark likewise.
        assertThrows(NoiseError.sendSequenceNotMonotonic) {
            try client.seal(
                plaintext: [7][...], aad: headerBytes[...],
                channel: env.channel, seq: ChannelSeq(rawValue: 9)
            )
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
            assertThrows(NoiseError.replayedSequence) {
                try host.unseal(wirePayload: d.wire[...], aad: d.aad[...], envelope: d.env)
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

        assertThrows(NoiseError.staleSequence) {
            try host.unseal(wirePayload: held[...], aad: heldAad[...], envelope: heldEnv)
        }
    }

    // MARK: Long one-way gaps

    /// Seals `seq` values at the given extended counters (skipping ahead
    /// in sub-half-window steps, as a sender whose datagrams are lost
    /// does) and returns the sealed datagrams for the listed counters.
    private func sealAcross(
        _ client: inout NoiseTransport, through last: UInt64,
        keeping kept: Set<UInt64>
    ) throws -> [(env: Envelope, aad: [UInt8], wire: [UInt8])] {
        var out: [(env: Envelope, aad: [UInt8], wire: [UInt8])] = []
        var counter: UInt64 = 0
        while counter <= last {
            let env = envelope(seq: UInt16(truncatingIfNeeded: counter))
            let headerBytes = try aad(env)
            let wire = try client.seal(
                plaintext: [UInt8(truncatingIfNeeded: counter)][...],
                aad: headerBytes[...], envelope: env
            )
            if kept.contains(counter) { out.append((env, headerBytes, wire)) }
            let next = kept.filter { $0 > counter }.min() ?? last + 1
            counter = min(counter + 30_000, next)
        }
        return out
    }

    /// A receive gap of half the seq space or more must not kill the
    /// channel: after a bounded run of failures the receiver resyncs
    /// forward and every later datagram opens again.
    func testReceiverResyncsAfterLongOneWayGaps() throws {
        for gap: UInt64 in [40_000, 70_000, 200_000] {
            var (client, host) = try makeTransports()
            let resumed = (gap...(gap + 40)).map { $0 }
            let kept = Set([0] + resumed)
            let sealed = try sealAcross(&client, through: gap + 40, keeping: kept)
            XCTAssertEqual(sealed.count, kept.count)

            var opened: [UInt64] = []
            for (index, datagram) in sealed.enumerated() {
                if let plaintext = try? host.unseal(
                    wirePayload: datagram.wire[...], aad: datagram.aad[...],
                    envelope: datagram.env
                ) {
                    XCTAssertEqual(plaintext.count, 1)
                    opened.append(index == 0 ? 0 : resumed[index - 1])
                }
            }
            // Datagram 0, then at most the threshold's worth of losses
            // before resync; everything after it opens.
            let lost = kept.count - opened.count
            XCTAssertLessThanOrEqual(lost, 8, "gap \(gap)")
            XCTAssertEqual(opened.first, 0)
            XCTAssertEqual(
                Array(opened.dropFirst()), Array(resumed.suffix(opened.count - 1)),
                "gap \(gap): contiguous after resync"
            )
        }
    }

    /// Forged datagrams in the stuck state neither resync the receiver
    /// nor stop a genuine datagram from resyncing it afterwards.
    func testForgeriesNeverResyncTheReceiver() throws {
        var (client, host) = try makeTransports()
        let gap: UInt64 = 70_000
        let sealed = try sealAcross(
            &client, through: gap + 1, keeping: [0, gap, gap + 1]
        )
        _ = try host.unseal(
            wirePayload: sealed[0].wire[...], aad: sealed[0].aad[...],
            envelope: sealed[0].env
        )
        for _ in 0..<20 {
            var forged = sealed[1].wire
            forged[0] ^= 0x5A
            XCTAssertThrowsError(try host.unseal(
                wirePayload: forged[...], aad: sealed[1].aad[...],
                envelope: sealed[1].env
            ))
        }
        XCTAssertEqual(
            try host.unseal(
                wirePayload: sealed[1].wire[...], aad: sealed[1].aad[...],
                envelope: sealed[1].env
            ),
            [UInt8(truncatingIfNeeded: gap)]
        )
        XCTAssertEqual(
            try host.unseal(
                wirePayload: sealed[2].wire[...], aad: sealed[2].aad[...],
                envelope: sealed[2].env
            ),
            [UInt8(truncatingIfNeeded: gap + 1)]
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
}

// MARK: - Sealed datagrams

final class SealedDatagramTests: XCTestCase {

    private func makeTransports() throws -> (client: NoiseTransport, host: NoiseTransport) {
        let hostStatic = NoiseKeyPair.generate()
        var client = try NoiseSession(
            role: .initiator, staticKeys: NoiseKeyPair.generate(),
            remoteStaticPublicKey: hostStatic.publicKey
        )
        var host = try NoiseSession(role: .responder, staticKeys: hostStatic)
        _ = try host.readMessage1(try client.writeMessage1()[...])
        _ = try client.readMessage2(try host.writeMessage2()[...])
        return (try client.makeTransport(), try host.makeTransport())
    }

    private func envelope(seq: UInt16, tagged: Bool = true) -> Envelope {
        Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: seq),
            frame: FrameNumber(rawValue: 3), timestamp: 42, fec: 0,
            extensions: tagged
                ? [try! WireExtension(type: 0x01, value: [1, 2, 3, 4, 5, 6, 7, 8])]
                : []
        )
    }

    /// The datagram is header ‖ seal(plaintext, aad: header), byte for
    /// byte what the two-step encode produces, and it opens back to the
    /// same envelope and plaintext.
    func testSealedDatagramIsHeaderThenSealedPayloadAndRoundTrips() throws {
        // Two copies of one transport seal identically at the same seq.
        var clientA = try makeTransports().client
        var clientB = clientA
        for tagged in [false, true] {
            let env = envelope(seq: tagged ? 1 : 0, tagged: tagged)
            let plaintext: [UInt8] = Array(0..<200)
            let header = try env.encode(payload: [])
            let twoStep = try env.encode(payload: try clientB.seal(
                plaintext: plaintext[...], aad: header[...], envelope: env
            )[...])
            XCTAssertEqual(try clientA.sealDatagram(env, plaintext: plaintext), twoStep)
        }

        var (client, peer) = try makeTransports()
        let env = envelope(seq: 9)
        let datagram = try client.sealDatagram(env, plaintext: [7, 7, 7])
        let opened = try peer.openDatagram(datagram)
        XCTAssertEqual(opened.envelope, env)
        XCTAssertEqual(opened.plaintext, [7, 7, 7])
        // The header is authenticated: flip a header byte and it fails.
        var tampered = datagram
        tampered[8] ^= 1
        XCTAssertThrowsError(try peer.openDatagram(tampered))
        // Replays are the transport's verdict, passed through.
        assertThrows(NoiseError.replayedSequence) {
            try peer.openDatagram(datagram)
        }
    }

    /// Decode failures surface as WireError before any open runs, and
    /// the closure form sees the envelope first.
    func testOpenDatagramDecodesBeforeOpening() throws {
        var opens = 0
        assertThrows(WireError.truncatedEnvelope) {
            try Envelope.openDatagram([1, 2, 3][...]) { _, _, _ in
                opens += 1
                return []
            }
        }
        let env = envelope(seq: 1)
        let passthrough = try env.sealedDatagram([9, 8][...]) { plaintext, _ in
            Array(plaintext)
        }
        let opened = try Envelope.openDatagram(passthrough[...]) { seen, payload, aad in
            opens += 1
            XCTAssertEqual(seen, env)
            XCTAssertEqual(Array(aad), try env.encode(payload: []))
            return Array(payload)
        }
        XCTAssertEqual(opened.plaintext, [9, 8])
        XCTAssertEqual(opens, 1)
    }

    /// Budgets hold on the assembled datagram.
    func testSealedDatagramEnforcesBudgets() {
        let env = envelope(seq: 1)
        assertThrows(
            WireError.payloadOverBudget(WireBudget.maxWirePayloadByteCount + 1)
        ) {
            try env.sealedDatagram([0][...]) { _, _ in
                [UInt8](repeating: 0, count: WireBudget.maxWirePayloadByteCount + 1)
            }
        }
    }
}
