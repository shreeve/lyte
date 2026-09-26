import HostSession
import HostWire
import LyteWire
import LyteWireTestKit

/// The client side of a host gate: whatever absorbs the session's
/// datagrams and answers with its own.
public protocol HostSessionClient {
    /// Delivers one host datagram at virtual µs `nowMicros`.
    mutating func receiveFromHost(_ bytes: [UInt8], nowMicros: UInt64) throws
    /// The client's due output at `nowMicros`.
    mutating func pollOut(nowMicros: UInt64) throws -> [[UInt8]]
    /// Grows whenever the client learns something; `settle` stops once
    /// neither this nor the forwarded count moves.
    var progressMark: Int { get }
}

extension SealedCtrlPeer: HostSessionClient where ClockDomain == ClientClock {
    public mutating func receiveFromHost(
        _ bytes: [UInt8], nowMicros: UInt64
    ) throws {
        try absorb(bytes, nowMicros: nowMicros)
    }

    public var progressMark: Int { received.count }
}

/// A shipping `HostWire.Session` behind a `HandshakeAcceptor`, as the
/// listening shell composes them, with UDP replaced by an outbox and time
/// by the caller's virtual microseconds (session `now` = µs × 1000 ns,
/// `hostMicroseconds` = µs). Datagrams reach the client only through
/// `deliver`, which advances the `forwarded` cursor over `sent`.
public final class HostSessionHarness {
    private final class Outbox {
        var datagrams: [VideoChannelDatagram] = []
    }

    /// Nil until a client's message 1 is answered.
    public private(set) var currentSession: Session?
    /// The answered session; a gate reads it only after connecting.
    public var session: Session { currentSession! }
    /// The listener's admission, shared by every session answered here.
    public var acceptor: HandshakeAcceptor
    /// Where client datagrams arrive from; a gate moves it to roam.
    public var tuple: FourTuple
    /// The RetryChallenges the acceptor minted, in order.
    public private(set) var challenges: [[UInt8]] = []
    private let config: SessionConfig
    private let rng: any RandomNumberGenerator
    private let sendAccounting: SessionSendAccounting
    private let outbox = Outbox()
    /// How many of `sent` have been delivered to the client.
    public var forwarded = 0

    public init(
        config: SessionConfig,
        acceptor: HandshakeAcceptor.Config = HandshakeAcceptor.Config(
            hostStatic: .generate()),
        tuple: FourTuple,
        rng: some RandomNumberGenerator,
        sendAccounting: SessionSendAccounting = .pacerRelease
    ) {
        self.config = config
        self.acceptor = HandshakeAcceptor(config: acceptor)
        self.tuple = tuple
        self.rng = rng
        self.sendAccounting = sendAccounting
    }

    /// Every datagram the sessions released, in pacer order.
    public var sent: [VideoChannelDatagram] { outbox.datagrams }

    /// Delivers the client's message 1 at instant 0 and pumps the
    /// session's reply (message 2 and what establishment queues).
    @discardableResult
    public func connect(
        _ client: inout SealedCtrlPeer<ClientClock>,
        clientMicros: UInt64 = 500
    ) throws -> [SessionEvent] {
        receive(try client.message1Datagram(timestamp: clientMicros), at: 0)
    }

    /// A client dialing the acceptor's Noise static, connected; when
    /// `declaring` is set, its capability declaration is queued at 1 ms. Opens
    /// only CTRL unless `openChannels` says otherwise.
    public func connectClient(
        declaring capabilities: Capabilities?,
        openChannels: Set<ChannelId>? = [.ctrl],
        arqConfig: ArqConfig = ArqConfig()
    ) throws -> SealedCtrlPeer<ClientClock> {
        var client = try SealedCtrlPeer<ClientClock>(
            initiatorTo: acceptor.hostStaticPublicKey, arqConfig: arqConfig
        )
        client.openChannels = openChannels
        try connect(&client)
        if let capabilities {
            try client.declare(capabilities, as: .client, nowMicros: 1_000)
        }
        return client
    }

