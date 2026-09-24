import LyteWire

/// Outbound envelope sequencing: every channel is its own serial u16
/// stream, as the far side's gap tracking and the Noise extended counter
/// expect. A shell that seals on several threads allocates and seals in one
/// critical section, so allocation order is commit order.
public struct ClientEnvelopeSequencer: Sendable {
    private var nextSeq: [UInt8: ChannelSeq] = [:]

    public init() {}

    /// The next envelope on `channel`. `timestamp` is client monotonic µs;
    /// `extensions` ride inside the AAD (the conn-id tag on reliable CTRL).
    public mutating func envelope(
        channel: ChannelId,
        frame: FrameNumber = FrameNumber(rawValue: 0),
        timestamp: UInt64,
        extensions: [WireExtension] = []
    ) -> Envelope {
        let seq = nextSeq[channel.rawValue] ?? ChannelSeq(rawValue: 0)
        nextSeq[channel.rawValue] = seq.next
        return Envelope(
            channel: channel,
            seq: seq,
            frame: frame,
            timestamp: timestamp,
            fec: 0,
            extensions: extensions
        )
    }
}

/// The session's connection id: learned — never invented — from the first
/// authenticated host datagram that carries the TLV, then tagged on every
/// reliable datagram. Feed it only datagrams that unsealed, so a forged
/// first datagram cannot choose the id every later send carries.
public struct ClientConnectionIdBook: Sendable, Equatable {
    public private(set) var learned: ConnectionId?

    public init() {}

    /// Learns the id from an authenticated envelope. True on the first
    /// learn only.
    @discardableResult
    public mutating func learn(from envelope: Envelope) -> Bool {
        guard learned == nil,
              let claimed = try? ConnectionId.decode(
                  extensions: envelope.extensions)
        else { return false }
        learned = claimed
        return true
    }

    /// Adopts an id another endpoint already learned. First writer wins;
    /// nil is a no-op.
    public mutating func adopt(_ id: ConnectionId?) {
        if learned == nil { learned = id }
    }

    /// The TLV block a reliable datagram carries: the tag once learned.
    public var extensions: [WireExtension] {
        learned.map { [$0.wireExtension] } ?? []
    }
}
