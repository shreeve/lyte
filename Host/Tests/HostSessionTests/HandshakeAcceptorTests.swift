import HostSession
import LyteWire
import LyteWireTestKit
import XCTest

/// The listener's admission of client handshakes: one initiation parse,
/// the process-wide flood gate and answered memory, and authentication
/// against the paired set.
final class HandshakeAcceptorTests: XCTestCase {
    private static let secret = [UInt8](repeating: 0x5A, count: 32)
    private static let client = FourTuple(
        localAddress: "0.0.0.0", localPort: 41_151,
        remoteAddress: "10.0.0.23", remotePort: 61_000)
    private static let spoofed = FourTuple(
        localAddress: "0.0.0.0", localPort: 41_151,
        remoteAddress: "10.0.0.66", remotePort: 40_000)

    private let host = NoiseKeyPair.generate()

    private func acceptor(
        gate: HandshakeGate.Config = HandshakeGate.Config(),
        allowed: [[UInt8]]? = nil
    ) -> HandshakeAcceptor {
        HandshakeAcceptor(config: HandshakeAcceptor.Config(
            hostStatic: host, gate: gate,
            allowedClientStaticPublicKeys: allowed))
    }

    private func ctrl(_ payload: [UInt8], seq: UInt16 = 0) throws -> [UInt8] {
        try Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: seq),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
        ).encode(payload: payload)
    }

    /// A fresh dial's bare message 1 (0x05) and its Noise bytes.
    private func dial(
        staticKeys: NoiseKeyPair = .generate()
    ) throws -> (datagram: [UInt8], message1: [UInt8]) {
        var noise = try NoiseSession(
            role: .initiator, staticKeys: staticKeys,
            remoteStaticPublicKey: host.publicKey)
        let message1 = try noise.writeMessage1()
        return (try ctrl([CtrlMessageType.noiseHandshake1] + message1), message1)
    }

    private func garbage(_ rng: inout SplitMix64) throws -> [UInt8] {
        try ctrl([CtrlMessageType.noiseHandshake1]
            + (0..<96).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    private func cookied(
        _ message1: [UInt8], from tuple: FourTuple, now: UInt64 = 1_000
    ) throws -> [UInt8] {
        let cookie = try RetryCookie.mint(
            clientTuple: Array(
                "\(tuple.remoteAddress):\(tuple.remotePort)".utf8),
            message1: message1[...], now: now, secret: Self.secret)
        return try ctrl(
            RetryHandshake1(cookie: cookie, message1: message1).encode())
    }

    private func authenticated(
        _ decision: HandshakeAcceptor.Decision
    ) -> AuthenticatedHandshake? {
        guard case .authenticated(let handshake) = decision.verdict
        else { return nil }
        return handshake
    }

    private func challenged(_ decision: HandshakeAcceptor.Decision) -> Bool {
        guard case .challenge = decision.verdict else { return false }
        return true
    }

    private func refusal(
        _ decision: HandshakeAcceptor.Decision
    ) -> HandshakeAcceptor.Refusal? {
        guard case .refused(let refusal) = decision.verdict else { return nil }
        return refusal
    }

    /// The flood dial belongs to the listener, not to a session: a flood
    /// that engaged it just before the shell discarded an unconfirmed
    /// answer still has the next un-cookied message 1 challenged.
    func testCookieModeOutlivesTheSessionsItAnswers() throws {
        var acceptor = acceptor(gate: HandshakeGate.Config(
            cookieSecret: Self.secret))
        XCTAssertNotNil(authenticated(acceptor.accept(
            try dial().datagram[...], from: Self.client, now: 0)),
            "a dial nobody confirms is answered")
        let floodAt: UInt64 = 11_900_000_000
        var engaged = false
        for i in 0..<25 {
            let decision = acceptor.accept(
                try dial().datagram[...], from: Self.spoofed,
                now: floodAt + UInt64(i) * 1_000_000)
            engaged = engaged || decision.cookieModeChangedTo == true
        }
        XCTAssertTrue(engaged)
        // The unconfirmed answer is abandoned at 12 s and its session
        // discarded; the acceptor lives on.
        XCTAssertTrue(challenged(acceptor.accept(
            try dial().datagram[...], from: Self.client,
            now: 12_000_001_000)), "the flood is still on")
    }

    /// Only a CTRL carriage typed 0x05 or a well-formed 0x14 is an
    /// initiation; nothing else reaches the gate.
    func testOnlyHandshakeInitiationsAreRead() throws {
        var acceptor = acceptor()
        func verdict(_ datagram: [UInt8]) -> HandshakeAcceptor.Verdict {
            acceptor.accept(datagram[...], from: Self.client, now: 0).verdict
        }
        guard case .notInitiation = verdict(
            try ctrl([CtrlMessageType.noiseHandshake2, 1])) else {
            return XCTFail("message 2 is not an initiation")
        }
        guard case .notInitiation = verdict(
            try ctrl([CtrlMessageType.retryHandshake1, 1, 2, 3])) else {
            return XCTFail("a malformed 0x14 is not an initiation")
        }
        guard case .notInitiation = verdict([0x00, 0x01]) else {
            return XCTFail("garbage is not an initiation")
        }
        let onFeedback = try Envelope(
            channel: .feedback, seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
        ).encode(payload: [CtrlMessageType.noiseHandshake1] + dial().message1)
        guard case .notInitiation = verdict(onFeedback) else {
            return XCTFail("message 1 rides CTRL only")
        }
        XCTAssertNotNil(authenticated(acceptor.accept(
            try dial().datagram[...], from: Self.client, now: 0)))
        XCTAssertEqual(acceptor.counters, HandshakeAcceptor.Counters())
    }

    /// A garbage message 1 from a spoofed source binds nothing; the
    /// message 1 that authenticates carries the tuple it came from.
    func testTheAuthenticatingTupleIsTheHandshakesTuple() throws {
        var acceptor = acceptor()
        let refused = acceptor.accept(
            try ctrl([CtrlMessageType.noiseHandshake1]
                + [UInt8](repeating: 0x42, count: 96))[...],
            from: Self.spoofed, now: 1_000)
        guard case .handshakeFailed = refusal(refused) else {
            return XCTFail("garbage fails in Noise: \(refused.verdict)")
        }
        let clientKeys = NoiseKeyPair.generate()
        let (datagram, message1) = try dial(staticKeys: clientKeys)
        let handshake = try XCTUnwrap(authenticated(acceptor.accept(
            datagram[...], from: Self.client, now: 2_000)))
        XCTAssertEqual(handshake.clientTuple, Self.client)
        XCTAssertEqual(handshake.message1, message1)
        XCTAssertEqual(handshake.remoteStaticPublicKey, clientKeys.publicKey)
    }

    /// The token bucket is consulted before any Noise: a flood's burst
    /// reaches the responder, the rest is refused unread, and the bucket
    /// refills for an honest dial. Answered handshakes spend it too.
    func testTheGateThrottlesBeforeNoiseAndRefills() throws {
        var acceptor = acceptor(gate: HandshakeGate.Config(
            ratePerSecond: 10, burst: 10))
        var rng = SplitMix64(seed: 0xF100D)
        var failed = 0
        var throttled = 0
        for _ in 0..<200 {
            switch refusal(acceptor.accept(
                try garbage(&rng)[...], from: Self.spoofed, now: 1_000)) {
            case .handshakeFailed: failed += 1
            case .throttled: throttled += 1
            default: XCTFail("garbage is refused")
            }
        }
        XCTAssertEqual(failed, 10, "exactly the burst reaches Noise")
        XCTAssertEqual(throttled, 190)
        XCTAssertEqual(acceptor.counters.throttled, 190)
        XCTAssertEqual(refusal(acceptor.accept(
            try dial().datagram[...], from: Self.client, now: 2_000)),
            .throttled, "an honest dial waits for the refill too")
        XCTAssertNotNil(authenticated(acceptor.accept(
            try dial().datagram[...], from: Self.client,
            now: 2_000_000_000)), "two seconds on, the bucket has refilled")
    }

    /// Pair once, reconnect 1-RTT: the paired static authenticates, a
    /// stranger's message 1 dies at the paired-set check.
    func testThePairedSetAdmitsPairedAndRefusesStrangers() throws {
        let paired = NoiseKeyPair.generate()
        var acceptor = acceptor(allowed: [paired.publicKey])
        XCTAssertEqual(authenticated(acceptor.accept(
            try dial(staticKeys: paired).datagram[...],
            from: Self.client, now: 0))?.remoteStaticPublicKey,
            paired.publicKey)
        XCTAssertEqual(
            refusal(acceptor.accept(
                try dial().datagram[...], from: Self.spoofed, now: 1_000)),
            .handshakeFailed("client static not in the paired set"))
    }

    /// The listener remembers what it answered: that message 1 again —
    /// replayed, or a stale retransmit re-enveloped after its session
    /// ended — is refused before the gate or Noise reads it.
    func testAMessage1AnsweredBeforeIsRefused() throws {
        var acceptor = acceptor()
        let (datagram, message1) = try dial()
        XCTAssertNotNil(authenticated(acceptor.accept(
            datagram[...], from: Self.client, now: 0)))
        let stale = try Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 3),
            frame: FrameNumber(rawValue: 0), timestamp: 7, fec: 0
        ).encode(payload: [CtrlMessageType.noiseHandshake1] + message1)
        XCTAssertEqual(refusal(acceptor.accept(
            stale[...], from: Self.spoofed, now: 1_000)), .answeredBefore)
        XCTAssertEqual(acceptor.counters.answeredBefore, 1)
    }

    /// Under flood an un-cookied message 1 is answered with a stateless
    /// RetryChallenge datagram smaller than the request, and a 0x14
    /// echoing its cookie authenticates; the dial clears with hysteresis
    /// once pressure lifts.
    func testAFloodChallengesThenAVerifiedCookieAuthenticates() throws {
        var acceptor = acceptor(gate: HandshakeGate.Config(
            cookieSecret: Self.secret,
            cookieEnterThreshold: 4, cookieExitThreshold: 1))
        var rng = SplitMix64(seed: 0x5EED)
        var changes: [Bool] = []
        for i in 0..<6 {
            let decision = acceptor.accept(
                try garbage(&rng)[...], from: Self.spoofed,
                now: 1_000 + UInt64(i) * 1_000)
            if let change = decision.cookieModeChangedTo { changes.append(change) }
        }
        XCTAssertEqual(changes, [true])
        XCTAssertTrue(acceptor.cookieMode)

        let (datagram, message1) = try dial()
        guard case .challenge(let challenge) = acceptor.accept(
            datagram[...], from: Self.client, now: 10_000).verdict else {
            return XCTFail("a flooded bare message 1 is challenged")
        }
        XCTAssertLessThan(challenge.count, datagram.count,
                          "the challenge never amplifies the request")
        let (envelope, payload) = try Envelope.decode(challenge[...])
        XCTAssertEqual(envelope.channel, .ctrl)
        let retry = try RetryHandshake1(
            echoing: RetryChallenge.decode(payload), message1: message1)
        let admitted = acceptor.accept(
            try ctrl(retry.encode())[...], from: Self.client, now: 20_000)
        XCTAssertNotNil(authenticated(admitted))
        XCTAssertEqual(acceptor.counters.cookiesVerified, 1)
        XCTAssertGreaterThan(acceptor.counters.challengesMinted, 0)

        let clearing = acceptor.accept(
            try garbage(&rng)[...], from: Self.spoofed, now: 3_000_000_000)
        XCTAssertEqual(clearing.cookieModeChangedTo, false)
        XCTAssertFalse(acceptor.cookieMode)
    }

    /// A 0x14 whose cookie does not verify is refused before any Noise.
    func testABadCookieIsRefusedBeforeNoise() throws {
        var acceptor = acceptor(gate: HandshakeGate.Config(
            cookieSecret: Self.secret,
            cookieEnterThreshold: 1, cookieExitThreshold: 0))
        let forged = [UInt8](repeating: 0xEE, count: RetryCookie.byteCount)
        let datagram = try ctrl(RetryHandshake1(
            cookie: forged, message1: dial().message1).encode())
        XCTAssertEqual(refusal(acceptor.accept(
            datagram[...], from: Self.client, now: 1_000)), .cookieInvalid)
        XCTAssertEqual(acceptor.counters.cookiesRejected, 1)
    }

    /// One proven host on many source ports is one share of the cookie
    /// budget: fresh cookies from 60 ports buy that host its share, and a
    /// client at another address dialing in the same instant still
    /// authenticates.
    func testOneAddressOnManyPortsSpendsOneShareOfTheCookieBudget() throws {
        var acceptor = acceptor(gate: HandshakeGate.Config(
            cookieSecret: Self.secret,
            cookieEnterThreshold: 1, cookieExitThreshold: 0))
        var rng = SplitMix64(seed: 0x9048)
        for port in UInt16(20_000)..<20_060 {
            let tuple = FourTuple(
                localAddress: "10.0.0.249", localPort: 41_157,
                remoteAddress: "10.0.0.66", remotePort: port)
            let bytes = (0..<96).map { _ in UInt8.random(in: 0...255, using: &rng) }
            _ = acceptor.accept(
                try cookied(bytes, from: tuple)[...], from: tuple, now: 2_000)
        }
        XCTAssertEqual(acceptor.counters.cookiesVerified, 2,
                       "one address's share, whatever its ports")
        XCTAssertNotNil(authenticated(acceptor.accept(
            try cookied(dial().message1, from: Self.client)[...],
            from: Self.client, now: 2_000)),
            "the host-wide cookie budget is untouched")
    }
}
