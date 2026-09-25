import LyteWire

/// A sans-IO stand-in for the far end of a Lyte session in tests: Noise IK
/// (either role), sealed datagrams on any channel, a reliable CTRL
/// `ArqEndpoint` (plus an optional chan-8 one), and a received-message log.
/// It holds no policy: `absorb` classifies what arrived and the caller
/// decides what it means.
public struct SealedCtrlPeer<ClockDomain>: Sendable {
    public typealias Instant = WireTimestamp<ClockDomain>

    /// What one received datagram turned out to be.
    public enum Inbound: Sendable {
        /// Initiator only: bare message 2 completed the handshake.
        case handshakeCompleted
        /// The transport's replay window refused it (a network
        /// duplicate or a stale sequence), or it repeats the bare message 2
        /// that completed the handshake — routine, never an error.
        case duplicate
        /// ARQ bytes (the opened plaintext), ingested by the envelope
        /// channel's endpoint. Ordered CTRL messages are already appended
        /// to `received`.
        case reliable(Envelope, [UInt8], [ArqEvent])
        /// Any other opened plaintext (beacons, exempt CTRL types,
        /// media shards) for the caller to judge.
        case plain(Envelope, [UInt8])
        /// A channel outside `openChannels`; left sealed.
        case unopened(Envelope)
    }

    public enum PeerError: Error, Equatable, Sendable {
        /// Pre-transport, the initiator expects only bare CTRL message 2.
        case expectedMessage2(channel: UInt8, type: UInt8?)
        case noTransport
        case wrongRole
    }

    public let role: NoiseRole
    public let staticKeys: NoiseKeyPair
    /// Stamped as a TLV on every datagram this peer sends (the host's
    /// every-packet rule). Nil sends bare envelopes (the client role).
    public var connectionId: ConnectionId?
    /// Channels `absorb` opens; others come back `.unopened`. Nil opens
    /// every channel.
    public var openChannels: Set<ChannelId>?
    public private(set) var handshake: NoiseSession?
    public var transport: NoiseTransport?
    public var arq: ArqEndpoint<ClockDomain>
    /// The chan-8 endpoint, for peers that carry bulk.
    public var bulkArq: ArqEndpoint<ClockDomain>?
    /// Optional capability negotiation (see `declare` / `receiveDeclaration`).
    public var negotiator: CapabilityNegotiator?
    /// Ordered CTRL messages delivered so far, not yet taken.
    public var received: [(group: ArqGroupId, bytes: [UInt8])] = []
    private var seqs: [ChannelId: UInt16] = [:]

    /// The client role: dials `remoteStaticPublicKey`.
    public init(
        initiatorTo remoteStaticPublicKey: [UInt8],
        staticKeys: NoiseKeyPair = .generate(),
        arqConfig: ArqConfig = ArqConfig()
    ) throws {
        self.role = .initiator
        self.staticKeys = staticKeys
        self.handshake = try NoiseSession(
            role: .initiator,
            staticKeys: staticKeys,
            remoteStaticPublicKey: remoteStaticPublicKey
        )
        self.arq = ArqEndpoint(channel: .ctrl, config: arqConfig)
    }

    /// The host role: answers message 1. With a `connectionId`, the
    /// CTRL (and bulk) endpoints pack for the conn-id-tagged carrier.
    public init(
        responderWith staticKeys: NoiseKeyPair = .generate(),
        connectionId: ConnectionId? = nil,
        arqConfig: ArqConfig = ArqConfig(),
        carriesBulk: Bool = false
    ) {
        self.role = .responder
        self.staticKeys = staticKeys
        self.connectionId = connectionId
        var config = arqConfig
        if connectionId != nil {
            config.maxDatagramPayloadByteCount = min(
                config.maxDatagramPayloadByteCount,
                WireBudget.maxConnectionIdTaggedPlaintextByteCount
            )
        }
        self.arq = ArqEndpoint(channel: .ctrl, config: config)
        if carriesBulk {
            self.bulkArq = ArqEndpoint(channel: .bulkTransfer, config: config)
        }
    }

    public var isEstablished: Bool { transport != nil }

