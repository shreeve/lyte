// HandshakeAcceptor: the listening service's admission of client
// handshakes. One acceptor serves the whole process, across every session
// it answers, so the flood gate's bucket, cookie mode, address shares and
// admitted-cookie ring, and the memory of answered message 1s, never reset
// when a session ends or an unconfirmed answer is discarded.
//
// It is the one reader of a handshake initiation: a bare CTRL carriage
// whose payload is a Noise message 1 (0x05) or a RetryHandshake1 (0x14)
// echoing a cookie. For each it decides, in order: a message 1 this
// process already answered is refused unread; the HandshakeGate admits,
// challenges (a stateless RetryChallenge datagram for the caller to send
// to the asking tuple) or refuses; an admitted message 1 is read on fresh
// responder state, and its client static must be in the paired set when
// one is configured. An authenticated message 1 is handed back with its
// message 2 and transport, and only then remembered as answered; `Session`
// sends the answer.
//
// Sans-IO: `now` is injected monotonic ns.

import LyteWire

/// A client message 1 that passed admission and authentication, with the
/// responder's message 2 and the transport it completed.
public struct AuthenticatedHandshake: Sendable {
    /// Where message 1 arrived from: the session's first primary path.
    public let clientTuple: FourTuple
    public let message1: [UInt8]
    public let remoteStaticPublicKey: [UInt8]
    package let message2: [UInt8]
    package let transport: NoiseTransport
}

public struct HandshakeAcceptor: Sendable {
    public struct Config: Sendable {
        public var hostStatic: NoiseKeyPair
        public var gate: HandshakeGate.Config
        /// Non-nil: only these client statics authenticate.
        public var allowedClientStaticPublicKeys: [[UInt8]]?

        public init(
            hostStatic: NoiseKeyPair,
            gate: HandshakeGate.Config = HandshakeGate.Config(),
            allowedClientStaticPublicKeys: [[UInt8]]? = nil
        ) {
            self.hostStatic = hostStatic
            self.gate = gate
            self.allowedClientStaticPublicKeys = allowedClientStaticPublicKeys
        }
    }

    public enum Refusal: Equatable, Sendable {
        /// A message 1 this process already answered: a replay, or a
        /// stale retransmit of a dial whose session is gone.
        case answeredBefore
        /// Over the gate's message-1 or cookie budget.
        case throttled
        /// A RetryHandshake1 whose cookie did not verify.
        case cookieInvalid
        /// Noise refused message 1, or its client static is not paired.
        case handshakeFailed(String)
    }

    public enum Verdict: Sendable {
        /// Not a handshake initiation; nothing was read.
        case notInitiation
        case refused(Refusal)
        /// Send this RetryChallenge (0x13) datagram, unsealed, to the
        /// tuple the initiation came from.
        case challenge(datagram: [UInt8])
        case authenticated(AuthenticatedHandshake)
    }

    public struct Decision: Sendable {
        public var verdict: Verdict
        /// Set when this arrival moved the gate's require-cookie dial.
        public var cookieModeChangedTo: Bool?
    }

    public struct Counters: Equatable, Sendable {
        /// Message 1s refused over a gate budget.
        public var throttled = 0
        /// RetryChallenges minted under flood.
        public var challengesMinted = 0
        /// RetryHandshake1s whose cookie verified.
        public var cookiesVerified = 0
        /// RetryHandshake1s whose cookie did not verify.
        public var cookiesRejected = 0
        /// Message 1s refused as answered before.
        public var answeredBefore = 0

        public init() {}
    }

    /// A handshake initiation's carriage.
    package struct Initiation {
        package var presentedCookie: ArraySlice<UInt8>?
        package var message1: ArraySlice<UInt8>
    }

    private let config: Config
    private var gate: HandshakeGate
    private var answered = AnsweredHandshakeMemory()
    /// The CTRL seq of the next RetryChallenge; the client reads only the
    /// channel and the type byte.
    private var challengeSeq: UInt16 = 0
    public private(set) var counters = Counters()

    public init(config: Config) {
        self.config = config
        gate = HandshakeGate(config: config.gate)
    }

