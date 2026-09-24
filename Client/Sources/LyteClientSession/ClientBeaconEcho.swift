import LyteWire

/// One raw clock observation, closed by a beacon's mirror of the host's
/// view of an earlier echo. Sign convention matches
/// BeaconEcho.clockSample: offset is client − host µs.
public struct ClockSample: Hashable, Sendable {
    /// The beaconSeq whose echo round-trip produced this sample.
    public var beaconSeq: UInt32
    public var offsetMicroseconds: Int64
    public var rttMicroseconds: Int64
    /// The exchange's client-time coordinate (its t2, the beacon's
    /// arrival). The mirror that closes the sample arrives a beacon later;
    /// the offset was true at the exchange, so its own instant is the
    /// honest abscissa.
    public var measuredAt: ClientTimestamp

    public init(beaconSeq: UInt32, offsetMicroseconds: Int64,
                rttMicroseconds: Int64, measuredAt: ClientTimestamp) {
        self.beaconSeq = beaconSeq
        self.offsetMicroseconds = offsetMicroseconds
        self.rttMicroseconds = rttMicroseconds
        self.measuredAt = measuredAt
    }
}

/// The beacon-echo exchange, IO-free. The host maps its clock over the
/// 1 Hz CTRL ClockBeacon; the client echoes it promptly and truthfully —
/// t2 (clientReceive) is the beacon's arrival, t3 (clientSend) the echo's
/// emit — so the host can stamp t4 on arrival and compute offset and RTT.
///
/// A beacon may mirror the host's view of the last echo it received (t3
/// verbatim, t4 as measured). With the t1/t2 this book remembered for that
/// beaconSeq, the client closes the same (offset, RTT) sample the host did.
/// No filtering happens here; HostClockModel owns that.
public struct ClientBeaconEchoBook: Sendable {
    /// Echoed beacons whose mirror is still awaited. The host mirrors the
    /// last echo, so a handful covers reordering.
    public static let maxPendingEchoes = 16

    private struct Pending: Sendable {
        var seq: UInt32
        var t1: HostTimestamp
        var t2: ClientTimestamp
    }
    private var pending: [Pending] = []

    public init() {}

    /// Answers one beacon: the echo to send, and the sample its mirror
    /// closed, if any. `receivedAt` and `sendingAt` must share one clock
    /// domain (t3 − t2 is the turnaround the host subtracts).
    public mutating func answer(
        _ beacon: ClockBeacon,
        receivedAt t2: ClientTimestamp,
        sendingAt t3: ClientTimestamp
    ) -> (echo: BeaconEcho, sample: ClockSample?) {
        let echo = BeaconEcho(
            beaconSeq: beacon.beaconSeq,
            hostSend: beacon.hostSend,
            clientReceive: t2,
            clientSend: t3)
        pending.append(Pending(seq: beacon.beaconSeq, t1: beacon.hostSend, t2: t2))
        if pending.count > Self.maxPendingEchoes {
            pending.removeFirst(pending.count - Self.maxPendingEchoes)
        }
        guard let mirror = beacon.lastEcho,
              let match = pending.first(where: { $0.seq == mirror.beaconSeq })
        else { return (echo, nil) }
        let outbound = Int64(bitPattern:
            match.t2.microseconds &- match.t1.microseconds)
        let inbound = Int64(bitPattern:
            mirror.clientSend.microseconds &- mirror.hostReceive.microseconds)
        let roundTrip = Int64(bitPattern:
            mirror.hostReceive.microseconds &- match.t1.microseconds)
        let turnaround = Int64(bitPattern:
            mirror.clientSend.microseconds &- match.t2.microseconds)
        pending.removeAll { $0.seq == mirror.beaconSeq }
        return (echo, ClockSample(
            beaconSeq: mirror.beaconSeq,
            offsetMicroseconds: (outbound &+ inbound) / 2,
            rttMicroseconds: roundTrip &- turnaround,
            measuredAt: match.t2))
    }
}
