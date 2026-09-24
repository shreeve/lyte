import LyteWire

/// Raw clock-mapping samples from the beacon/echo exchange.
public struct SessionClockStats: Equatable, Sendable {
    public var samples = 0
    public var lastOffsetMicroseconds: Int64?
    public var lastRttMicroseconds: Int64?
    public var minRttMicroseconds: Int64?
    /// The offset carried by the min-RTT sample — the least
    /// queue-polluted estimate (the min-filter idea, one sample deep).
    public var minRttOffsetMicroseconds: Int64?

    public init() {}
}

/// The sans-IO owner of the Host session's beacon clock.
///
/// `Session` adapts these values to sealed CTRL sends and estimator events;
/// this value owns cadence, successful-send sequence advancement, echo
/// mirroring, and raw offset/RTT books. A late timer wake emits at most one
/// catch-up beacon, preserves the existing beat when it is still ahead, and
/// otherwise starts one fresh interval from the late wake.
///
/// Every RTT sample is built from a t1 this clock recorded when the beacon
/// left, never from the echo's `hostSend`: the client controls every echo
/// byte. An echo naming no beacon still outstanding, or whose sample falls
/// outside `plausibleRttMicroseconds` (a turnaround longer than the round
/// trip, or a round trip past 10 s), yields no sample at all.
public struct SessionBeaconClock: Equatable, Sendable {
    /// The RTT range any sample may take: a 10 s round trip is already far
    /// past every consumer's horizon (the retransmit gate, the liveness
    /// clock), and bounding it keeps downstream EWMA arithmetic in range.
    public static let plausibleRttMicroseconds: ClosedRange<Int64> =
        0...10_000_000
    /// Beacons whose t1 stays matchable: at the 1 Hz default, an echo up
    /// to 8 s late still yields a sample.
    static let outstandingCapacity = 8

    public let intervalNanoseconds: UInt64
    public private(set) var nextDeadlineNanoseconds: UInt64?
    public private(set) var stats = SessionClockStats()

    private var nextSequence: UInt32 = 0
    /// t1 of the beacon the last `pendingBeacon` built, committed with its
    /// sequence by `noteBeaconSent`.
    private var pendingHostSend = HostTimestamp(microseconds: 0)
    private struct Outstanding: Equatable, Sendable {
        var seq: UInt32
        var hostSend: HostTimestamp
    }
    /// Beacons sent and not yet echoed, oldest first.
    private var outstanding: [Outstanding] = []
    private var lastEcho: ClockBeacon.LastEcho?

    public init(intervalNanoseconds: UInt64) {
        self.intervalNanoseconds = intervalNanoseconds
    }

    /// Arms an immediate session-start beacon for the next service pass.
    public mutating func armSessionStart(at now: UInt64) {
        nextDeadlineNanoseconds = now
    }

    /// Builds the Noise-handshake session-start beacon and arms its next beat.
    public mutating func makeSessionStartBeacon(
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> ClockBeacon {
        nextDeadlineNanoseconds = now + intervalNanoseconds
        return pendingBeacon(hostMicroseconds: hostMicroseconds)
    }

    /// Returns the one due beacon and re-arms cadence before IO is attempted.
    /// A refused send therefore waits for the next beat and retries the same
    /// sequence number; only `noteBeaconSent` advances it.
    public mutating func takeDueBeacon(
        now: UInt64,
        hostMicroseconds: UInt64
    ) -> ClockBeacon? {
        guard let due = nextDeadlineNanoseconds, now >= due else { return nil }
        var next = due + intervalNanoseconds
        if next <= now { next = now + intervalNanoseconds }
        nextDeadlineNanoseconds = next
        return pendingBeacon(hostMicroseconds: hostMicroseconds)
    }

    /// Commits exactly one successfully emitted beacon sequence and
    /// remembers its t1 for the echo.
    @discardableResult
    public mutating func noteBeaconSent() -> UInt32 {
        defer { nextSequence &+= 1 }
        if outstanding.count == Self.outstandingCapacity {
            outstanding.removeFirst()
        }
        outstanding.append(
            Outstanding(seq: nextSequence, hostSend: pendingHostSend))
        return nextSequence
    }

    /// Records one echo of an outstanding beacon, updates the minimum-RTT
    /// books, and retains the mirror fields for the next beacon. Nil when
    /// the echo names no outstanding beacon or its RTT is implausible;
    /// each beacon yields at most one sample.
    public mutating func accept(
        echo: BeaconEcho,
        hostMicroseconds: UInt64
    ) -> (offsetMicroseconds: Int64, rttMicroseconds: Int64)? {
        guard let index = outstanding.firstIndex(where: {
            $0.seq == echo.beaconSeq
        }) else { return nil }
        let hostReceive = HostTimestamp(microseconds: hostMicroseconds)
        var honest = echo
        honest.hostSend = outstanding[index].hostSend
        let sample = honest.clockSample(hostReceive: hostReceive)
        let roundTrip = Int64(bitPattern:
            hostReceive.microseconds &- honest.hostSend.microseconds)
        guard Self.plausibleRttMicroseconds.contains(sample.rttMicroseconds),
              sample.rttMicroseconds <= roundTrip
        else { return nil }
        outstanding.remove(at: index)
        stats.samples += 1
        stats.lastOffsetMicroseconds = sample.offsetMicroseconds
        stats.lastRttMicroseconds = sample.rttMicroseconds
        if stats.minRttMicroseconds.map({ sample.rttMicroseconds < $0 }) ?? true {
            stats.minRttMicroseconds = sample.rttMicroseconds
            stats.minRttOffsetMicroseconds = sample.offsetMicroseconds
        }
        lastEcho = ClockBeacon.LastEcho(
            beaconSeq: echo.beaconSeq,
            clientSend: echo.clientSend,
            hostReceive: hostReceive
        )
        return sample
    }

    private mutating func pendingBeacon(
        hostMicroseconds: UInt64
    ) -> ClockBeacon {
        pendingHostSend = HostTimestamp(microseconds: hostMicroseconds)
        return ClockBeacon(
            beaconSeq: nextSequence,
            hostSend: pendingHostSend,
            lastEcho: lastEcho
        )
    }
}
