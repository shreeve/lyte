import LyteWire

/// The client's Noise IK initiator over bare CTRL carriage, IO-free. Every
/// shell — the native UDP endpoint and the browser — drives this one machine
/// with its own datagram IO and clock.
///
/// - Message 1 leaves as a bare CTRL datagram (chan 0, seq 0, no seal) whose
///   payload is `0x05 ‖ message 1`; message 2 returns as `0x06 ‖ message 2`.
/// - One session and one message 1 serve the whole retry window: a retransmit
///   resends the same bytes, so a host answer to any copy — however late —
///   completes this transcript.
/// - A `0x13` retry challenge is answered with that same message 1 and the
///   echoed cookie (`0x14`). Answering spends no attempt: the challenge is the
///   host's liveness. A host challenges each message 1 at most once, so only
///   one challenge per transmission is answered; answering a flood would
///   reflect it at the host's tuple.
/// - A message 2 that fails to read leaves the handshake untouched, so a later
///   genuine one still completes it.
public struct ClientHandshakeInitiator: Sendable {
    /// Message-1 retransmit schedule: `attempts` transmissions, each given
    /// `intervalMicroseconds` for an answer before the next (or failure).
    /// Every shell dials on one of these schedules; the default is 5 × 1 s.
    public struct Retry: Sendable, Equatable {
        public var attempts: Int
        public var intervalMicroseconds: UInt64

        public init(attempts: Int = 5, intervalMicroseconds: UInt64 = 1_000_000) {
            self.attempts = max(1, attempts)
            self.intervalMicroseconds = max(1, intervalMicroseconds)
        }

        /// A connect's first dial: 5 × 2 s, so a host still waking (or a
        /// radio still associating) has 10 s to answer.
        public static let firstDial = Retry(
            attempts: 5, intervalMicroseconds: 2_000_000)
        /// Every later dial — a connect's next round, a roaming probe:
        /// 3 × 700 ms, so a dead target frees the ladder in about 2 s.
        public static let redial = Retry(
            attempts: 3, intervalMicroseconds: 700_000)
    }

    public struct Counters: Sendable, Equatable {
        /// Message-1 transmissions, the first included.
        public var message1Transmissions: UInt64 = 0
        public var retryChallengesAnswered: UInt64 = 0
        /// Retry challenges that did not decode or could not be answered.
        public var malformedRetryChallenges: UInt64 = 0
        /// Challenges past the first for one message-1 transmission.
        public var retryChallengesIgnored: UInt64 = 0
        /// Message-2 candidates the handshake rejected.
        public var rejectedMessage2: UInt64 = 0
        /// Datagrams whose envelope did not decode.
        public var undecodableDatagrams: UInt64 = 0
        /// Decodable datagrams that were not handshake carriage (reordered
        /// sealed traffic, noise on the port).
        public var otherDatagrams: UInt64 = 0

        public init() {}
    }

    /// What one received datagram did.
    public enum Ingest: Sendable {
        /// Not for the handshake, or a fault already counted.
        case ignored
        /// Send this carriage (a retry-challenge answer).
        case reply([UInt8])
        /// A message 2 failed to read; the handshake continues.
        case rejectedMessage2(any Error)
        /// The handshake completed.
        case established(NoiseTransport)
    }

    /// What the clock requires now.
    public enum Tick: Sendable, Equatable {
        case wait
        /// Send this carriage (message 1 again, verbatim).
        case retransmit([UInt8])
        /// Every attempt's window passed unanswered.
        case exhausted
    }

    public let retry: Retry
    public private(set) var counters = Counters()
    private var session: NoiseSession
    private let message1: [UInt8]
    private var lastMessage1Micros: UInt64 = 0
    /// The transmission (by count) the last challenge answer spent.
    private var challengeAnsweredFor: UInt64?
    private var finished = false

