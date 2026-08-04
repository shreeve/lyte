import XCTest
import LyteClientTestKit
import Foundation
import LyteTransport
import LyteWire
import LyteWireTestKit

// THE GATE (build plan CL-9 row, the in-tree half — the live leg runs
// against the reference host): the client input sender. Pinned:
//
//   • the 0x16/0x17/TLV-0x03 mirrors are byte-pinned against the SAME
//     hand-built layouts the host's InputGateTests pin (mirror-then-
//     promote: both copies move to Wire/ together, bytes unchanged) and
//     never trap on hostile bytes;
//   • the latency math is EXACT in a deterministic unit: a known clock
//     offset, a scripted echo, and a stamped delivery produce the
//     precise input→inject / input→photon / host receive→inject edges;
//   • the full loop runs through the REAL production core (Noise dial,
//     sealed ARQ CTRL, demux, pipeline) against a scripted LyteWire
//     host peer over the W-G4 SimNet storm: 40 events of all five
//     kinds arrive exactly once IN ORDER byte-faithful, 40 echo tuples
//     return, the stamped video frame closes every photon loop, and
//     the sender's books balance;
//   • MacEvdevKeyMap speaks evdev position codes (spot-pinned) — the
//     host's XKB map owns layout.

final class InputPathGateTests: XCTestCase {

    // MARK: - Corpus

    private static var corpusDirectory: String {
        ClientTestPaths.videoCorpus
    }