    public var hostStaticPublicKey: [UInt8] { config.hostStatic.publicKey }
    /// Whether the flood dial currently demands a retry cookie.
    public var cookieMode: Bool { gate.cookieMode }

    public mutating func accept(
        _ datagram: ArraySlice<UInt8>, from tuple: FourTuple, now: UInt64
    ) -> Decision {
        guard let initiation = Self.parseInitiation(datagram) else {
            return Decision(verdict: .notInitiation)
        }
        guard !answered.contains(message1: initiation.message1) else {
            counters.answeredBefore += 1
            return Decision(verdict: .refused(.answeredBefore))
        }
        let decision = gate.admitMessage1(
            presentedCookie: initiation.presentedCookie,
            clientTuple: Self.cookieTuple(tuple),
            clientAddress: HandshakeGate.addressShareKey(tuple.remoteAddress),
            message1: initiation.message1,
            now: now
        )
        func decided(_ verdict: Verdict) -> Decision {
            Decision(
                verdict: verdict,
                cookieModeChangedTo: decision.cookieModeChangedTo)
        }
        switch decision.admission {
        case .admit:
            if initiation.presentedCookie != nil {
                counters.cookiesVerified += 1
            }
            return decided(authenticate(initiation.message1, from: tuple))
        case .challenge(let cookie):
            // A minted cookie is always within RetryChallenge's bounds.
            let datagram = try! Envelope(
                channel: .ctrl, seq: ChannelSeq(rawValue: challengeSeq),
                frame: FrameNumber(rawValue: 0), timestamp: 0, fec: 0
            ).encode(payload: RetryChallenge(cookie: cookie).encode())
            challengeSeq &+= 1
            counters.challengesMinted += 1
            return decided(.challenge(datagram: datagram))
        case .drop(.throttled):
            counters.throttled += 1
            return decided(.refused(.throttled))
        case .drop(.cookieInvalid):
            counters.cookiesRejected += 1
            return decided(.refused(.cookieInvalid))
        }
    }

    /// Reads message 1 on fresh responder state — a failed one (bad
    /// version, wrong static, garbage) burns nothing — applies the
    /// paired-set policy to the static it names, and writes message 2.
    private mutating func authenticate(
        _ message1: ArraySlice<UInt8>, from tuple: FourTuple
    ) -> Verdict {
        let handshake: AuthenticatedHandshake
        do {
            var responder = try NoiseSession(
                role: .responder, staticKeys: config.hostStatic)
            _ = try responder.readMessage1(message1)
            let remote = responder.remoteStaticPublicKey ?? []
            if let allowed = config.allowedClientStaticPublicKeys,
               !allowed.contains(remote) {
                return .refused(
                    .handshakeFailed("client static not in the paired set"))
            }
            let message2 = try responder.writeMessage2()
            handshake = AuthenticatedHandshake(
                clientTuple: tuple, message1: Array(message1),
                remoteStaticPublicKey: remote, message2: message2,
                transport: try responder.makeTransport())
        } catch {
            return .refused(.handshakeFailed(String(describing: error)))
        }
        answered.record(message1: message1)
        return .authenticated(handshake)
    }

    /// The one initiation parse; nil for anything else.
    package static func parseInitiation(
        _ datagram: ArraySlice<UInt8>
    ) -> Initiation? {
        guard let (envelope, payload) = try? Envelope.decode(datagram),
              envelope.channel == .ctrl else { return nil }
        switch payload.first {
        case CtrlMessageType.noiseHandshake1:
            return Initiation(
                presentedCookie: nil, message1: payload.dropFirst())
        case CtrlMessageType.retryHandshake1:
            guard let resubmission = try? RetryHandshake1.decode(payload)
            else { return nil }
            return Initiation(
                presentedCookie: resubmission.cookie[...],
                message1: resubmission.message1[...])
        default:
            return nil
        }
    }

    /// The opaque bytes the retry cookie binds address ownership to: the
    /// client's address ‖ port, within RetryCookie's 1…255-byte tuple
    /// bound ("255.255.255.255:65535" is 21 bytes).
    static func cookieTuple(_ tuple: FourTuple) -> [UInt8] {
        Array("\(tuple.remoteAddress):\(tuple.remotePort)".utf8)
    }
}