    /// - Throws: `NoiseError` when the host static is not a valid key.
    public init(
        hostStaticPublicKey: [UInt8],
        clientStatic: NoiseKeyPair,
        retry: Retry = Retry()
    ) throws {
        var session = try NoiseSession(
            role: .initiator,
            staticKeys: clientStatic,
            remoteStaticPublicKey: hostStaticPublicKey
        )
        self.message1 = try session.writeMessage1()
        self.session = session
        self.retry = retry
    }

    public var message1ByteCount: Int { message1.count }

    /// The instant the current attempt's window closes.
    public var attemptDeadlineMicros: UInt64 {
        lastMessage1Micros &+ retry.intervalMicroseconds
    }

    /// The first message-1 carriage.
    /// - Throws: `WireError` only if the fixed carriage fails to encode.
    public mutating func begin(nowMicros: UInt64) throws -> [UInt8] {
        try message1Carriage(nowMicros: nowMicros)
    }

    /// Retransmits message 1 when its attempt window has closed, or reports
    /// exhaustion once the last window has.
    public mutating func tick(nowMicros: UInt64) -> Tick {
        guard !finished,
              nowMicros &- lastMessage1Micros >= retry.intervalMicroseconds
        else { return .wait }
        guard counters.message1Transmissions < UInt64(retry.attempts) else {
            return .exhausted
        }
        guard let carriage = try? message1Carriage(nowMicros: nowMicros) else {
            return .exhausted
        }
        return .retransmit(carriage)
    }

    /// Feeds one received datagram.
    public mutating func ingest(
        _ datagram: ArraySlice<UInt8>, nowMicros: UInt64
    ) -> Ingest {
        guard !finished else { return .ignored }
        guard let (envelope, payload) = try? Envelope.decode(datagram) else {
            counters.undecodableDatagrams += 1
            return .ignored
        }
        guard envelope.channel == .ctrl, let type = payload.first else {
            counters.otherDatagrams += 1
            return .ignored
        }
        switch type {
        case CtrlMessageType.retryChallenge:
            guard challengeAnsweredFor != counters.message1Transmissions else {
                counters.retryChallengesIgnored += 1
                return .ignored
            }
            guard let challenge = try? RetryChallenge.decode(payload),
                  let resubmission = try? RetryHandshake1(
                      echoing: challenge, message1: message1
                  ).encode(),
                  let carriage = try? Self.carriage(
                      payload: resubmission, nowMicros: nowMicros)
            else {
                counters.malformedRetryChallenges += 1
                return .ignored
            }
            counters.retryChallengesAnswered += 1
            challengeAnsweredFor = counters.message1Transmissions
            return .reply(carriage)

        case CtrlMessageType.noiseHandshake2:
            var candidate = session
            do {
                _ = try candidate.readMessage2(payload.dropFirst())
                let transport = try candidate.makeTransport()
                session = candidate
                finished = true
                return .established(transport)
            } catch {
                counters.rejectedMessage2 += 1
                return .rejectedMessage2(error)
            }

        default:
            counters.otherDatagrams += 1
            return .ignored
        }
    }

    private mutating func message1Carriage(
        nowMicros: UInt64
    ) throws -> [UInt8] {
        let carriage = try Self.carriage(
            payload: [CtrlMessageType.noiseHandshake1] + message1,
            nowMicros: nowMicros)
        counters.message1Transmissions += 1
        lastMessage1Micros = nowMicros
        return carriage
    }

    /// One bare pre-transport CTRL datagram: chan 0, seq 0, the client's
    /// monotonic µs, the typed payload unsealed.
    private static func carriage(
        payload: [UInt8], nowMicros: UInt64
    ) throws -> [UInt8] {
        try Envelope(
            channel: .ctrl,
            seq: ChannelSeq(rawValue: 0),
            frame: FrameNumber(rawValue: 0),
            timestamp: nowMicros,
            fec: 0
        ).encode(payload: payload)
    }
}
