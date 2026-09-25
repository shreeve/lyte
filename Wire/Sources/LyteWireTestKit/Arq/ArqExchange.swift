import LyteWire

extension Array where Element == ArqEvent {
    /// The delivered messages' bytes, in event order.
    public var messages: [[UInt8]] {
        compactMap { event in
            guard case .message(_, let bytes) = event else { return nil }
            return bytes
        }
    }
}

extension Array where Element == [UInt8] {
    /// Every ARQ frame in these datagram payloads, in order.
    public func arqFrames() throws -> [ArqFrame] {
        try flatMap { try ArqFrame.decodeAll($0) }
    }
}

extension ArqEndpoint {
    /// One lossless round at `now`: everything this endpoint's poll
    /// yields goes to `peer`, then everything the peer's poll yields comes
    /// back. Returns the peer's events, then this endpoint's.
    @discardableResult
    public mutating func exchange(
        with peer: inout ArqEndpoint, now: Instant
    ) -> (peer: [ArqEvent], local: [ArqEvent]) {
        var peerEvents: [ArqEvent] = []
        for datagram in poll(now: now).datagrams {
            peerEvents += peer.ingest(payload: datagram, now: now)
        }
        var localEvents: [ArqEvent] = []
        for datagram in peer.poll(now: now).datagrams {
            localEvents += ingest(payload: datagram, now: now)
        }
        return (peerEvents, localEvents)
    }

    /// Exchanges a round every `step` µs from `start` until both ends are
    /// quiescent or `maxRounds` have run. Returns the peer's events and
    /// the instant after the last round.
    @discardableResult
    public mutating func drain(
        with peer: inout ArqEndpoint, from start: UInt64 = 0,
        step: UInt64, maxRounds: Int
    ) -> (peer: [ArqEvent], end: UInt64) {
        var events: [ArqEvent] = []
        var now = start
        for _ in 0..<maxRounds where !(isQuiescent && peer.isQuiescent) {
            events += exchange(with: &peer, now: Instant(microseconds: now)).peer
            now += step
        }
        return (events, now)
    }
}
