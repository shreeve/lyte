import XCTest
import LyteWire
import LyteWireTestKit

// The transport: the extended-counter nonce (ROC reconstruction across
// the u16 wrap), the replay window, tamper rejection on both ciphertext
// and AAD, the byte budgets, and the rekey/epoch primitive with its
// receive-grace window. The pinned round trips in both directions live in
// noise-v1.json's transport vector.

final class NoiseTransportTests: XCTestCase {

    /// One datagram's envelope, its header bytes (the AAD), and the
    /// sealed wire payload.
    private struct Sealed {
        var env: Envelope
        var aad: [UInt8]
        var wire: [UInt8]
    }

    private func counting(from offset: Int, count: Int) -> [UInt8] {
        (0..<count).map { UInt8((offset + $0) & 0xFF) }
    }

    private func envelope(seq: UInt16) -> Envelope {
        Envelope(
            channel: ChannelId(rawValue: 2),
            seq: ChannelSeq(rawValue: seq),
            frame: FrameNumber(rawValue: 1),
            timestamp: 1_000_000,
            fec: 0
        )
    }

    private func seal(
        _ transport: inout NoiseTransport, seq: UInt16, _ plaintext: [UInt8]
    ) throws -> Sealed {
        let env = envelope(seq: seq)
        let aad = try env.encode(payload: [])
        return Sealed(env: env, aad: aad, wire: try transport.seal(
            plaintext: plaintext[...], aad: aad[...], envelope: env
        ))
    }

    private func open(
        _ transport: inout NoiseTransport, _ sealed: Sealed
    ) throws -> [UInt8] {
        try transport.unseal(
            wirePayload: sealed.wire[...], aad: sealed.aad[...],
            envelope: sealed.env
        )
    }

    // MARK: Tamper

    func testTamperedCiphertextTagAndAadFail() throws {
        var (client, host) = try NoisePair.transports()
        let plaintext = counting(from: 0, count: 100)
        let sealed = try seal(&client, seq: 5, plaintext)
        let count = sealed.wire.count

        // Ciphertext and tag bit flips.
        for index in [0, count - 17, count - 16, count - 1] {
            var tampered = sealed
            tampered.wire[index] ^= 0x01
            assertThrows(NoiseError.authenticationFailure, "byte \(index)") {
                try open(&host, tampered)
            }
        }

        // AAD flip: the envelope header is authenticated even though it
        // rides in the clear.
        var tamperedAad = sealed
        tamperedAad.aad[8] ^= 0x01  // a timestamp byte
        assertThrows(NoiseError.authenticationFailure) {
            try open(&host, tamperedAad)
        }

        // A forged seq in both envelope and AAD: the nonce moves with it,
        // so authentication still fails — a datagram cannot be replayed
        // into a different sequence slot.
        var shifted = sealed
        shifted.env.seq = ChannelSeq(rawValue: 6)
        shifted.aad = try shifted.env.encode(payload: [])
        assertThrows(NoiseError.authenticationFailure) {
            try open(&host, shifted)
        }

        // The genuine datagram still opens: no failure committed state.
        XCTAssertEqual(try open(&host, sealed), plaintext)
    }

    // MARK: Budgets

    func testBudgetsEnforced() throws {
        var (client, host) = try NoisePair.transports()

        let over = WireBudget.maxPlaintextShardByteCount + 1
        assertThrows(NoiseError.plaintextOverBudget(over)) {
            try seal(&client, seq: 0, counting(from: 0, count: over))
        }

        // Unseal bounds: under one tag, and over the wire ceiling.
        let env = envelope(seq: 0)
        let aad = try env.encode(payload: [])
        for count in [15, WireBudget.maxWirePayloadByteCount + 1] {
            assertThrows(NoiseError.wirePayloadOutOfBounds(count)) {
                try host.unseal(
                    wirePayload: [UInt8](repeating: 0, count: count)[...],
                    aad: aad[...], envelope: env
                )
            }
        }
    }

    // MARK: ROC across the u16 wrap

    func testRocReconstructionAcrossSeqWrap() throws {
        var (client, host) = try NoisePair.transports()

        // Walk the sender straight through the wrap; deliver everything.
        let seqs: [UInt16] = [65533, 65534, 65535, 0, 1, 2]
        let sealed = try seqs.enumerated().map { index, seq in
            try seal(&client, seq: seq, counting(from: index, count: 32))
        }
        // Deliver out of order across the wrap boundary: 65533, 65535,
        // 65534, 0, 2, 1 — reorder inside the window is admitted, and the
        // extended counter (not the raw seq) picks the right nonce.
        for index in [0, 2, 1, 3, 5, 4] {
            XCTAssertEqual(
                try open(&host, sealed[index]), counting(from: index, count: 32),
                "delivery of seq \(seqs[index])"
            )
        }
    }

