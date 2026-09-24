import HostCore
import HostSession
import HostWire
import LyteWire
import LyteWireTestKit
import XCTest

/// Noise IK message 1 carries no freshness: a message 1 captured from any
/// earlier session of a paired client authenticates again, from any
/// tuple, even with --require-paired. So answering one commits the host
/// to nothing — a session is uncommitted until its initiator proves key
/// possession with an authenticated transport datagram, and until then a
/// newer message 1 that authenticates supersedes it.
final class HandshakeReplayGateTests: XCTestCase {
    private static let attacker = FourTuple(
        localAddress: "0.0.0.0", localPort: 41_151,
        remoteAddress: "10.0.0.66", remotePort: 40_000)
    private static let client = FourTuple(
        localAddress: "0.0.0.0", localPort: 41_151,
        remoteAddress: "10.0.0.23", remotePort: 61_000)

    private final class Sink {
        var sent: [VideoChannelDatagram] = []
        func take() -> [VideoChannelDatagram] {
            defer { sent.removeAll() }
            return sent
        }
    }

    private func makeSession(
        host: NoiseKeyPair, allowed: [[UInt8]]? = nil,
        tuple: FourTuple, sink: Sink, seed: UInt64
    ) -> Session {
        Session(
            config: SessionConfig(
                crypto: .noise(hostStatic: host),
                rateBitsPerSecond: 20_000_000,
                allowedClientStaticPublicKeys: allowed),
            clientTuple: tuple, now: 0,
            rng: SplitMix64(seed: seed)
        ) { sink.sent.append($0) }
    }

    private func completed(_ events: [SessionEvent]) -> Bool {
        events.contains {
            if case .handshakeCompleted = $0 { return true }
            return false
        }
    }

