import Synchronization
import LyteCore
import LyteTransport
import LyteWire
import LyteWireTestKit

/// A scripted host for client gates: a `SealedCtrlPeer` responder that
/// answers the client's pre-thread Noise handshake in process, then
/// speaks sealed CTRL (and chan 8) with whatever evidence the gate keeps.
public protocol ScriptedHost: AnyObject, NoiseHandshakeIO {
    var peer: SealedCtrlPeer<HostClock> { get set }
    /// Message 2 waiting for the client's handshake read.
    var handshakeOutbox: [[UInt8]] { get set }
    /// Runs once the responder transport exists, before message 2 is
    /// read — where a host queues its first reliable word.
    func didEstablish() throws
    /// One client datagram, judged by the gate.
    func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws
    /// Grows whenever the host records evidence; `settle` stops once
    /// nothing moves.
    var progressMark: Int { get }
}

extension ScriptedHost {
    public var staticKeys: NoiseKeyPair { peer.staticKeys }

    public var transport: NoiseTransport? {
        get { peer.transport }
        set { peer.transport = newValue }
    }

    public func didEstablish() throws {}

    // NoiseHandshakeIO — answered in process.

    public func sendToHost(_ datagram: [UInt8]) throws {
        guard let message2 = try peer.answerMessage1(datagram) else { return }
        try didEstablish()
        handshakeOutbox.append(message2)
    }

    public func receiveDatagram(timeoutMilliseconds: Int) throws -> [UInt8]? {
        handshakeOutbox.isEmpty ? nil : handshakeOutbox.removeFirst()
    }

    /// One host beat: due ARQ output, sealed on its channel.
    public func advance(nowMicros: UInt64) throws -> [[UInt8]] {
        try peer.pollOut(nowMicros: nowMicros)
    }

    /// A scripted host word onto the CTRL ordered stream (genuine
    /// traffic and hostile legs alike).
    public func injectReliable(_ message: [UInt8], nowMicros: UInt64) throws {
        try peer.send(message, nowMicros: nowMicros)
    }

    /// A scripted host word onto chan 8's ordered stream.
    public func injectBulk(_ message: [UInt8], nowMicros: UInt64) throws {
        try peer.sendBulk(message, nowMicros: nowMicros)
    }

    /// Declares `local` as the host (the first reliable word).
    public func declare(_ local: Capabilities) throws {
        try peer.declare(local, as: .host, nowMicros: 0)
    }
}

/// A scripted host that declares `localCapabilities` as its first reliable
/// word, records the agreement, and hands every reliable message (the
/// client's declaration included, after `agreed` is set) to `receive`.
/// Subclasses keep the evidence their gate asserts.
open class DeclaringHost: ScriptedHost {
    public var peer: SealedCtrlPeer<HostClock>
    public var handshakeOutbox: [[UInt8]] = []
    public let localCapabilities: Capabilities
    public var agreed: Capabilities?
    /// The type byte of every reliable CTRL message, in order.
    public var reliableTypes: [UInt8] = []
    /// Reliable messages received on any channel.
    public var reliableCount = 0

    open var progressMark: Int { reliableCount }

    /// Without `carriesBulk` only CTRL is opened.
    public init(
        localCapabilities: Capabilities,
        seed: UInt64,
        staticKeys: NoiseKeyPair = .generate(),
        carriesBulk: Bool = false
    ) {
        var rng = SplitMix64(seed: seed)
        peer = SealedCtrlPeer(
            responderWith: staticKeys,
            connectionId: ConnectionId.random(using: &rng),
            carriesBulk: carriesBulk)
        if !carriesBulk { peer.openChannels = [.ctrl] }
        self.localCapabilities = localCapabilities
    }

    open func didEstablish() throws {
        try declare(localCapabilities)
    }

    open func absorb(_ bytes: [UInt8], nowMicros: UInt64) throws {
        guard case .reliable(let envelope, _, let events) =
            try peer.absorb(bytes, nowMicros: nowMicros)
        else { return }
        for case .message(_, let message) in events {
            reliableCount += 1
            if envelope.channel == .ctrl {
                reliableTypes.append(message.first ?? 0)
                if message.first == CtrlMessageType.capabilityDeclaration,
                   let intersection = try peer.receiveDeclaration(message) {
                    agreed = intersection
                }
            }
            try receive(message, on: envelope.channel, nowMicros: nowMicros)
        }
    }

    open func receive(
        _ message: [UInt8], on channel: ChannelId, nowMicros: UInt64
    ) throws {}
}

