import LyteWire

/// One Host session's sans-IO reliable carrier state: the Wire endpoint, its
/// next PTO wake in the session's nanosecond domain, and the fresh envelope
/// sequence shared by every datagram on that channel.
struct SessionArqLane: Sendable {
    private(set) var nextDeadlineNanoseconds: UInt64?
    private(set) var pendingEnvelopeSequence: ChannelSeq

    private var endpoint: ArqEndpoint<HostClock>

    init(
        channel: ChannelId,
        config: ArqConfig,
        initialEnvelopeSequence: ChannelSeq = ChannelSeq(rawValue: 0)
    ) {
        self.pendingEnvelopeSequence = initialEnvelopeSequence
        self.endpoint = ArqEndpoint(channel: channel, config: config)
    }

    var isQuiescent: Bool { endpoint.isQuiescent }

    mutating func send(_ message: [UInt8], now: UInt64) throws {
        try endpoint.send(message: message, now: instant(now))
    }

    mutating func sendOneShot(
        _ message: [UInt8], group: ArqGroupId, now: UInt64
    ) throws {
        try endpoint.sendOneShot(
            message: message, group: group, now: instant(now)
        )
    }

    mutating func ingest(
        _ payload: ArraySlice<UInt8>, now: UInt64
    ) -> [ArqEvent] {
        endpoint.ingest(payload: payload, now: instant(now))
    }

    /// Polls once and retains the endpoint's next timer in Session's ns
    /// domain. Datagram payloads are already packed to the carrier ceiling.
    mutating func poll(now: UInt64) -> [[UInt8]] {
        let (datagrams, deadline) = endpoint.poll(now: instant(now))
        nextDeadlineNanoseconds = deadline.map {
            $0.microseconds &* 1_000
        }
        return datagrams
    }

    /// Advances the channel envelope sequence only after sealing and pacer
    /// admission succeeded. Wire sequence arithmetic deliberately wraps.
    @discardableResult
    mutating func commitEnvelopeSent() -> ChannelSeq {
        defer { pendingEnvelopeSequence = pendingEnvelopeSequence.next }
        return pendingEnvelopeSequence
    }

    private func instant(_ nanoseconds: UInt64) -> HostTimestamp {
        HostTimestamp(microseconds: nanoseconds / 1_000)
    }
}