    /// The next envelope seq this peer will stamp on `channel`.
    public func nextSeq(on channel: ChannelId) -> UInt16 {
        seqs[channel] ?? 0
    }

    // MARK: Handshake

    /// Initiator: bare CTRL message 1.
    public mutating func message1Datagram(timestamp: UInt64) throws -> [UInt8] {
        guard role == .initiator, var noise = handshake else {
            throw PeerError.wrongRole
        }
        let message1 = try noise.writeMessage1()
        handshake = noise
        return try datagram(
            body: [CtrlMessageType.noiseHandshake1] + message1,
            sealed: false, timestamp: timestamp
        )
    }

    /// Responder: consumes a datagram and, when it is bare CTRL message
    /// 1, completes the handshake and returns bare message 2 (see
    /// `answer(message1:)`). Anything else returns nil.
    public mutating func answerMessage1(
        _ datagram: [UInt8]
    ) throws -> [UInt8]? {
        guard role == .responder else { throw PeerError.wrongRole }
        guard let (envelope, payload) = try? Envelope.decode(datagram[...]),
              envelope.channel == .ctrl,
              payload.first == CtrlMessageType.noiseHandshake1
        else { return nil }
        return try answer(message1: payload.dropFirst())
    }

    /// Responder: reads Noise message 1 (the bytes after the type
    /// byte), completes the handshake, and returns the bare message-2
    /// CTRL datagram (conn-id tagged when set, timestamp 0).
    public mutating func answer(
        message1: ArraySlice<UInt8>
    ) throws -> [UInt8] {
        guard role == .responder else { throw PeerError.wrongRole }
        var responder = try NoiseSession(role: .responder, staticKeys: staticKeys)
        _ = try responder.readMessage1(message1)
        let message2 = try responder.writeMessage2()
        transport = try responder.makeTransport()
        handshake = responder
        return try datagram(
            body: [CtrlMessageType.noiseHandshake2] + message2,
            sealed: false, timestamp: 0
        )
    }

    // MARK: Send

    /// One datagram on `channel` with this peer's next seq for it:
    /// sealed under the transport (header as AAD) unless `sealed` is
    /// false. `extensions` follow the conn-id TLV, if any.
    public mutating func datagram(
        channel: ChannelId = .ctrl,
        body: [UInt8],
        sealed: Bool = true,
        timestamp: UInt64,
        extensions: [WireExtension] = []
    ) throws -> [UInt8] {
        let seq = seqs[channel] ?? 0
        seqs[channel] = seq &+ 1
        let envelope = Envelope(
            channel: channel,
            seq: ChannelSeq(rawValue: seq),
            frame: FrameNumber(rawValue: 0),
            timestamp: timestamp,
            fec: 0,
            extensions: (connectionId.map { [$0.wireExtension] } ?? [])
                + extensions
        )
        guard sealed else { return try envelope.encode(payload: body) }
        guard transport != nil else { throw PeerError.noTransport }
        return try transport!.sealDatagram(envelope, plaintext: body)
    }

    /// Queues `message` on the CTRL ordered stream.
    public mutating func send(_ message: [UInt8], nowMicros: UInt64) throws {
        try arq.send(message: message, now: Instant(microseconds: nowMicros))
    }

    /// Queues `message` on the chan-8 ordered stream.
    public mutating func sendBulk(_ message: [UInt8], nowMicros: UInt64) throws {
        try bulkArq!.send(message: message, now: Instant(microseconds: nowMicros))
    }

    /// Due ARQ output from the CTRL endpoint, then chan 8's, each sealed
    /// on its own channel. Empty before the transport exists.
    public mutating func pollOut(nowMicros: UInt64) throws -> [[UInt8]] {
        guard transport != nil else { return [] }
        let now = Instant(microseconds: nowMicros)
        var out = try arq.poll(now: now).datagrams.map {
            try datagram(body: $0, timestamp: nowMicros)
        }
        if bulkArq != nil {
            for body in bulkArq!.poll(now: now).datagrams {
                out.append(try datagram(
                    channel: .bulkTransfer, body: body, timestamp: nowMicros
                ))
            }
        }
        return out
    }