    func testSenderRefusesNonMonotonicSeq() throws {
        var (client, _) = try NoisePair.transports()
        _ = try seal(&client, seq: 10, [1, 2, 3])
        // Same seq again — deterministic re-seal is refused; a retransmit
        // resends the already-sealed bytes.
        assertThrows(NoiseError.sendSequenceNotMonotonic) {
            try seal(&client, seq: 10, [9, 9, 9])
        }
        // And a seq behind the high-water mark likewise.
        let aad = try envelope(seq: 9).encode(payload: [])
        assertThrows(NoiseError.sendSequenceNotMonotonic) {
            try client.seal(
                plaintext: [7][...], aad: aad[...],
                channel: ChannelId(rawValue: 2), seq: ChannelSeq(rawValue: 9)
            )
        }
    }

    // MARK: Replay and staleness

    func testReplayRejectedOutOfOrderAdmitted() throws {
        var (client, host) = try NoisePair.transports()
        let sealed = try (0..<5).map {
            try seal(&client, seq: UInt16($0), counting(from: $0, count: 10))
        }

        // In-window reorder: 0, 2, 4, then the stragglers 1 and 3.
        for index in [0, 2, 4, 1, 3] {
            XCTAssertEqual(
                try open(&host, sealed[index]), counting(from: index, count: 10)
            )
        }
        // Every replay — the byte-identical retransmit that lost the
        // race — rejects as replayedSequence, exactly once admitted.
        for datagram in sealed {
            assertThrows(NoiseError.replayedSequence) {
                try open(&host, datagram)
            }
        }
    }

    func testStaleSequenceBeyondWindowRejected() throws {
        var (client, host) = try NoisePair.transports()

        // Seal seq 0, hold it back, advance the channel far past the
        // 64-deep window, then deliver the straggler.
        let held = try seal(&client, seq: 0, [1])
        for seq: UInt16 in 1...80 {
            _ = try open(&host, try seal(&client, seq: seq, [2]))
        }
        assertThrows(NoiseError.staleSequence) { try open(&host, held) }
    }

    // MARK: Long one-way gaps

    /// Seals `seq` values at the given extended counters (skipping ahead
    /// in sub-half-window steps, as a sender whose datagrams are lost
    /// does) and returns the sealed datagrams for the listed counters.
    private func sealAcross(
        _ client: inout NoiseTransport, through last: UInt64,
        keeping kept: Set<UInt64>
    ) throws -> [Sealed] {
        var out: [Sealed] = []
        var counter: UInt64 = 0
        while counter <= last {
            let sealed = try seal(
                &client, seq: UInt16(truncatingIfNeeded: counter),
                [UInt8(truncatingIfNeeded: counter)]
            )
            if kept.contains(counter) { out.append(sealed) }
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
            var (client, host) = try NoisePair.transports()
            let resumed = (gap...(gap + 40)).map { $0 }
            let kept = Set([0] + resumed)
            let sealed = try sealAcross(&client, through: gap + 40, keeping: kept)
            XCTAssertEqual(sealed.count, kept.count)

            var opened: [UInt64] = []
            for (index, datagram) in sealed.enumerated() {
                if let plaintext = try? open(&host, datagram) {
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
        var (client, host) = try NoisePair.transports()
        let gap: UInt64 = 70_000
        let sealed = try sealAcross(
            &client, through: gap + 1, keeping: [0, gap, gap + 1]
        )
        _ = try open(&host, sealed[0])
        for _ in 0..<20 {
            var forged = sealed[1]
            forged.wire[0] ^= 0x5A
            XCTAssertThrowsError(try open(&host, forged))
        }
        XCTAssertEqual(try open(&host, sealed[1]), [UInt8(truncatingIfNeeded: gap)])
        XCTAssertEqual(try open(&host, sealed[2]), [UInt8(truncatingIfNeeded: gap + 1)])
    }

    // MARK: Rekey

    func testRekeyChangesKeyAndGraceWindowCoversInFlight() throws {
        var (client, host) = try NoisePair.transports()

        // A datagram sealed before the rekey but delivered after it.
        let inFlight = try seal(&client, seq: 0, Array("in flight".utf8))

        try client.rekeySend()
        try host.rekeyReceive()
        XCTAssertEqual(client.sendEpoch, 1)
        XCTAssertEqual(host.receiveEpoch, 1)

        // Post-rekey traffic flows on the new epoch key…
        let post = try seal(&client, seq: 1, Array("post rekey".utf8))
        XCTAssertEqual(try open(&host, post), Array("post rekey".utf8))
        // …and the in-flight datagram still opens via the grace key.
        XCTAssertEqual(try open(&host, inFlight), Array("in flight".utf8))
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
            try NoisePair.complete(&client, &host)
            return try client.makeTransport()
        }

        var plain = try makeClientTransport()
        var rekeyed = try makeClientTransport()
        try rekeyed.rekeySend()
        let plaintext = Array("same slot".utf8)
        XCTAssertNotEqual(
            try seal(&plain, seq: 0, plaintext).wire,
            try seal(&rekeyed, seq: 0, plaintext).wire
        )
    }
}

// MARK: - Sealed datagrams

final class SealedDatagramTests: XCTestCase {

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
        var clientA = try NoisePair.transports().client
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

        var (client, peer) = try NoisePair.transports()
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
