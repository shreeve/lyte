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

    /// The longest round trip a sample may claim. A path slower than this
    /// cannot stream anyway, and the bound keeps every RTT sum the fit and
    /// the repair gate form far from overflow.
    public static let maxPlausibleRttMicroseconds: Int64 = 5_000_000

    /// A sample fit to model the host clock: its RTT is a real duration.
    public var isPlausible: Bool {
        (0...Self.maxPlausibleRttMicroseconds).contains(rttMicroseconds)
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
/// A mirror closes a sample only when its t3 is the one this book sent and
/// the sample is plausible: every other timestamp is host-chosen, and a
/// forged turnaround or RTT must never reach the clock fit.
public struct ClientBeaconEchoBook: Sendable {
    /// Echoed beacons whose mirror is still awaited. The host mirrors the
    /// last echo, so a handful covers reordering.
    public static let maxPendingEchoes = 16

    private struct Pending: Sendable {
        var seq: UInt32
        var t1: HostTimestamp
        var t2: ClientTimestamp
        var t3: ClientTimestamp
    }
    private var pending: [Pending] = []
    /// Mirrors that matched a pending echo but closed no sample.
    public private(set) var mirrorsRefused: UInt64 = 0

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
        pending.append(Pending(
            seq: beacon.beaconSeq, t1: beacon.hostSend, t2: t2, t3: t3))
        if pending.count > Self.maxPendingEchoes {
            pending.removeFirst(pending.count - Self.maxPendingEchoes)
        }
        guard let mirror = beacon.lastEcho,
              let match = pending.first(where: { $0.seq == mirror.beaconSeq })
        else { return (echo, nil) }
        pending.removeAll { $0.seq == mirror.beaconSeq }
        guard mirror.clientSend == match.t3 else {
            mirrorsRefused += 1
            return (echo, nil)
        }
        let outbound = Int64(bitPattern:
            match.t2.microseconds &- match.t1.microseconds)
        let inbound = Int64(bitPattern:
            match.t3.microseconds &- mirror.hostReceive.microseconds)
        let roundTrip = Int64(bitPattern:
            mirror.hostReceive.microseconds &- match.t1.microseconds)
        let turnaround = match.t3.microseconds(since: match.t2)
        let sample = ClockSample(
            beaconSeq: mirror.beaconSeq,
            offsetMicroseconds: (outbound &+ inbound) / 2,
            rttMicroseconds: roundTrip &- turnaround,
            measuredAt: match.t2)
        guard turnaround >= 0, sample.isPlausible else {
            mirrorsRefused += 1
            return (echo, nil)
        }
        return (echo, sample)
    }
}