    /// One client datagram in from `tuple` at virtual µs `t`, then a
    /// pump. An answered session reads first; anything else is the
    /// acceptor's, and an authenticated message 1 replaces an unconfirmed
    /// session (its undelivered datagrams are dropped, as the shell's
    /// are).
    @discardableResult
    public func receive(_ datagram: [UInt8], at t: UInt64) -> [SessionEvent] {
        var events: [SessionEvent] = []
        if let currentSession {
            events = currentSession.receive(
                datagram, from: tuple, now: t * 1_000, hostMicroseconds: t
            )
        }
        if currentSession == nil
            || events.contains(.initiationWhileUnconfirmed) {
            switch acceptor.accept(
                datagram[...], from: tuple, now: t * 1_000
            ).verdict {
            case .authenticated(let handshake):
                outbox.datagrams.removeSubrange(forwarded...)
                let answered = try! Session.answer(
                    handshake, config: config,
                    now: t * 1_000, hostMicroseconds: t,
                    rng: rng, sendAccounting: sendAccounting,
                    send: { [outbox] in outbox.datagrams.append($0) }
                )
                currentSession = answered.session
                events += answered.events
            case .challenge(let challenge):
                challenges.append(challenge)
            case .notInitiation, .refused:
                break
            }
        }
        currentSession?.pump(now: t * 1_000)
        return events
    }

    /// The session's timers at virtual µs `t`, then a pump.
    @discardableResult
    public func advance(to t: UInt64) -> [SessionEvent] {
        guard let session = currentSession else { return [] }
        let events = session.advance(now: t * 1_000, hostMicroseconds: t)
        session.pump(now: t * 1_000)
        return events
    }

    /// Runs the session's timers wake by wake, each rounded up to a whole
    /// µs and at least 1 µs on, until `done` or the next wake passes
    /// virtual µs `horizon`; returns their events.
    @discardableResult
    public func service(
        t: inout UInt64, through horizon: UInt64,
        until done: () -> Bool = { false }
    ) -> [SessionEvent] {
        var events: [SessionEvent] = []
        currentSession?.pump(now: t * 1_000)
        while !done(), let wake = currentSession?.nextWake(now: t * 1_000) {
            let next = max(t + 1, (wake + 999) / 1_000)
            guard next <= horizon else { break }
            t = next
            events += advance(to: t)
        }
        return events
    }

    /// Removes and returns, in order, the not-yet-forwarded datagrams
    /// `selectedBy` picks; the rest stay queued for `deliver`.
    public func take(
        where selectedBy: (VideoChannelDatagram) -> Bool
    ) -> [VideoChannelDatagram] {
        let pending = outbox.datagrams[forwarded...]
        outbox.datagrams.removeSubrange(forwarded...)
        var taken: [VideoChannelDatagram] = []
        for datagram in pending {
            if selectedBy(datagram) {
                taken.append(datagram)
            } else {
                outbox.datagrams.append(datagram)
            }
        }
        return taken
    }

    /// Hands every not-yet-forwarded datagram to the client.
    public func deliver<Client: HostSessionClient>(
        to client: inout Client, at t: UInt64
    ) throws {
        while forwarded < outbox.datagrams.count {
            try client.receiveFromHost(
                outbox.datagrams[forwarded].bytes, nowMicros: t
            )
            forwarded += 1
        }
    }

    /// One direct exchange pass at virtual µs `t`: host timers, host →
    /// client, then each client datagram in with its replies forwarded.
    /// Returns the host's events in order.
    public func exchange<Client: HostSessionClient>(
        _ client: inout Client, at t: UInt64
    ) throws -> [SessionEvent] {
        var events = advance(to: t)
        try deliver(to: &client, at: t)
        for datagram in try client.pollOut(nowMicros: t) {
            events += receive(datagram, at: t)
            try deliver(to: &client, at: t)
        }
        return events
    }

    /// Exchange passes `step` µs apart until three in a row move nothing.
    /// `onEvent` sees each pass's host events after the pass.
    public func settle<Client: HostSessionClient>(
        _ client: inout Client,
        t: inout UInt64,
        step: UInt64 = 2_000,
        onEvent: (SessionEvent) -> Void = { _ in }
    ) throws {
        var idle = 0
        while idle < 3 {
            t += step
            let before = (forwarded, client.progressMark)
            for event in try exchange(&client, at: t) { onEvent(event) }
            idle = (forwarded, client.progressMark) == before ? idle + 1 : 0
        }
    }
}

/// A gate's own client: a `SealedCtrlPeer` plus the evidence that gate
/// records in `absorb`. The peer's CTRL surface is forwarded so gate
/// bodies read `client.arq`, `client.take(type:)`, `client.pollOut`.
public protocol PeerBackedClient: HostSessionClient {
    var peer: SealedCtrlPeer<ClientClock> { get set }
    /// One host datagram through the peer, judged by the gate.
    mutating func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws
}

