import LyteClientSession
import LyteWire
import XCTest

/// The initiator pieces the native and browser shells share, driven
/// directly: the handshake over bare carriage, the IDR episode, the
/// beacon-echo book, conn-id learning, envelope sequencing and the
/// lifecycle effects.
final class ClientInitiatorPiecesTests: XCTestCase {
    private let hostStatic = NoiseKeyPair.generate()
    private let clientStatic = NoiseKeyPair.generate()

    private func initiator(
        attempts: Int = 3, interval: UInt64 = 100_000
    ) throws -> ClientHandshakeInitiator {
        try ClientHandshakeInitiator(
            hostStaticPublicKey: hostStatic.publicKey,
            clientStatic: clientStatic,
            retry: .init(attempts: attempts, intervalMicroseconds: interval))
    }

    private func payload(_ datagram: [UInt8]) throws -> [UInt8] {
        Array(try Envelope.decode(datagram[...]).1)
    }

    private func carriage(_ payload: [UInt8]) throws -> [UInt8] {
        try Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
        ).encode(payload: payload)
    }

    /// The host's answer to one message-1 carriage.
    private func message2(answering carriage: [UInt8]) throws -> [UInt8] {
        var responder = try NoiseSession(role: .responder, staticKeys: hostStatic)
        let body = try payload(carriage)
        XCTAssertEqual(body.first, CtrlMessageType.noiseHandshake1)
        _ = try responder.readMessage1(body.dropFirst())
        return try self.carriage(
            [CtrlMessageType.noiseHandshake2] + responder.writeMessage2())
    }

    func testRetransmitsTheSameMessage1ThenExhausts() throws {
        var handshake = try initiator()
        let first = try handshake.begin(nowMicros: 0)
        XCTAssertEqual(handshake.tick(nowMicros: 99_999), .wait)
        guard case .retransmit(let second) = handshake.tick(nowMicros: 100_000)
        else { return XCTFail("the first window closed without a retransmit") }
        XCTAssertEqual(try payload(second), try payload(first))
        guard case .retransmit = handshake.tick(nowMicros: 200_000) else {
            return XCTFail("the second window closed without a retransmit")
        }
        XCTAssertEqual(handshake.tick(nowMicros: 299_999), .wait)
        XCTAssertEqual(handshake.tick(nowMicros: 300_000), .exhausted)
        XCTAssertEqual(handshake.counters.message1Transmissions, 3)
    }

    func testALateAnswerToAnEarlierCopyStillCompletes() throws {
        var handshake = try initiator()
        let first = try handshake.begin(nowMicros: 0)
        _ = handshake.tick(nowMicros: 100_000)
        guard case .established(let transport) = handshake.ingest(
            try message2(answering: first)[...], nowMicros: 150_000)
        else { return XCTFail("the late answer did not complete") }
        XCTAssertEqual(transport.handshakeHash.count, 32)
        XCTAssertEqual(handshake.tick(nowMicros: 900_000), .wait,
                       "a finished handshake never retransmits")
    }

    func testRetryChallengeIsAnsweredWithTheSameMessage1() throws {
        var handshake = try initiator()
        let first = try handshake.begin(nowMicros: 0)
        let challenge = try RetryChallenge(cookie: [1, 2, 3]).encode()
        guard case .reply(let answer) = handshake.ingest(
            try carriage(challenge)[...], nowMicros: 10)
        else { return XCTFail("the challenge went unanswered") }
        let resubmission = try RetryHandshake1.decode(try payload(answer)[...])
        XCTAssertEqual(resubmission.cookie, [1, 2, 3])
        XCTAssertEqual(
            [CtrlMessageType.noiseHandshake1] + resubmission.message1,
            try payload(first))
        XCTAssertEqual(handshake.counters.retryChallengesAnswered, 1)
        XCTAssertEqual(handshake.counters.message1Transmissions, 1,
                       "answering spends no attempt")
    }

    func testFaultsAreCountedAndTheGenuineMessage2StillCompletes() throws {
        var handshake = try initiator()
        let first = try handshake.begin(nowMicros: 0)
        guard case .ignored = handshake.ingest([0xFF, 0x01][...], nowMicros: 1)
        else { return XCTFail("junk must be ignored") }
        guard case .ignored = handshake.ingest(
            try carriage([CtrlMessageType.retryChallenge])[...], nowMicros: 2)
        else { return XCTFail("a malformed challenge must be ignored") }
        let forged = try carriage(
            [CtrlMessageType.noiseHandshake2]
                + [UInt8](repeating: 0xA5, count: 48))
        guard case .rejectedMessage2 = handshake.ingest(forged[...], nowMicros: 3)
        else { return XCTFail("a forged message 2 must be rejected") }
        guard case .established = handshake.ingest(
            try message2(answering: first)[...], nowMicros: 4)
        else { return XCTFail("the genuine message 2 must still complete") }
        XCTAssertEqual(handshake.counters.undecodableDatagrams, 1)
        XCTAssertEqual(handshake.counters.malformedRetryChallenges, 1)
        XCTAssertEqual(handshake.counters.rejectedMessage2, 1)
    }

    // MARK: IDR recovery

    func testIdrEpisodeAsksOnceThenRetriesAtItsIntervalUntilAnIrap() {
        var recovery = ClientIdrRecovery(retryIntervalMicroseconds: 500_000)
        let t0 = ClientTimestamp(microseconds: 1_000_000)
        XCTAssertNil(recovery.requestDue(now: t0))
        recovery.recordDemand(frame: FrameNumber(rawValue: 10))
        let first = recovery.requestDue(now: t0)
        XCTAssertEqual(first?.frame.rawValue, 10)
        recovery.recordDemand(frame: FrameNumber(rawValue: 12))
        XCTAssertNil(recovery.requestDue(
            now: ClientTimestamp(microseconds: 1_499_999)))
        let retry = recovery.requestDue(
            now: ClientTimestamp(microseconds: 1_500_000))
        XCTAssertEqual(retry?.frame.rawValue, 12)
        XCTAssertEqual(retry?.coalescedCount, 2)
        XCTAssertEqual(retry?.requestSeq, 1)
        recovery.noteUsableIrapAccepted()
        XCTAssertFalse(recovery.isOutstanding)
        XCTAssertNil(recovery.requestDue(
            now: ClientTimestamp(microseconds: 9_000_000)))
        XCTAssertEqual(recovery.stats.episodesStarted, 1)
        XCTAssertEqual(recovery.stats.episodesCompleted, 1)
        XCTAssertEqual(recovery.stats.retryRequests, 1)
        XCTAssertEqual(recovery.stats.requestsSent, 2)
    }

    /// The open episode gates rendering: dependent frames wait for the
    /// IRAP that closes it.
    func testOpenEpisodeAdmitsOnlyRandomAccessFrames() {
        var recovery = ClientIdrRecovery()
        XCTAssertTrue(recovery.admits(isRandomAccess: false))
        XCTAssertFalse(recovery.recordDemand(frame: FrameNumber(rawValue: 3)))
        XCTAssertTrue(recovery.recordDemand(frame: FrameNumber(rawValue: 4)),
                      "a second verdict joins the open episode")
        XCTAssertFalse(recovery.admits(isRandomAccess: false))
        XCTAssertTrue(recovery.admits(isRandomAccess: true))
        recovery.noteUsableIrapAccepted()
        XCTAssertTrue(recovery.admits(isRandomAccess: false))
    }

    // MARK: Beacon echo

    func testMirrorClosesTheSampleTheHostMeasured() {
        var book = ClientBeaconEchoBook()
        // t1 = 1000 (host), t2 = 5000, t3 = 5010 (client); the host
        // measured t4 = 1030. Offset = ((t2−t1) + (t3−t4)) / 2 = 3990;
        // RTT = (t4 − t1) − (t3 − t2) = 20.
        let (echo, none) = book.answer(
            ClockBeacon(beaconSeq: 1, hostSend: HostTimestamp(microseconds: 1_000)),
            receivedAt: ClientTimestamp(microseconds: 5_000),
            sendingAt: ClientTimestamp(microseconds: 5_010))
        XCTAssertNil(none)
        XCTAssertEqual(echo.clientReceive.microseconds, 5_000)
        let mirror = ClockBeacon.LastEcho(
            beaconSeq: 1, clientSend: echo.clientSend,
            hostReceive: HostTimestamp(microseconds: 1_030))
        let (_, sample) = book.answer(
            ClockBeacon(beaconSeq: 2, hostSend: HostTimestamp(microseconds: 2_000),
                        lastEcho: mirror),
            receivedAt: ClientTimestamp(microseconds: 6_000),
            sendingAt: ClientTimestamp(microseconds: 6_000))
        XCTAssertEqual(sample?.offsetMicroseconds, 3_990)
        XCTAssertEqual(sample?.rttMicroseconds, 20)
        XCTAssertEqual(sample?.measuredAt.microseconds, 5_000)
    }

    /// Every mirror timestamp but t3 is host-chosen; a mirror naming a t3
    /// this book never sent, or closing an impossible RTT, is refused.
    func testForgedMirrorsCloseNoSample() {
        var book = ClientBeaconEchoBook()
        func beacon(_ seq: UInt32, mirror: ClockBeacon.LastEcho? = nil)
            -> ClockBeacon {
            ClockBeacon(beaconSeq: seq,
                        hostSend: HostTimestamp(microseconds: 1_000),
                        lastEcho: mirror)
        }
        let t2 = ClientTimestamp(microseconds: 5_000)
        let t3 = ClientTimestamp(microseconds: 5_010)
        for seq in UInt32(1)...3 {
            _ = book.answer(beacon(seq), receivedAt: t2, sendingAt: t3)
        }
        let forgedTurnaround = ClockBeacon.LastEcho(
            beaconSeq: 1, clientSend: ClientTimestamp(microseconds: 0),
            hostReceive: HostTimestamp(microseconds: 1_030))
        let negativeRtt = ClockBeacon.LastEcho(
            beaconSeq: 2, clientSend: t3,
            hostReceive: HostTimestamp(microseconds: 1_000))
        let hugeRtt = ClockBeacon.LastEcho(
            beaconSeq: 3, clientSend: t3,
            hostReceive: HostTimestamp(microseconds: UInt64(Int64.max)))
        for mirror in [forgedTurnaround, negativeRtt, hugeRtt] {
            let (_, sample) = book.answer(
                beacon(9, mirror: mirror), receivedAt: t2, sendingAt: t3)
            XCTAssertNil(sample)
        }
        XCTAssertEqual(book.mirrorsRefused, 3)
    }

    // MARK: Exempt CTRL

    func testExemptControlAnswersChallengesAndCountsMalformedWords() {
        let challenge = PathChallenge(token: 0x0123_4567_89AB_CDEF)
        XCTAssertEqual(
            ClientExemptControl(payload: challenge.encode()),
            .pathChallenge(response: PathResponse(token: challenge.token)))
        XCTAssertEqual(
            ClientExemptControl(payload: [CtrlMessageType.pathChallenge, 0]),
            .malformed(type: CtrlMessageType.pathChallenge))
        let beacon = ClockBeacon(
            beaconSeq: 4, hostSend: HostTimestamp(microseconds: 9))
        XCTAssertEqual(ClientExemptControl(payload: beacon.encode()),
                       .clockBeacon(beacon))
        XCTAssertEqual(ClientExemptControl(payload: [0x7E, 1, 2]), .unclaimed)
        XCTAssertEqual(ClientExemptControl(payload: []), .unclaimed)
    }

    // MARK: Carriage books

    func testConnectionIdIsLearnedOnceAndSequencesArePerChannel() throws {
        var rng = SystemRandomNumberGenerator()
        let id = ConnectionId.random(using: &rng)
        var book = ClientConnectionIdBook()
        XCTAssertEqual(book.extensions, [])
        let untagged = Envelope(
            channel: .ctrl, seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0)
        XCTAssertFalse(book.learn(from: untagged))
        var tagged = untagged
        tagged.extensions = [id.wireExtension]
        XCTAssertTrue(book.learn(from: tagged))
        XCTAssertFalse(book.learn(from: tagged))
        book.adopt(ConnectionId.random(using: &rng))
        XCTAssertEqual(book.learned, id, "first writer wins")

        var sequencer = ClientEnvelopeSequencer()
        let seqs = [ChannelId.ctrl, .feedback, .ctrl, .ctrl, .feedback].map {
            sequencer.envelope(channel: $0, timestamp: 0).seq.rawValue
        }
        XCTAssertEqual(seqs, [0, 0, 1, 2, 1])
    }

    // MARK: Lifecycle effects

    func testLocalTeardownYieldsTheWireMessageThenTheClose() {
        var lifecycle = ClientSessionLifecycle(
            config: SessionMachineConfig(),
            now: ClientTimestamp(microseconds: 0))
        let decision = lifecycle.advance(
            .teardownRequest(.shuttingDown),
            now: ClientTimestamp(microseconds: 1))
        XCTAssertEqual(decision.effects, [
            .sendTeardown(
                .shuttingDown,
                message: SessionTeardown(reason: .shuttingDown).encode()),
            .closed(.localTeardown(.shuttingDown)),
        ])
    }
}