    private func loadCorpus(_ count: Int) throws -> [[UInt8]] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: Self.corpusDirectory)
            .filter { $0.hasPrefix("frame-0") && $0.hasSuffix(".annexb") }
            .sorted()
            .prefix(count)
        return try names.map {
            [UInt8](try Data(contentsOf: URL(
                fileURLWithPath: Self.corpusDirectory + "/" + $0)))
        }
    }

    // MARK: - Codec pins (the host InputGateTests layouts, verbatim)

    func testInputEventCodecPinsBytesAgainstHostLayout() throws {
        // keyKeycode: KEY_A (30) pressed, seq 7, client µs 0x1122334455.
        let key = InputEvent(
            seq: 7, clientMicroseconds: 0x11_2233_4455,
            body: .keyKeycode(keycode: 30, pressed: true)
        )
        XCTAssertEqual(key.encode(), [
            0x16,                                   // type
            7, 0, 0, 0,                             // seq u32 LE
            0x55, 0x44, 0x33, 0x22, 0x11, 0, 0, 0,  // clientMicros u64 LE
            0x01,                                   // kind keyKeycode
            30, 0, 0, 0,                            // keycode u32 LE
            1,                                      // pressed
        ])
        XCTAssertEqual(try InputEvent.decode(key.encode()), key)

        // pointerMotionAbsolute: f64 bit patterns, LE.
        let move = InputEvent(
            seq: 8, clientMicroseconds: 2,
            body: .pointerMotionAbsolute(x: 512.0, y: 320.25)
        )
        var expected: [UInt8] = [0x16, 8, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0x02]
        for value in [512.0, 320.25] {
            let bits = value.bitPattern
            for shift in stride(from: 0, to: 64, by: 8) {
                expected.append(UInt8(truncatingIfNeeded: bits >> shift))
            }
        }
        XCTAssertEqual(move.encode(), expected)
        XCTAssertEqual(try InputEvent.decode(move.encode()), move)

        // The remaining kinds round-trip.
        for body: InputEvent.Body in [
            .pointerMotionRelative(dx: -3.5, dy: 12.0),
            .pointerButton(button: 0x110, pressed: false),
            .pointerAxis(dx: 0, dy: -45.0, finish: true),
        ] {
            let event = InputEvent(seq: 99, clientMicroseconds: 1_000, body: body)
            XCTAssertEqual(try InputEvent.decode(event.encode()), event)
        }

        // Echo: two tuples, hand-built layout.
        let echo = InputEcho(tuples: [
            InputEchoTuple(seq: 1, receivedMicroseconds: 0x0A,
                           injectedMicroseconds: 0x0B),
            InputEchoTuple(seq: 2, receivedMicroseconds: 0x0C,
                           injectedMicroseconds: 0x0D),
        ])
        XCTAssertEqual(echo.encode(), [
            0x17, 2,
            1, 0, 0, 0,
            0x0A, 0, 0, 0, 0, 0, 0, 0,
            0x0B, 0, 0, 0, 0, 0, 0, 0,
            2, 0, 0, 0,
            0x0C, 0, 0, 0, 0, 0, 0, 0,
            0x0D, 0, 0, 0, 0, 0, 0, 0,
        ])
        XCTAssertEqual(try InputEcho.decode(echo.encode()), echo)
    }

    func testHostileInputBytesRejectAndNeverTrap() throws {
        let good = InputEvent(
            seq: 1, clientMicroseconds: 2,
            body: .keyKeycode(keycode: 30, pressed: true)
        ).encode()

        // Truncations at every length below the minimum.
        for length in 0..<good.count {
            XCTAssertThrowsError(
                try InputEvent.decode(Array(good.prefix(length))),
                "truncation to \(length) bytes must reject"
            )
        }
        // Foreign type byte.
        XCTAssertThrowsError(try InputEvent.decode([0x15] + good.dropFirst()))
        // Unknown kind.
        var badKind = good
        badKind[13] = 0x77
        XCTAssertThrowsError(try InputEvent.decode(badKind))
        // Trailing junk (body length disagrees with the kind).
        XCTAssertThrowsError(try InputEvent.decode(good + [0x00]))
        // A flag byte that is neither 0 nor 1.
        var badFlag = good
        badFlag[18] = 2
        XCTAssertThrowsError(try InputEvent.decode(badFlag))
        // Reserved axis-flag bits.
        var axis = InputEvent(
            seq: 1, clientMicroseconds: 2,
            body: .pointerAxis(dx: 1, dy: 2, finish: false)
        ).encode()
        axis[axis.count - 1] = 0x82
        XCTAssertThrowsError(try InputEvent.decode(axis))

        // Echo: count 0, count/length mismatch, over-limit count.
        XCTAssertThrowsError(try InputEcho.decode([0x17, 0]))
        XCTAssertThrowsError(try InputEcho.decode([0x17, 1, 1, 2, 3]))
        XCTAssertThrowsError(try InputEcho.decode(
            [0x17, 33] + [UInt8](repeating: 0, count: 33 * 20)
        ))

        // The TLV: duplicate and malformed value.
        let tlv = LastInputSeqTlv.wireExtension(seq: 5)
        XCTAssertEqual(try LastInputSeqTlv.decode(extensions: [tlv]), 5)
        XCTAssertThrowsError(
            try LastInputSeqTlv.decode(extensions: [tlv, tlv])
        )
        XCTAssertThrowsError(try LastInputSeqTlv.decode(
            extensions: [try WireExtension(
                type: WireExtension.ReservedType.lastInputSeq, value: [1, 2]
            )]
        ))
        XCTAssertNil(try LastInputSeqTlv.decode(extensions: []))
    }

    // MARK: - The keymap speaks evdev position codes

    func testMacEvdevKeyMapPins() {
        // Letters, editing, navigation, function — evdev
        // input-event-codes.h values, spot-pinned.
        XCTAssertEqual(MacEvdevKeyMap.evdevKeycode(forMacKeyCode: 0x00), 30)   // A
        XCTAssertEqual(MacEvdevKeyMap.evdevKeycode(forMacKeyCode: 0x06), 44)   // Z
        XCTAssertEqual(MacEvdevKeyMap.evdevKeycode(forMacKeyCode: 0x24), 28)   // Return → KEY_ENTER
        XCTAssertEqual(MacEvdevKeyMap.evdevKeycode(forMacKeyCode: 0x31), 57)   // Space
        XCTAssertEqual(MacEvdevKeyMap.evdevKeycode(forMacKeyCode: 0x35), 1)    // Escape
        XCTAssertEqual(MacEvdevKeyMap.evdevKeycode(forMacKeyCode: 0x7E), 103)  // Up
        XCTAssertEqual(MacEvdevKeyMap.evdevKeycode(forMacKeyCode: 0x69), 183)  // F13
        XCTAssertNil(MacEvdevKeyMap.evdevKeycode(forMacKeyCode: 0x3F))         // Fn: unmapped

        // Left/right modifiers are DISTINCT evdev codes.
        XCTAssertEqual(MacEvdevKeyMap.modifierKeys[0x38]?.evdev, 42)   // KEY_LEFTSHIFT
        XCTAssertEqual(MacEvdevKeyMap.modifierKeys[0x3C]?.evdev, 54)   // KEY_RIGHTSHIFT
        XCTAssertEqual(MacEvdevKeyMap.modifierKeys[0x37]?.evdev, 125)  // KEY_LEFTMETA

        // Buttons are evdev BTN_*.
        XCTAssertEqual(MacEvdevKeyMap.evdevButton(forMacButtonNumber: 0), 0x110)
        XCTAssertEqual(MacEvdevKeyMap.evdevButton(forMacButtonNumber: 1), 0x111)
        XCTAssertEqual(MacEvdevKeyMap.evdevButton(forMacButtonNumber: 2), 0x112)
        XCTAssertNil(MacEvdevKeyMap.evdevButton(forMacButtonNumber: 9))
    }

    // MARK: - Deterministic latency math

    func testInputSenderLatencyMathIsExact() throws {
        // A clock model with a KNOWN fit: offset (client − host) is
        // exactly +500 000 µs, zero skew (three identical-rtt samples).
        let clock = HostClockModel()
        for (t, seq) in [(UInt64(100_000), UInt32(0)),
                         (UInt64(200_000), UInt32(1)),
                         (UInt64(300_000), UInt32(2))] {
            clock.ingest(ClockSample(
                beaconSeq: seq,
                offsetMicroseconds: 500_000,
                rttMicroseconds: 8_000,
                measuredAt: ClientTimestamp(microseconds: t)))
        }

        var sent: [[UInt8]] = []
        let sender = InputSender(clockModel: clock) { message, _ in
            sent.append(message)
        }

        // seq 0 at client t = 1 000 000.
        let seq = try sender.send(
            .keyKeycode(keycode: 30, pressed: true),
            now: ClientTimestamp(microseconds: 1_000_000))
        XCTAssertEqual(seq, 0)
        XCTAssertEqual(sent.count, 1)
        let onWire = try InputEvent.decode(sent[0])
        XCTAssertEqual(onWire.seq, 0)
        XCTAssertEqual(onWire.clientMicroseconds, 1_000_000)

        // The echo: host rx 600 000 / inject 601 500 (host µs). Mapped
        // through the +500 000 fit, inject = client 1 101 500 — so
        // input→inject is EXACTLY 101 500 µs and the host's own
        // receive→inject edge is EXACTLY 1 500 µs.
        sender.handleEcho(
            InputEcho(tuples: [InputEchoTuple(
                seq: 0,
                receivedMicroseconds: 600_000,
                injectedMicroseconds: 601_500)]),
            now: ClientTimestamp(microseconds: 1_012_000))
        var stats = sender.snapshotStats()
        XCTAssertEqual(stats.echoTuplesReceived, 1)
        XCTAssertEqual(stats.inputToInject.count, 1)
        XCTAssertEqual(stats.inputToInject.p50, 101_500)
        XCTAssertEqual(stats.hostReceiveToInject.p50, 1_500)
        XCTAssertEqual(sender.pendingEchoCount, 0)

        // The stamped frame: shard TLV says frame 9's capture followed
        // seq 0's injection; delivery at client 1 200 000 closes the
        // photon loop at EXACTLY 200 000 µs.
        var envelope = Envelope(
            channel: .videoActive,
            seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 9),
            timestamp: 0,
            fec: 0)
        envelope.extensions.append(LastInputSeqTlv.wireExtension(seq: 0))
        sender.noteVideoShard(envelope: envelope)
        sender.noteFrameDelivered(
            frame: FrameNumber(rawValue: 9),
            now: ClientTimestamp(microseconds: 1_200_000))
        stats = sender.snapshotStats()
        XCTAssertEqual(stats.inputToPhoton.count, 1)
        XCTAssertEqual(stats.inputToPhoton.p50, 200_000)
        XCTAssertEqual(stats.lastStampSeen, 0)

        // A second delivery of the same frame closes nothing twice.
        sender.noteFrameDelivered(
            frame: FrameNumber(rawValue: 9),
            now: ClientTimestamp(microseconds: 1_300_000))
        XCTAssertEqual(sender.snapshotStats().inputToPhoton.count, 1)

        // Books stay honest while the path is live: an unmatched echo
        // counts, a duplicate stamp TLV counts, neither throws. (A
        // fresh event re-arms the pending books first — with nothing
        // pending, noteVideoShard's fast-out skips the decode
        // entirely; that skip has its own pin below.)
        _ = try sender.send(
            .keyKeycode(keycode: 30, pressed: false),
            now: ClientTimestamp(microseconds: 1_350_000))
        sender.handleEcho(
            InputEcho(tuples: [InputEchoTuple(
                seq: 77, receivedMicroseconds: 1, injectedMicroseconds: 2)]),
            now: ClientTimestamp(microseconds: 1_400_000))
        var hostile = Envelope(
            channel: .videoActive,
            seq: ChannelSeq(rawValue: 1),
            frame: FrameNumber(rawValue: 10),
            timestamp: 0,
            fec: 0)
        hostile.extensions.append(LastInputSeqTlv.wireExtension(seq: 1))
        hostile.extensions.append(LastInputSeqTlv.wireExtension(seq: 2))
        sender.noteVideoShard(envelope: hostile)
        stats = sender.snapshotStats()
        XCTAssertEqual(stats.unmatchedEchoTuples, 1)
        XCTAssertEqual(stats.malformedFrameStamps, 1)
    }

    func testNoteVideoShardSkipsEntirelyWhileNoInputPends() throws {
        // The receive thread's fast-out: with both pending books empty
        // (fresh sender, or every event echoed AND photon-closed), a
        // video shard's stamp TLV is not even decoded — no book entry,
        // no malformed count. The moment an event pends, the path is
        // fully live again (the frame stamp records and closes the
        // photon loop as ever).
        let sender = InputSender(clockModel: HostClockModel()) { _, _ in }

        var hostile = Envelope(
            channel: .videoActive,
            seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 1),
            timestamp: 0,
            fec: 0)
        hostile.extensions.append(LastInputSeqTlv.wireExtension(seq: 1))
        hostile.extensions.append(LastInputSeqTlv.wireExtension(seq: 2))
        sender.noteVideoShard(envelope: hostile)
        XCTAssertEqual(sender.snapshotStats().malformedFrameStamps, 0,
                       "no pending input — the TLV must not even decode")

        // An event pends: the same hostile shard now counts, and a
        // well-formed stamp closes the photon loop exactly as before.
        _ = try sender.send(
            .keyKeycode(keycode: 30, pressed: true),
            now: ClientTimestamp(microseconds: 1_000_000))
        sender.noteVideoShard(envelope: hostile)
        XCTAssertEqual(sender.snapshotStats().malformedFrameStamps, 1)

        var stamped = Envelope(
            channel: .videoActive,
            seq: ChannelSeq(rawValue: 1),
            frame: FrameNumber(rawValue: 2),
            timestamp: 0,
            fec: 0)
        stamped.extensions.append(LastInputSeqTlv.wireExtension(seq: 0))
        sender.noteVideoShard(envelope: stamped)
        sender.noteFrameDelivered(
            frame: FrameNumber(rawValue: 2),
            now: ClientTimestamp(microseconds: 1_250_000))
        let stats = sender.snapshotStats()
        XCTAssertEqual(stats.inputToPhoton.count, 1)
        XCTAssertEqual(stats.inputToPhoton.p50, 250_000)
    }

    func testInputSenderWithoutClockFitStillRecordsHostEdge() throws {
        let sender = InputSender(clockModel: HostClockModel()) { _, _ in }
        _ = try sender.send(
            .pointerMotionAbsolute(x: 1, y: 2),
            now: ClientTimestamp(microseconds: 10))
        sender.handleEcho(
            InputEcho(tuples: [InputEchoTuple(
                seq: 0, receivedMicroseconds: 100,
                injectedMicroseconds: 350)]),
            now: ClientTimestamp(microseconds: 20))
        let stats = sender.snapshotStats()
        XCTAssertEqual(stats.echoesWithoutClockFit, 1)
        XCTAssertEqual(stats.inputToInject.count, 0)
        XCTAssertEqual(stats.hostReceiveToInject.p50, 250)
    }

    func testOrderedInputSenderPreservesOrderAndStopsQueuedWork() {
        let delivered = UInt32Pile()
        let sender = OrderedInputSender { body, _ in
            guard case .keyKeycode(let code, _) = body else { return }
            delivered.append(code)
        }
        for code: UInt32 in 0..<100 {
            sender.enqueue(
                .keyKeycode(keycode: code, pressed: true),
                capturedNanoseconds: UInt64(code + 1) * 1_000)
        }
        sender.drainForTesting()
        XCTAssertEqual(delivered.all, Array(0..<100))
        XCTAssertEqual(sender.snapshot.queued, 100)
        XCTAssertEqual(sender.snapshot.sent, 100)

        sender.stop()
        sender.enqueue(
            .keyKeycode(keycode: 999, pressed: true),
            capturedNanoseconds: 999_000)
        sender.drainForTesting()
        XCTAssertEqual(delivered.all.count, 100)
    }

    func testOrderedInputAcceptanceRacesFinishWithoutLosingAcceptedWork() {
        let delivered = UInt32Pile()
        let accepted = UInt32Pile()
        let sender = OrderedInputSender { body, _ in
            guard case .keyKeycode(let code, _) = body else { return }
            delivered.append(code)
        }
        let group = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        for code: UInt32 in 0..<500 {
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                if sender.enqueue(
                    .keyKeycode(keycode: code, pressed: true),
                    capturedNanoseconds: UInt64(code + 1) * 1_000
                ) {
                    accepted.append(code)
                }
                group.leave()
            }
        }
        for _ in 0..<500 { start.signal() }
        sender.finishAndDrain()
        group.wait()
        sender.drainForTesting()

        XCTAssertEqual(Set(delivered.all), Set(accepted.all))
        XCTAssertEqual(delivered.all.count, accepted.all.count)
        XCTAssertEqual(
            sender.snapshot.sent, UInt64(accepted.all.count),
            "every event admitted before the finish gate must drain")
        XCTAssertFalse(sender.enqueue(
            .keyKeycode(keycode: 999, pressed: true)))
    }

    // MARK: - The host stand-in (HS-13's Session discipline from Wire parts)

    /// Noise responder + host-clock ARQ + the HS-13 input arm: consumes
    /// 0x16 from the ordered stream, "injects" after a fixed synthetic
    /// delay, buffers echo tuples flushed as 0x17 on advance (≤ 32 per
    /// message), moves the lastInputSeq stamp, and packetizes video at
    /// the STAMPED shard budget (the HS-13 geometry-honesty rule) so
    /// every datagram fits 1152 B with the TLV aboard.
    private final class HostInputStandIn: NoiseHandshakeIO {
        let staticKeys = NoiseKeyPair.generate()
        let connectionId: ConnectionId
        var transport: NoiseTransport?
        var ctrlSeq: UInt16 = 0
        var videoSeq = ChannelSeq(rawValue: 0)
        var arq: ArqEndpoint<HostClock>
        private var handshakeOutbox: [[UInt8]] = []

        /// Synthetic receive→inject delay, host µs — the deterministic
        /// figure the client's hostReceiveToInject histogram must
        /// reproduce exactly.
        static let injectDelayMicroseconds: UInt64 = 1_300

        // Evidence the gate asserts against.
        var receivedEvents: [InputEvent] = []
        var declarationsSeen = 0
        var idrRequestsSeen = 0
        var lastInputSeq: UInt32?
        var pendingEchoes: [InputEchoTuple] = []
        var echoTuplesSent = 0

        // The beacon mirror (the real CL-10 loop: beacon → echo →
        // mirrored t3/t4 on the next beacon → client clock sample).
        var beaconSeq: UInt32 = 0
        var lastBeaconAt: UInt64 = 0
        var pendingMirror: ClockBeacon.LastEcho?

        init() {
            var rng = SplitMix64(seed: 0xC1_09)
            connectionId = ConnectionId.random(using: &rng)
            var config = ArqConfig()
            config.maxDatagramPayloadByteCount =
                WireBudget.maxConnectionIdTaggedPlaintextByteCount
            arq = ArqEndpoint(channel: .ctrl, config: config)
        }

        // NoiseHandshakeIO — answered in-process.

        func sendToHost(_ datagram: [UInt8]) throws {
            guard let (envelope, payload) = try? Envelope.decode(datagram[...]),
                  envelope.channel == .ctrl,
                  payload.first == CtrlMessageType.noiseHandshake1
            else { return }
            var responder = try NoiseSession(
                role: .responder, staticKeys: staticKeys)
            _ = try responder.readMessage1(payload.dropFirst())
            let message2 = try responder.writeMessage2()
            transport = try responder.makeTransport()
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

        // The established send path (the CL-8 stand-in's, verbatim).

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
            let datagram = try envelope.encode(payload: payload)
            XCTAssertLessThanOrEqual(
                datagram.count, WireBudget.maxDatagramByteCount)
            return datagram
        }

        /// One client datagram: unseal → route. Input events "inject"
        /// after the fixed synthetic delay; echoes buffer for advance.
        func absorb(_ bytes: [UInt8], hostMicros: UInt64) throws {
            let (envelope, payload) = try Envelope.decode(bytes)
            let aad = bytes[bytes.startIndex..<payload.startIndex]
            let plaintext: [UInt8]
            do {
                plaintext = try transport!.unseal(
                    wirePayload: payload, aad: aad, envelope: envelope
                )
            } catch NoiseError.replayedSequence, NoiseError.staleSequence {
                return // network duplicate; routine
            }
            guard envelope.channel == .ctrl else { return }
            switch plaintext.first {
            case CtrlMessageType.arqSegment, CtrlMessageType.arqAck:
                for event in arq.ingest(
                    payload: plaintext,
                    now: HostTimestamp(microseconds: hostMicros)
                ) {
                    guard case .message(_, let message) = event else { continue }
                    dispatchReliable(message, hostMicros: hostMicros)
                }
            case CtrlMessageType.beaconEcho:
                // The mirror's food: t3 echoed verbatim, t4 measured
                // here — rides the NEXT beacon (W4a's lastEcho rule).
                if let echo = try? BeaconEcho.decode(plaintext) {
                    pendingMirror = ClockBeacon.LastEcho(
                        beaconSeq: echo.beaconSeq,
                        clientSend: echo.clientSend,
                        hostReceive: HostTimestamp(microseconds: hostMicros))
                }
            case CtrlMessageType.idrRequest:
                idrRequestsSeen += 1
            default:
                XCTFail("unexpected client CTRL type \(plaintext.first ?? 0)")
            }
        }

        private func dispatchReliable(_ message: [UInt8], hostMicros: UInt64) {
            switch message.first {
            case CtrlMessageType.capabilityDeclaration:
                declarationsSeen += 1
            case CtrlMessageType.inputEvent:
                guard let event = try? InputEvent.decode(message) else {
                    return XCTFail("malformed input event reached the host")
                }
                receivedEvents.append(event)
                // The HS-13 shell: inject, then noteInputInjected —
                // the stamp moves and one echo tuple buffers.
                lastInputSeq = event.seq
                pendingEchoes.append(InputEchoTuple(
                    seq: event.seq,
                    receivedMicroseconds: hostMicros,
                    injectedMicroseconds: hostMicros
                        &+ Self.injectDelayMicroseconds))
            default:
                XCTFail("unexpected reliable type \(message.first ?? 0)")
            }
        }

        /// One host beat: pending echoes onto the reliable stream
        /// (≤ 32 per 0x17 — the flushInputEchoes rule), the 1 Hz
        /// mirrored beacon, and the ARQ's due output.
        func advance(hostMicros: UInt64) throws -> [[UInt8]] {
            guard transport != nil else { return [] }
            var out: [[UInt8]] = []
            while !pendingEchoes.isEmpty {
                let batch = Array(pendingEchoes.prefix(InputEcho.maxTupleCount))
                try arq.send(
                    message: InputEcho(tuples: batch).encode(),
                    now: HostTimestamp(microseconds: hostMicros))
                pendingEchoes.removeFirst(batch.count)
                echoTuplesSent += batch.count
            }
            if lastBeaconAt == 0 || hostMicros - lastBeaconAt >= 1_000_000 {
                lastBeaconAt = hostMicros
                let beacon = ClockBeacon(
                    beaconSeq: beaconSeq,
                    hostSend: HostTimestamp(microseconds: hostMicros),
                    lastEcho: pendingMirror
                )
                beaconSeq &+= 1
                out.append(try sealedCtrl(
                    body: beacon.encode(), hostMicros: hostMicros))
            }
            let (payloads, _) = arq.poll(
                now: HostTimestamp(microseconds: hostMicros))
            for payload in payloads {
                out.append(try sealedCtrl(
                    body: payload, hostMicros: hostMicros))
            }
            return out
        }

        /// Video at the STAMPED budget: when lastInputSeq is set, every
        /// shard carries TLV 0x03 and the geometry derives from the
        /// correspondingly smaller shard ceiling (the HS-13 VideoChannel
        /// rule, mirrored from LyteWire parts) — so the sealed datagram
        /// NEVER bursts 1152 B, asserted per datagram.
        func videoDatagrams(
            annexB: [UInt8], frameNumber: UInt32, hostMicros: UInt64
        ) throws -> [[UInt8]] {
            let stamp = lastInputSeq
            let tlvBlock = stamp == nil
                ? 0 : 1 + LastInputSeqTlv.encodedByteCount
            let budget = min(
                WireBudget.maxPlaintextShardByteCount,
                WireBudget.maxWirePayloadByteCount
                    - WireBudget.aeadTagByteCount
                    - tlvBlock
            )
            let k = (annexB.count + budget - 1) / budget
            let m = try FecGeometryTable.parityShards(
                forDataShards: k, regime: .clean)
            let geometry = try FecGeometry(
                dataShards: k, parityShards: m, groupByteCount: annexB.count)
            let payloads = try FecEncoder.encode(
                group: annexB[...], geometry: geometry)

            var out: [[UInt8]] = []
            for (index, payload) in payloads.enumerated() {
                let field = try FecField.reedSolomonShard(index, of: geometry)
                var envelope = Envelope(
                    channel: .videoActive,
                    seq: videoSeq,
                    frame: FrameNumber(rawValue: frameNumber),
                    timestamp: hostMicros,
                    fec: field.encoded
                )
                if let stamp {
                    envelope.extensions.append(
                        LastInputSeqTlv.wireExtension(seq: stamp))
                }
                videoSeq = videoSeq.next
                let header = try envelope.encode(payload: [])
                let sealed = try transport!.seal(
                    plaintext: payload[...], aad: header[...],
                    envelope: envelope)
                let datagram = try envelope.encode(payload: sealed)
                XCTAssertLessThanOrEqual(
                    datagram.count, WireBudget.maxDatagramByteCount,
                    "a stamped shard must still fit the 1152 B budget")
                out.append(datagram)
            }
            return out
        }

    }

    // MARK: - The client harness (the CL-8 shape: real core, no socket)

    private final class Harness: @unchecked Sendable {
        let host: HostInputStandIn
        let clientStatic = NoiseKeyPair.generate()
        let crypto: NoiseTransportCrypto
        let demux: ReceiveDemux
        var core: LyteUdpSessionCore!
        let outbound = LockedBytePile()
        let clock = LockedClock()
        var deliveredFrames: [UInt32] = []

        init(host: HostInputStandIn) throws {
            self.host = host
            let crypto = try NoiseTransportCrypto(
                hostAddress: "10.0.0.249", hostPort: 41_011,
                hostStaticPublicKey: host.staticKeys.publicKey,
                staticKeys: clientStatic,
                attempts: 3, attemptTimeoutMilliseconds: 200)
            try crypto.performHandshake(io: host)
            self.crypto = crypto
            self.demux = ReceiveDemux(crypto: crypto)
            let outbound = self.outbound
            let clock = self.clock
            let sender = TransportSender(crypto: crypto, transmit: {
                outbound.append($0)
                return true
            })
            self.core = LyteUdpSessionCore(
                demux: demux,
                sender: sender,
                now: { ClientTimestamp(microseconds: clock.value) },
                videoSink: HeadlessVideoSink(receive: {
                    [weak self] _, unit in
                    self?.deliveredFrames.append(unit.frameNumber.rawValue)
                }),
                onEvent: { _ in })
        }

        func absorb(_ bytes: [UInt8], tMicros: UInt64) {
            let outcome = demux.ingest(
                datagram: bytes[...], arrivalMicroseconds: tMicros)
            switch outcome {
            case .accepted:
                core.handleDatagram(outcome, arrivalMicroseconds: tMicros)
            case .unsealFailed:
                break   // byte-identical duplicate: replay window
            default:
                XCTFail("host datagram refused: \(outcome)")
            }
        }
    }

    final class LockedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64 = 1_000
        var value: UInt64 {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    final class UInt32Pile: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [UInt32] = []
        func append(_ value: UInt32) {
            lock.lock(); stored.append(value); lock.unlock()
        }
        var all: [UInt32] {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }

    // MARK: - The full loop through the W-G4 storm

    func testGateSyntheticInputThroughStormWithEchoesAndPhotonLoop() throws {
        let corpus = try loadCorpus(2)
        let host = HostInputStandIn()
        let harness = try Harness(host: host)
        var net = SimNet(
            config: SimNetConfig(
                baseDelayMicroseconds: 4_000,
                jitterMicroseconds: 2_000
            ),
            seed: 0xC1_9
        )

        try harness.core.open(now: ClientTimestamp(microseconds: 1_000))

        // The script (virtual µs). Beacons run from establishment so
        // the clock model has a fit before the first echo returns:
        //   3.0–4.0 s  40 input events, all five kinds, one per 25 ms,
        //              THROUGH the W-G4 storm (5% loss, 2% dup, jitter)
        //   4.2 s      storm clears (input proven under impairment;
        //              the photon leg wants a deliverable frame)
        //   4.5 s      video frame 0 (IDR) — stamped: injections
        //              already happened, so every shard carries TLV
        //              0x03 = 39, and its delivery closes all 40 loops
        //   4.8 s      video frame 1 — stamped the same
        let bodies: [InputEvent.Body] = [
            .keyKeycode(keycode: 30, pressed: true),
            .keyKeycode(keycode: 30, pressed: false),
            .pointerMotionAbsolute(x: 512.5, y: 320.25),
            .pointerMotionRelative(dx: -3.5, dy: 12),
            .pointerButton(button: 0x110, pressed: true),
            .pointerButton(button: 0x110, pressed: false),
            .pointerAxis(dx: 0, dy: -45, finish: false),
            .pointerAxis(dx: 0, dy: 0, finish: true),
        ]
        let eventCount = 40
        var expected: [InputEvent] = []

        var stormApplied = false
        var stormCleared = false
        var eventsSent = 0
        var frame0Sent = false
        var frame1Sent = false
        var forwarded = 0

        var t: UInt64 = 1_000
        while t <= 6_500_000 {
            harness.clock.value = t

            if t >= 2_900_000, !stormApplied {
                stormApplied = true
                net.setConfig(SimNetConfig(
                    lossRate: 0.05, duplicateRate: 0.02,
                    baseDelayMicroseconds: 4_000,
                    jitterMicroseconds: 2_000))
            }
            if t >= 4_200_000, !stormCleared {
                stormCleared = true
                net.setConfig(SimNetConfig(
                    baseDelayMicroseconds: 4_000,
                    jitterMicroseconds: 2_000))
            }

            // One event per 25 ms from 3.0 s — the production
            // sendInput path (seq allocation, capture stamp, reliable
            // stream), never gated on mode (the pre-arm rule).
            if eventsSent < eventCount,
               t >= 3_000_000 + UInt64(eventsSent) * 25_000 {
                let body = bodies[eventsSent % bodies.count]
                let seq = try harness.core.sendInput(
                    body, now: ClientTimestamp(microseconds: t))
                XCTAssertEqual(Int(seq), eventsSent,
                               "session seqs allocate serially from 0")
                expected.append(InputEvent(
                    seq: seq, clientMicroseconds: t, body: body))
                eventsSent += 1
            }

            if t >= 4_500_000, !frame0Sent {
                frame0Sent = true
                for datagram in try host.videoDatagrams(
                    annexB: corpus[0], frameNumber: 0, hostMicros: t
                ) {
                    net.send(from: 1, bytes: datagram, now: t)
                }
            }
            if t >= 4_800_000, !frame1Sent {
                frame1Sent = true
                for datagram in try host.videoDatagrams(
                    annexB: corpus[1], frameNumber: 1, hostMicros: t
                ) {
                    net.send(from: 1, bytes: datagram, now: t)
                }
            }

            for delivery in net.deliveries(upTo: t) {
                if delivery.destination == 0 {
                    harness.absorb(delivery.bytes, tMicros: t)
                } else {
                    try host.absorb(delivery.bytes, hostMicros: t)
                }
            }

            harness.core.tick(now: ClientTimestamp(microseconds: t))
            while forwarded < harness.outbound.count {
                net.send(from: 0, bytes: harness.outbound.all[forwarded], now: t)
                forwarded += 1
            }
            for datagram in try host.advance(hostMicros: t) {
                net.send(from: 1, bytes: datagram, now: t)
            }

            t += 5_000
        }

        // ── Exactly once, IN ORDER, byte-faithful through the storm. ──
        XCTAssertEqual(host.receivedEvents.count, eventCount,
                       "every event exactly once — no loss, no duplicate")
        XCTAssertEqual(host.receivedEvents, expected,
                       "seq, capture stamp, and body byte-faithful IN ORDER")
        XCTAssertEqual(host.declarationsSeen, 1,
                       "the declaration stayed the first reliable word")

        // ── Every injection echoed; the books balance. ──
        let stats = harness.core.input.snapshotStats()
        XCTAssertEqual(host.echoTuplesSent, eventCount)
        XCTAssertEqual(stats.eventsSent, UInt64(eventCount))
        XCTAssertEqual(stats.echoTuplesReceived, UInt64(eventCount),
                       "40/40 echo tuples consumed")
        XCTAssertEqual(stats.unmatchedEchoTuples, 0)
        XCTAssertEqual(stats.sendFailures, 0)
        XCTAssertEqual(stats.malformedFrameStamps, 0)
        XCTAssertEqual(harness.core.input.pendingEchoCount, 0)

        // ── The host's receive→inject edge survives the trip EXACTLY
        // (the deterministic leg of the latency math). ──
        XCTAssertEqual(stats.hostReceiveToInject.count, eventCount)
        XCTAssertEqual(stats.hostReceiveToInject.p50,
                       HostInputStandIn.injectDelayMicroseconds)
        XCTAssertEqual(stats.hostReceiveToInject.p99,
                       HostInputStandIn.injectDelayMicroseconds)

        // ── input→inject through the REAL clock loop (beacon → echo →
        // mirror → CL-10 fit): every echo that found a fit recorded,
        // and the values sit where SimNet's one-way delay + the
        // synthetic inject delay put them (identical virtual clocks →
        // true offset 0; the fit's error is bounded by the jitter). ──
        XCTAssertEqual(
            stats.inputToInject.count + Int(stats.echoesWithoutClockFit),
            eventCount)
        XCTAssertGreaterThan(stats.inputToInject.count, eventCount / 2,
                             "the fit existed for most echoes")
        if let p50 = stats.inputToInject.p50, let p99 = stats.inputToInject.p99 {
            XCTAssertGreaterThan(p50, 1_000, "one-way delay + inject > 1 ms")
            XCTAssertLessThan(p50, 20_000,
                              "the median event crossed in one flight")
            XCTAssertLessThan(p99, 300_000,
                              "the tail is bounded by a couple of PTO cycles "
                              + "(a lost 0x16 under the 5% storm retransmits)")
        } else {
            XCTFail("no input→inject percentiles recorded")
        }

        // ── The photon loop: both frames delivered; the stamped IDR
        // closed ALL 40 loops (stamp 39 ≥ every seq); values span the
        // capture→delivery gap the script created. ──
        XCTAssertEqual(harness.deliveredFrames, [0, 1])
        XCTAssertEqual(stats.lastStampSeen, 39)
        XCTAssertEqual(stats.inputToPhoton.count, eventCount,
                       "one photon edge per event, closed by the stamped frame")
        if let p50 = stats.inputToPhoton.p50, let max = stats.inputToPhoton.maxValue {
            XCTAssertGreaterThan(p50, 400_000,
                                 "median event waited ~½ s for the stamped frame")
            XCTAssertLessThan(max, 2_000_000,
                              "the earliest event closed within the script window")
        } else {
            XCTFail("no input→photon percentiles recorded")
        }

        // ── Hygiene: nothing malformed, nothing unknown, ARQ quiescent. ──
        let counters = harness.core.snapshotCounters()
        XCTAssertEqual(counters.malformedReliableMessages, 0)
        XCTAssertEqual(counters.unknownReliableTypes, 0)
        XCTAssertGreaterThan(counters.inputEchoMessagesReceived, 0)
        XCTAssertTrue(harness.core.isReliableQuiescent,
                      "all input + echo traffic acknowledged both ways")

        print("CL-9 gate: \(eventCount)/\(eventCount) events exactly-once "
            + "in-order through the W-G4 storm; \(stats.echoTuplesReceived) "
            + "echoes; host rx→inject pinned at "
            + "\(HostInputStandIn.injectDelayMicroseconds) µs; "
            + "input→inject p50 \(stats.inputToInject.p50 ?? 0) µs over the "
            + "live clock fit; \(stats.inputToPhoton.count) photon loops "
            + "closed by the stamped frame")
    }
}