    /// The same Noise message 1, re-enveloped (the client's retransmit
    /// timer stamps a new timestamp on the verbatim bytes).
    private func reenvelope(_ datagram: [UInt8], timestamp: UInt64) throws -> [UInt8] {
        let (_, payload) = try Envelope.decode(datagram[...])
        return try Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0), timestamp: timestamp, fec: 0
        ).encode(payload: Array(payload))
    }

    /// The review's proof, inverted: a replayed message 1 still completes
    /// a handshake, but only an uncommitted one — the real client's fresh
    /// message 1 supersedes it instead of being dropped, and the session
    /// that replaces it is bound to the real client.
    func testAReplayedMessage1CannotLockOutTheRealClient() throws {
        let host = NoiseKeyPair.generate()
        let clientKeys = NoiseKeyPair.generate()
        // Yesterday's session: the paired client's message 1, observed.
        var yesterday = try SealedCtrlPeer<ClientClock>(
            initiatorTo: host.publicKey, staticKeys: clientKeys)
        let captured = try yesterday.message1Datagram(timestamp: 1)

        let sink = Sink()
        let replayed = makeSession(
            host: host, allowed: [clientKeys.publicKey],
            tuple: Self.attacker, sink: sink, seed: 9)
        let replayEvents = replayed.receive(
            captured, from: Self.attacker, now: 1_000, hostMicroseconds: 1)
        XCTAssertTrue(completed(replayEvents), "the replay authenticates")
        XCTAssertEqual(replayed.validator.primary.tuple, Self.attacker)
        XCTAssertFalse(replayed.isPeerConfirmed,
                       "but nobody has proved key possession")
        XCTAssertEqual(replayed.answeredMessage1,
                       Session.handshakeMessage1(in: captured))

        // The real client dials now.
        var client = try SealedCtrlPeer<ClientClock>(
            initiatorTo: host.publicKey, staticKeys: clientKeys)
        let fresh = try client.message1Datagram(timestamp: 2)
        let later = replayed.receive(
            fresh, from: Self.client, now: 2_000, hostMicroseconds: 2)
        XCTAssertFalse(later.contains {
            if case .dropped = $0 { return true }
            return false
        }, "the real client's message 1 is not dropped: \(later)")
        XCTAssertEqual(replayed.counters.handshakesSuperseded, 1)
        let superseding = try XCTUnwrap(replayed.takeSupersedingHandshake())
        XCTAssertNil(replayed.takeSupersedingHandshake(), "handed over once")
        XCTAssertEqual(superseding.clientTuple, Self.client)

        // The shell replaces the uncommitted session with a fresh one.
        _ = sink.take()
        let session = makeSession(
            host: host, allowed: [clientKeys.publicKey],
            tuple: Self.client, sink: sink, seed: 10)
        XCTAssertTrue(completed(session.completeSupersedingHandshake(
            superseding, now: 2_000, hostMicroseconds: 2)))
        XCTAssertEqual(session.validator.primary.tuple, Self.client)
        XCTAssertFalse(session.isPeerConfirmed)
        session.pump(now: 2_000)
        let answer = try XCTUnwrap(sink.take().first)
        _ = try client.absorb(answer.bytes, nowMicros: 3)
        XCTAssertTrue(client.isEstablished)

        // The client's first sealed datagram commits the session.
        let echo = try client.datagram(
            body: [CtrlMessageType.arqAck, 0, 0], timestamp: 4)
        _ = session.receive(echo, from: Self.client, now: 3_000, hostMicroseconds: 3)
        XCTAssertTrue(session.isPeerConfirmed)
        XCTAssertNil(session.answeredMessage1)

        // Once committed, a replay is only an unsealable datagram.
        let afterCommit = session.receive(
            captured, from: Self.attacker, now: 4_000, hostMicroseconds: 4)
        XCTAssertEqual(afterCommit, [.dropped(.unsealFailed(0))])
        XCTAssertNil(session.takeSupersedingHandshake())
        XCTAssertEqual(session.validator.primary.tuple, Self.client)
    }

    /// A lost message 2: the client resends message 1 verbatim, and gets
    /// the same message 2 again — the keys it would derive are the
    /// session's own, whichever copy it reads.
    func testAVerbatimRepeatGetsTheSameMessage2() throws {
        let host = NoiseKeyPair.generate()
        let sink = Sink()
        let session = makeSession(host: host, tuple: Self.client, sink: sink, seed: 3)
        var client = try SealedCtrlPeer<ClientClock>(initiatorTo: host.publicKey)
        let first = try client.message1Datagram(timestamp: 1)
        XCTAssertTrue(completed(session.receive(
            first, from: Self.client, now: 0, hostMicroseconds: 0)))
        session.pump(now: 0)
        let original = try XCTUnwrap(sink.take().first)

        let repeatEvents = session.receive(
            try reenvelope(first, timestamp: 1_000_001),
            from: Self.client, now: 1_000_000_000, hostMicroseconds: 1_000_000)
        XCTAssertEqual(repeatEvents, [])
        XCTAssertEqual(session.counters.handshakeMessage2Resends, 1)
        XCTAssertNil(session.takeSupersedingHandshake())
        session.pump(now: 1_000_000_000)
        let resent = try XCTUnwrap(sink.take().first {
            (try? Envelope.decode($0.bytes[...]))?.1.first
                == CtrlMessageType.noiseHandshake2
        })
        XCTAssertEqual(try Envelope.decode(resent.bytes[...]).1,
                       try Envelope.decode(original.bytes[...]).1,
                       "the same message 2 bytes")

        // The first copy was lost; the client reads the resend and its
        // sealed traffic authenticates against the session's keys.
        _ = try client.absorb(resent.bytes, nowMicros: 2)
        XCTAssertTrue(client.isEstablished)
        let sealed = try client.datagram(
            body: [CtrlMessageType.arqAck, 0, 0], timestamp: 3)
        _ = session.receive(sealed, from: Self.client,
                            now: 1_000_001_000, hostMicroseconds: 1_000_001)
        XCTAssertTrue(session.isPeerConfirmed)
    }

    /// The confirming datagram is sealed; its first ciphertext byte is
    /// 0x05 (message 1's type) one time in 256. It must still confirm —
    /// the AEAD is asked before the handshake shape is.
    func testASealedDatagramShapedLikeMessage1StillConfirms() throws {
        let host = NoiseKeyPair.generate()
        let sink = Sink()
        let session = makeSession(host: host, tuple: Self.client, sink: sink, seed: 7)
        var client = try SealedCtrlPeer<ClientClock>(initiatorTo: host.publicKey)
        XCTAssertTrue(completed(session.receive(
            try client.message1Datagram(timestamp: 1),
            from: Self.client, now: 0, hostMicroseconds: 0)))
        session.pump(now: 0)
        _ = try client.absorb(try XCTUnwrap(sink.take().first).bytes, nowMicros: 1)

        var shaped: [UInt8]?
        for attempt in 0..<4_096 where shaped == nil {
            let candidate = try client.datagram(
                body: [CtrlMessageType.arqAck, 0, 0], timestamp: UInt64(attempt))
            if Session.handshakeMessage1(in: candidate) != nil { shaped = candidate }
        }
        let datagram = try XCTUnwrap(shaped, "a message-1-shaped ciphertext")
        let events = session.receive(datagram, from: Self.client,
                                     now: 1_000, hostMicroseconds: 1)
        XCTAssertFalse(events.contains {
            if case .dropped = $0 { return true }
            return false
        }, "\(events)")
        XCTAssertTrue(session.isPeerConfirmed)
    }

    /// A verbatim repeat from another tuple is not answered: message 2
    /// goes only where the answered message 1 came from.
    func testAVerbatimRepeatFromAnotherTupleIsDropped() throws {
        let host = NoiseKeyPair.generate()
        let sink = Sink()
        let session = makeSession(host: host, tuple: Self.client, sink: sink, seed: 4)
        var client = try SealedCtrlPeer<ClientClock>(initiatorTo: host.publicKey)
        let first = try client.message1Datagram(timestamp: 1)
        _ = session.receive(first, from: Self.client, now: 0, hostMicroseconds: 0)
        XCTAssertEqual(session.receive(
            try reenvelope(first, timestamp: 9), from: Self.attacker,
            now: 1_000, hostMicroseconds: 1),
            [.dropped(.handshakeRepeatOffPath)])
        XCTAssertEqual(session.counters.handshakeMessage2Resends, 0)
    }

    /// A superseding message 1 still passes the gate: an unconfirmed
    /// session is not a way around the flood throttle.
    func testSupersedingInitiationsSpendTheGate() throws {
        let host = NoiseKeyPair.generate()
        let sink = Sink()
        let session = makeSession(host: host, tuple: Self.client, sink: sink, seed: 5)
        var first = try SealedCtrlPeer<ClientClock>(initiatorTo: host.publicKey)
        _ = session.receive(try first.message1Datagram(timestamp: 1),
                            from: Self.client, now: 0, hostMicroseconds: 0)
        var throttled = 0
        for i in 0..<30 {
            var dialer = try SealedCtrlPeer<ClientClock>(initiatorTo: host.publicKey)
            let events = session.receive(
                try dialer.message1Datagram(timestamp: 2),
                from: Self.attacker, now: UInt64(i) * 1_000, hostMicroseconds: 1)
            if events.contains(.dropped(.handshakeThrottled)) { throttled += 1 }
        }
        XCTAssertGreaterThan(throttled, 0)
        XCTAssertLessThan(session.counters.handshakesSuperseded, 30)
    }

    /// A message 1 whose static is not paired never supersedes.
    func testAnUnpairedMessage1CannotSupersede() throws {
        let host = NoiseKeyPair.generate()
        let paired = NoiseKeyPair.generate()
        let sink = Sink()
        let session = makeSession(
            host: host, allowed: [paired.publicKey],
            tuple: Self.client, sink: sink, seed: 6)
        var client = try SealedCtrlPeer<ClientClock>(
            initiatorTo: host.publicKey, staticKeys: paired)
        XCTAssertTrue(completed(session.receive(
            try client.message1Datagram(timestamp: 1),
            from: Self.client, now: 0, hostMicroseconds: 0)))
        var stranger = try SealedCtrlPeer<ClientClock>(initiatorTo: host.publicKey)
        let events = session.receive(
            try stranger.message1Datagram(timestamp: 2),
            from: Self.attacker, now: 1_000, hostMicroseconds: 1)
        XCTAssertEqual(events, [.dropped(.handshakeFailed(
            "client static not in the paired set"))])
        XCTAssertNil(session.takeSupersedingHandshake())
    }

    /// The listening service remembers what it answered: the previous
    /// session's message 1 — replayed, or a stale retransmit still queued
    /// on the listening socket — is known before any session reads it.
    func testTheListenerRemembersAnsweredMessage1s() throws {
        let host = NoiseKeyPair.generate()
        var memory = AnsweredHandshakeMemory()
        var client = try SealedCtrlPeer<ClientClock>(initiatorTo: host.publicKey)
        let datagram = try client.message1Datagram(timestamp: 1)
        let message1 = try XCTUnwrap(Session.handshakeMessage1(in: datagram))
        XCTAssertFalse(memory.contains(message1: message1))
        memory.record(message1: message1)
        let stale = try reenvelope(datagram, timestamp: 7)
        XCTAssertTrue(memory.contains(
            message1: try XCTUnwrap(Session.handshakeMessage1(in: stale))))
        XCTAssertNil(Session.handshakeMessage1(in: [0, 1, 2]))
    }
}