/// Virtual microseconds a production core reads through its `now` closure.
public final class ManualMicrosClock: Sendable {
    private let stored: Mutex<UInt64>

    public init(_ start: UInt64 = 1_000) {
        stored = Mutex(start)
    }

    public var value: UInt64 {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }
}

/// What a harnessed core's callbacks append to; gates run single-threaded.
private final class CoreCollected: @unchecked Sendable {
    var outbound: [[UInt8]] = []
    var events: [LyteUdpSessionEvent] = []
}

/// The REAL `LyteUdpSessionCore` minus the socket, on a virtual clock,
/// piped directly to a `ScriptedHost`: the handshake runs through the
/// production `NoiseTransportCrypto`, outbound datagrams collect in
/// `outbound`, and `settle` shuttles both ways until quiet.
public final class ClientCoreHarness<Host: ScriptedHost>: @unchecked Sendable {
    public let host: Host
    public let crypto: NoiseTransportCrypto
    public let demux: ReceiveDemux
    public private(set) var core: LyteUdpSessionCore!
    private let collected = CoreCollected()
    /// How many of `outbound` the host has absorbed.
    public var forwarded = 0
    public let clock: ManualMicrosClock

    public init(
        host: Host,
        hostAddress: String = "10.0.0.249",
        hostPort: UInt16,
        clientKeys: NoiseKeyPair = .generate(),
        clock: ManualMicrosClock = ManualMicrosClock(),
        coreConfig: LyteUdpSessionCoreConfig = LyteUdpSessionCoreConfig(),
        imageHasher: @escaping @Sendable () -> any ClipboardImageHasher = {
            Sha256()
        }
    ) throws {
        self.host = host
        self.clock = clock
        let crypto = try NoiseTransportCrypto(
            hostAddress: hostAddress, hostPort: hostPort,
            hostStaticPublicKey: host.staticKeys.publicKey,
            staticKeys: clientKeys,
            retry: .init(attempts: 3, intervalMicroseconds: 200_000))
        try crypto.performHandshake(io: host)
        self.crypto = crypto
        self.demux = ReceiveDemux(crypto: crypto)
        let collected = self.collected
        let sender = TransportSender(crypto: crypto, transmit: { datagram in
            collected.outbound.append(datagram)
            return true
        })
        self.core = LyteUdpSessionCore(
            demux: demux,
            sender: sender,
            config: coreConfig,
            now: { ClientTimestamp(microseconds: clock.value) },
            imageHasher: imageHasher,
            videoSink: HeadlessVideoSink(),
            onEvent: { event in collected.events.append(event) })
    }

    /// Everything the client transmitted, in order.
    public var outbound: [[UInt8]] { collected.outbound }

    /// Every core event, in order.
    public var events: [LyteUdpSessionEvent] {
        get { collected.events }
        set { collected.events = newValue }
    }

    /// One host datagram through the real receive path.
    public func absorb(_ bytes: [UInt8], tMicros: UInt64) {
        let outcome = demux.ingest(
            datagram: bytes[...], arrivalMicroseconds: tMicros)
        if case .accepted = outcome {
            core.handleDatagram(outcome, arrivalMicroseconds: tMicros)
        }
    }

    /// Hands every not-yet-forwarded client datagram to the host.
    public func forwardToHost(nowMicros t: UInt64) throws {
        while forwarded < collected.outbound.count {
            try host.absorb(collected.outbound[forwarded], nowMicros: t)
            forwarded += 1
        }
    }

    /// Opens the core at 1 ms (its declaration leaves) and settles;
    /// returns the settled instant.
    @discardableResult
    public func openAndSettle() throws -> UInt64 {
        var t: UInt64 = 1_000
        clock.value = t
        try core.open(now: ClientTimestamp(microseconds: t))
        try settle(t: &t)
        return t
    }

    /// Direct-pipe beats 2 ms apart until three in a row move nothing:
    /// core tick, client → host, host beat → client, core tick again.
    public func settle(t: inout UInt64) throws {
        var idle = 0
        while idle < 3 {
            t += 2_000
            clock.value = t
            let before = (forwarded, host.progressMark, events.count)
            core.tick(now: ClientTimestamp(microseconds: t))
            try forwardToHost(nowMicros: t)
            for datagram in try host.advance(nowMicros: t) {
                absorb(datagram, tMicros: t)
            }
            core.tick(now: ClientTimestamp(microseconds: t))
            try forwardToHost(nowMicros: t)
            idle = (forwarded, host.progressMark, events.count) == before
                ? idle + 1 : 0
        }
    }
}