    // MARK: Receive

    /// Opens one received datagram, or nil when the replay window
    /// refuses it as a duplicate/stale.
    public mutating func open(
        _ bytes: [UInt8]
    ) throws -> (envelope: Envelope, plaintext: [UInt8])? {
        guard transport != nil else { throw PeerError.noTransport }
        do {
            return try transport!.openDatagram(bytes)
        } catch NoiseError.replayedSequence, NoiseError.staleSequence {
            return nil
        }
    }

    /// One received datagram: completes the initiator's handshake, opens,
    /// and feeds ARQ bytes to the channel's endpoint.
    @discardableResult
    public mutating func absorb(
        _ bytes: [UInt8], nowMicros: UInt64
    ) throws -> Inbound {
        if transport == nil, role == .initiator, var noise = handshake {
            let (envelope, payload) = try Envelope.decode(bytes)
            guard envelope.channel == .ctrl,
                  payload.first == CtrlMessageType.noiseHandshake2
            else {
                throw PeerError.expectedMessage2(
                    channel: envelope.channel.rawValue, type: payload.first
                )
            }
            _ = try noise.readMessage2(payload.dropFirst())
            transport = try noise.makeTransport()
            handshake = noise
            return .handshakeCompleted
        }
        if let openChannels {
            let (envelope, _) = try Envelope.decode(bytes)
            guard openChannels.contains(envelope.channel) else {
                return .unopened(envelope)
            }
        }
        let opened: (envelope: Envelope, plaintext: [UInt8])?
        do {
            opened = try open(bytes)
        } catch _ where role == .initiator && Self.isBareMessage2(bytes) {
            return .duplicate
        }
        guard let (envelope, plaintext) = opened else { return .duplicate }
        guard plaintext.first == CtrlMessageType.arqSegment
                || plaintext.first == CtrlMessageType.arqAck
        else { return .plain(envelope, plaintext) }
        let now = Instant(microseconds: nowMicros)
        switch envelope.channel {
        case .ctrl:
            let events = arq.ingest(payload: plaintext, now: now)
            for case .message(let group, let bytes) in events {
                received.append((group, bytes))
            }
            return .reliable(envelope, plaintext, events)
        case .bulkTransfer where bulkArq != nil:
            let events = bulkArq!.ingest(payload: plaintext, now: now)
            return .reliable(envelope, plaintext, events)
        default:
            return .plain(envelope, plaintext)
        }
    }

    /// A bare CTRL message 2: after establishment, a network duplicate of
    /// the datagram that completed the handshake.
    private static func isBareMessage2(_ bytes: [UInt8]) -> Bool {
        guard let (envelope, payload) = try? Envelope.decode(bytes) else {
            return false
        }
        return envelope.channel == .ctrl
            && payload.first == CtrlMessageType.noiseHandshake2
    }

    /// Removes and returns every received message whose type byte is
    /// `type`, in arrival order.
    public mutating func take(type: UInt8) -> [[UInt8]] {
        let hits = received.filter { $0.bytes.first == type }.map(\.bytes)
        received.removeAll { $0.bytes.first == type }
        return hits
    }

    // MARK: Capabilities

    /// Starts capability negotiation in `role` and queues the declaration
    /// on the ordered stream.
    public mutating func declare(
        _ local: Capabilities, as role: CapabilityRole, nowMicros: UInt64
    ) throws {
        var negotiator = CapabilityNegotiator(role: role, local: local)
        if let declaration = negotiator.start() {
            try send(declaration.encode(), nowMicros: nowMicros)
        }
        self.negotiator = negotiator
    }

    /// Feeds the peer's 0x0F to the negotiator: the agreed set, or nil
    /// when the bytes are not a declaration or nothing settled.
    /// Negotiation failures throw.
    public mutating func receiveDeclaration(
        _ message: [UInt8]
    ) throws -> Capabilities? {
        guard negotiator != nil,
              let declaration = try? CapabilityDeclaration.decode(message),
              case .agreed(let set) = try negotiator!.receive(declaration)
        else { return nil }
        return set
    }
}
