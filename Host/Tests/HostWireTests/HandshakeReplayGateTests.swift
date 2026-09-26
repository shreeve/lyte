import HostCore
import HostSession
import HostWire
import HostWireTestKit
import LyteWire
import LyteWireTestKit
import XCTest

/// Noise IK message 1 carries no freshness: a message 1 captured from any
/// earlier session of a paired client authenticates again, from any
/// tuple, even with --require-paired. So answering one commits the host
/// to nothing — a session is uncommitted until its initiator proves key
/// possession with an authenticated transport datagram, and until then a
/// newer message 1 that authenticates replaces it.
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

    /// A session answering `client`'s first message 1 from `Self.client`.
    private func answered(
        _ client: inout SealedCtrlPeer<ClientClock>, host: NoiseKeyPair,
        sink: Sink, seed: UInt64
    ) throws -> (session: Session, message1: [UInt8]) {
        let first = try client.message1Datagram(timestamp: 1)
        let (session, _) = try Session.answering(
            first, hostStatic: host, from: Self.client,
            config: SessionConfig(rateBitsPerSecond: 20_000_000),
            rng: SplitMix64(seed: seed)
        ) { sink.sent.append($0) }
        return (session, first)
    }

    private func harness(
        host: NoiseKeyPair, allowed: [[UInt8]]? = nil, tuple: FourTuple
    ) -> HostSessionHarness {
        HostSessionHarness(
            config: SessionConfig(rateBitsPerSecond: 20_000_000),
            acceptor: HandshakeAcceptor.Config(
                hostStatic: host, allowedClientStaticPublicKeys: allowed),
            tuple: tuple, rng: SplitMix64(seed: 9))
    }

    private func completed(_ events: [SessionEvent]) -> Bool {
        events.contains {
            if case .handshakeCompleted = $0 { return true }
            return false
        }
    }

    private func isMessage2(_ datagram: VideoChannelDatagram) -> Bool {
        (try? Envelope.decode(datagram.bytes[...]))?.1.first
            == CtrlMessageType.noiseHandshake2
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

    /// A replayed message 1 still completes a handshake, but only an
    /// uncommitted one: the real client's fresh message 1 replaces it
    /// instead of being dropped, and the session that replaces it is
    /// bound to the real client.
    func testAReplayedMessage1CannotLockOutTheRealClient() throws {
        let host = NoiseKeyPair.generate()
        let clientKeys = NoiseKeyPair.generate()
        // Yesterday's session: the paired client's message 1, observed.
        var yesterday = try SealedCtrlPeer<ClientClock>(
            initiatorTo: host.publicKey, staticKeys: clientKeys)
        let captured = try yesterday.message1Datagram(timestamp: 1)

        let listener = harness(
            host: host, allowed: [clientKeys.publicKey], tuple: Self.attacker)
        XCTAssertTrue(completed(listener.receive(captured, at: 1)),
                      "the replay authenticates")
        let replayed = try XCTUnwrap(listener.currentSession)
        XCTAssertEqual(replayed.validator.primary.tuple, Self.attacker)
        XCTAssertFalse(replayed.isPeerConfirmed,
                       "but nobody has proved key possession")

        // The real client dials now, and its answer replaces the replay's.
        var client = try SealedCtrlPeer<ClientClock>(
            initiatorTo: host.publicKey, staticKeys: clientKeys)
        listener.tuple = Self.client
        let later = listener.receive(
            try client.message1Datagram(timestamp: 2), at: 2)
        XCTAssertTrue(later.contains(.initiationWhileUnconfirmed))
        XCTAssertTrue(completed(later), "\(later)")
        let session = try XCTUnwrap(listener.currentSession)
        XCTAssertFalse(session === replayed)
        XCTAssertEqual(session.validator.primary.tuple, Self.client)
        XCTAssertFalse(session.isPeerConfirmed)
        try listener.deliver(to: &client, at: 3)
        XCTAssertTrue(client.isEstablished)

        // The client's first sealed datagram commits the session.
        _ = listener.receive(try client.datagram(
            body: [CtrlMessageType.arqAck, 0, 0], timestamp: 4), at: 3)
        XCTAssertTrue(session.isPeerConfirmed)

        // Once committed, a replay is only an unsealable datagram.
        listener.tuple = Self.attacker
        XCTAssertEqual(listener.receive(captured, at: 4),
                       [.dropped(.unsealFailed(0))])
        XCTAssertTrue(listener.currentSession === session)
        XCTAssertEqual(session.validator.primary.tuple, Self.client)
    }

    /// A lost message 2: the client resends message 1 verbatim, and gets
    /// the same message 2 again — the keys it would derive are the
    /// session's own, whichever copy it reads.
    func testAVerbatimRepeatGetsTheSameMessage2() throws {
        let host = NoiseKeyPair.generate()
        let sink = Sink()
        var client = try SealedCtrlPeer<ClientClock>(initiatorTo: host.publicKey)
        let (session, first) = try answered(
            &client, host: host, sink: sink, seed: 3)
        session.pump(now: 0)
        let original = try XCTUnwrap(sink.take().first)

        let repeatEvents = session.receive(
            try reenvelope(first, timestamp: 1_000_001),
            from: Self.client, now: 1_000_000_000, hostMicroseconds: 1_000_000)
        XCTAssertEqual(repeatEvents, [])
        XCTAssertEqual(session.counters.handshakeMessage2Resends, 1)
        session.pump(now: 1_000_000_000)
        let resent = try XCTUnwrap(sink.take().first(where: isMessage2))
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

    /// A connect's first dial retransmits message 1 at 0, 2, 4, 6 and 8 s
    /// and waits until 10 s. Every message 2 but the last is lost: the
    /// answer is never abandoned while the client is still dialing, and
    /// the resend at 8 s completes the session. Only a lifetime of quiet
    /// after the latest send abandons an answer.
    func testAnAnswerLivesThroughTheClientsWholeFirstDial() throws {
        let host = NoiseKeyPair.generate()
        let sink = Sink()
        var client = try SealedCtrlPeer<ClientClock>(initiatorTo: host.publicKey)
        let (session, first) = try answered(
            &client, host: host, sink: sink, seed: 12)
        let second: UInt64 = 1_000_000_000
        session.pump(now: 0)
        _ = sink.take() // lost

        var lastAnswer: VideoChannelDatagram?
        for attempt in UInt64(1)...4 {
            let now = attempt * 2 * second
            XCTAssertFalse(session.isUnconfirmedAnswerAbandoned(now: now),
                           "abandoned before the retransmit at \(attempt * 2) s")
            _ = session.receive(
                try reenvelope(first, timestamp: now / 1_000),
                from: Self.client, now: now, hostMicroseconds: now / 1_000)
            session.pump(now: now)
            lastAnswer = sink.take().first(where: isMessage2)
            XCTAssertNotNil(lastAnswer, "message 2 resent at \(attempt * 2) s")
        }
        XCTAssertEqual(session.counters.handshakeMessage2Resends, 4)
        let delivered = 8 * second
        XCTAssertFalse(session.isUnconfirmedAnswerAbandoned(
            now: delivered + Session.unconfirmedAnswerLifetimeNS - 1))
        XCTAssertTrue(session.isUnconfirmedAnswerAbandoned(
            now: delivered + Session.unconfirmedAnswerLifetimeNS))

        _ = try client.absorb(try XCTUnwrap(lastAnswer).bytes, nowMicros: 8_000_001)
        let sealed = try client.datagram(
            body: [CtrlMessageType.arqAck, 0, 0], timestamp: 8_000_002)
        _ = session.receive(sealed, from: Self.client,
                            now: delivered + 1_000_000, hostMicroseconds: 8_001_000)
        XCTAssertTrue(session.isPeerConfirmed)
        XCTAssertFalse(session.isUnconfirmedAnswerAbandoned(
            now: delivered + 10 * Session.unconfirmedAnswerLifetimeNS),
            "a confirmed session is never an abandoned answer")
    }

    /// The confirming datagram is sealed; its first ciphertext byte is
    /// 0x05 (message 1's type) one time in 256. It must still confirm —
    /// the AEAD is asked before the handshake shape is.
    func testASealedDatagramShapedLikeMessage1StillConfirms() throws {
        let host = NoiseKeyPair.generate()
        let sink = Sink()
        var client = try SealedCtrlPeer<ClientClock>(initiatorTo: host.publicKey)
        let (session, _) = try answered(&client, host: host, sink: sink, seed: 7)
        session.pump(now: 0)
        _ = try client.absorb(try XCTUnwrap(sink.take().first).bytes, nowMicros: 1)

        var shaped: [UInt8]?
        for attempt in 0..<4_096 where shaped == nil {
            let candidate = try client.datagram(
                body: [CtrlMessageType.arqAck, 0, 0], timestamp: UInt64(attempt))
            if HandshakeAcceptor.parseInitiation(candidate[...]) != nil {
                shaped = candidate
            }
        }
        let datagram = try XCTUnwrap(shaped, "a message-1-shaped ciphertext")
        let events = session.receive(datagram, from: Self.client,
                                     now: 1_000, hostMicroseconds: 1)
        XCTAssertFalse(events.contains {
            if case .dropped = $0 { return true }
            return $0 == .initiationWhileUnconfirmed
        }, "\(events)")
        XCTAssertTrue(session.isPeerConfirmed)
    }

    /// A verbatim repeat from another tuple is not answered: message 2
    /// goes only where the answered message 1 came from.
    func testAVerbatimRepeatFromAnotherTupleIsDropped() throws {
        let host = NoiseKeyPair.generate()
        var client = try SealedCtrlPeer<ClientClock>(initiatorTo: host.publicKey)
        let (session, first) = try answered(
            &client, host: host, sink: Sink(), seed: 4)
        XCTAssertEqual(session.receive(
            try reenvelope(first, timestamp: 9), from: Self.attacker,
            now: 1_000, hostMicroseconds: 1),
            [.dropped(.handshakeRepeatOffPath)])
        XCTAssertEqual(session.counters.handshakeMessage2Resends, 0)
    }

    /// Initiations reaching an unconfirmed session still pass the
    /// listener's gate, and one that does not authenticate replaces
    /// nothing: an unconfirmed session is neither a way around the flood
    /// throttle nor around the paired set.
    func testInitiationsAtAnUnconfirmedSessionPassTheAcceptor() throws {
        let host = NoiseKeyPair.generate()
        let paired = NoiseKeyPair.generate()
        let listener = harness(
            host: host, allowed: [paired.publicKey], tuple: Self.client)
        var client = try SealedCtrlPeer<ClientClock>(
            initiatorTo: host.publicKey, staticKeys: paired)
        XCTAssertTrue(completed(listener.receive(
            try client.message1Datagram(timestamp: 1), at: 0)))
        let session = try XCTUnwrap(listener.currentSession)

        listener.tuple = Self.attacker
        for i in 0..<30 {
            var dialer = try SealedCtrlPeer<ClientClock>(initiatorTo: host.publicKey)
            _ = listener.receive(
                try dialer.message1Datagram(timestamp: 2), at: UInt64(i))
        }
        XCTAssertGreaterThan(listener.acceptor.counters.throttled, 0)
        XCTAssertTrue(listener.currentSession === session,
                      "no unpaired message 1 replaces the answer")
        XCTAssertEqual(session.validator.primary.tuple, Self.client)
    }
}