extension PeerBackedClient {
    public var arq: ArqEndpoint<ClientClock> {
        get { peer.arq }
        set { peer.arq = newValue }
    }

    public var transport: NoiseTransport? {
        get { peer.transport }
        set { peer.transport = newValue }
    }

    public var received: [(group: ArqGroupId, bytes: [UInt8])] {
        get { peer.received }
        set { peer.received = newValue }
    }

    public mutating func take(type: UInt8) -> [[UInt8]] {
        peer.take(type: type)
    }

    public mutating func message1Datagram(
        clientMicros: UInt64
    ) throws -> [UInt8] {
        try peer.message1Datagram(timestamp: clientMicros)
    }

    public mutating func ctrlDatagram(
        body: [UInt8], sealed: Bool, clientMicros: UInt64
    ) throws -> [UInt8] {
        try peer.datagram(body: body, sealed: sealed, timestamp: clientMicros)
    }

    public mutating func pollOut(nowMicros: UInt64) throws -> [[UInt8]] {
        try peer.pollOut(nowMicros: nowMicros)
    }

    public mutating func receiveFromHost(
        _ bytes: [UInt8], nowMicros: UInt64
    ) throws {
        try absorb(bytes, nowMicros: nowMicros)
    }

    public var progressMark: Int { peer.received.count }
}

extension Session {
    /// The encoder-loop poll as a Bool: whether a fresh IDR is owed.
    public func takeFreshKeyframeRequest() -> Bool {
        !takeFreshKeyframeDemand().isEmpty
    }

    /// A session answering the client's `message1Datagram` from `tuple`,
    /// admitted by a fresh acceptor for `hostStatic`: how a gate stands
    /// up an answered session on its own sink.
    public static func answering(
        _ message1Datagram: [UInt8],
        hostStatic: NoiseKeyPair,
        from tuple: FourTuple,
        config: SessionConfig,
        now: UInt64 = 0,
        rng: some RandomNumberGenerator,
        sendAccounting: SessionSendAccounting = .pacerRelease,
        send: @escaping (VideoChannelDatagram) -> Void
    ) throws -> (session: Session, events: [SessionEvent]) {
        var acceptor = HandshakeAcceptor(
            config: HandshakeAcceptor.Config(hostStatic: hostStatic))
        guard case .authenticated(let handshake) = acceptor.accept(
            message1Datagram[...], from: tuple, now: now
        ).verdict else { throw HostSessionHarnessError.notAuthenticated }
        return try answer(
            handshake, config: config,
            now: now, hostMicroseconds: now / 1_000,
            rng: rng, sendAccounting: sendAccounting, send: send)
    }
}

public enum HostSessionHarnessError: Error {
    case notAuthenticated
}

extension VideoChannel {
    /// Both halves of a frame's ingest at once: packetize at this
    /// channel's shard budget, then enqueue; returns the shard count.
    /// Throws on non-frame-shaped bytes, a lying keyframe flag or an
    /// unprotectable size.
    @discardableResult
    public func ingest(
        frame annexB: [UInt8],
        frameNumber: FrameNumber,
        captureTimestampMicroseconds: UInt64,
        isKeyframe: Bool,
        lastInputSeq: UInt32? = nil,
        now: UInt64
    ) throws -> Int {
        ingestPrepared(
            try Self.prepareFrame(
                annexB, isKeyframe: isKeyframe,
                config: preparationConfig(
                    hasLastInputSeq: lastInputSeq != nil)),
            frameNumber: frameNumber,
            captureTimestampMicroseconds: captureTimestampMicroseconds,
            lastInputSeq: lastInputSeq, now: now)
    }
}

/// A frame-shaped Annex-B blob of exactly `byteCount` bytes: a 4-byte start
/// code, a TRAIL_R NAL header (IDR_W_RADL with `irap`), and padding that can
/// never form a start code.
public func syntheticFrame(byteCount: Int, irap: Bool = false) -> [UInt8] {
    precondition(byteCount >= 6)
    return [0, 0, 0, 1, irap ? 0x26 : 0x02, 0x01]
        + [UInt8](repeating: 0xAA, count: byteCount - 6)
}
