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

/// A shipping `HostWire.Session` with UDP replaced by an outbox and time
/// by the caller's virtual microseconds (session `now` = µs × 1000 ns,
/// `hostMicroseconds` = µs). Datagrams reach the client only through
/// `deliver`, which advances the `forwarded` cursor over `sent`.
public final class HostSessionHarness {
    private final class Outbox {
        var datagrams: [VideoChannelDatagram] = []
    }

    public let session: Session
    public let tuple: FourTuple
    private let outbox: Outbox
    /// How many of `sent` have been delivered to the client.
    public var forwarded = 0

    public init(
        config: SessionConfig,
        tuple: FourTuple,
        now: UInt64 = 0,
        rng: some RandomNumberGenerator,
        sendAccounting: SessionSendAccounting = .pacerRelease
    ) {
        let outbox = Outbox()
        self.outbox = outbox
        self.tuple = tuple
        self.session = Session(
            config: config,
            clientTuple: tuple,
            now: now,
            rng: rng,
            sendAccounting: sendAccounting,
            send: { outbox.datagrams.append($0) }
        )
    }

    /// Every datagram the session released, in pacer order.
    public var sent: [VideoChannelDatagram] { outbox.datagrams }

    /// Delivers the client's message 1 at instant 0 and pumps the
    /// session's reply (message 2 and what establishment queues).
    @discardableResult
    public func connect(
        _ client: inout SealedCtrlPeer<ClientClock>,
        clientMicros: UInt64 = 500
    ) throws -> [SessionEvent] {
        let events = session.receive(
            try client.message1Datagram(timestamp: clientMicros),
            from: tuple, now: 0, hostMicroseconds: 0
        )
        session.pump(now: 0)
        return events
    }

    /// A client dialing this session's Noise static, connected; when
    /// `declaring` is set, its W7 declaration is queued at 1 ms. Opens
    /// only CTRL unless `openChannels` says otherwise.
    public func connectClient(
        declaring capabilities: Capabilities?,
        openChannels: Set<ChannelId>? = [.ctrl],
        arqConfig: ArqConfig = ArqConfig()
    ) throws -> SealedCtrlPeer<ClientClock> {
        guard case .noise(let hostStatic) = session.config.crypto else {
            preconditionFailure("connectClient needs a Noise session")
        }
        var client = try SealedCtrlPeer<ClientClock>(
            initiatorTo: hostStatic.publicKey, arqConfig: arqConfig
        )
        client.openChannels = openChannels
        try connect(&client)
        if let capabilities {
            try client.declare(capabilities, as: .client, nowMicros: 1_000)
        }
        return client
    }

    /// One client datagram in at virtual µs `t`, then a pump.
    @discardableResult
    public func receive(_ datagram: [UInt8], at t: UInt64) -> [SessionEvent] {
        let events = session.receive(
            datagram, from: tuple, now: t * 1_000, hostMicroseconds: t
        )
        session.pump(now: t * 1_000)
        return events
    }

    /// The session's timers at virtual µs `t`, then a pump.
    @discardableResult
    public func advance(to t: UInt64) -> [SessionEvent] {
        let events = session.advance(now: t * 1_000, hostMicroseconds: t)
        session.pump(now: t * 1_000)
        return events
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
