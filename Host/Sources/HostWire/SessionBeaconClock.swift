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

/// The sans-IO owner of the Host session's W4a beacon clock.
///
/// `Session` adapts these values to sealed CTRL sends and estimator events;
/// this value owns cadence, successful-send sequence advancement, echo
/// mirroring, and raw offset/RTT books. A late timer wake emits at most one
/// catch-up beacon, preserves the existing beat when it is still ahead, and
/// otherwise starts one fresh interval from the late wake.
public struct SessionBeaconClock: Equatable, Sendable {
    public let intervalNanoseconds: UInt64
    public private(set) var nextDeadlineNanoseconds: UInt64?
    public private(set) var stats = SessionClockStats()

    private var nextSequence: UInt32 = 0
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

    /// Commits exactly one successfully emitted beacon sequence.
    @discardableResult
    public mutating func noteBeaconSent() -> UInt32 {
        defer { nextSequence &+= 1 }
        return nextSequence
    }

    /// Records one echo, updates the minimum-RTT books, and retains the W4a
    /// mirror fields for the next beacon.
    public mutating func accept(
        echo: BeaconEcho,
        hostMicroseconds: UInt64
    ) -> (offsetMicroseconds: Int64, rttMicroseconds: Int64) {
        let hostReceive = HostTimestamp(microseconds: hostMicroseconds)
        let sample = echo.clockSample(hostReceive: hostReceive)
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

    private func pendingBeacon(hostMicroseconds: UInt64) -> ClockBeacon {
        ClockBeacon(
            beaconSeq: nextSequence,
            hostSend: HostTimestamp(microseconds: hostMicroseconds),
            lastEcho: lastEcho
        )
    }
}
