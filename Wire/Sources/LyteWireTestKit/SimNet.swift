// SimNet (W3): the seeded loss/reorder/duplication/delay injector the
// core plan promised as a TestKit product, so the host and client test
// suites can run the same network fault model as W-G4. Deterministic by
// construction: one SplitMix64 drives every fault decision, time is the
// caller's virtual clock, and delivery order falls out of the computed
// arrival instants (reorder is what jitter DOES to a packet stream —
// bounded displacement, exactly the G4 gate's model — rather than a
// separate shuffling pass).
//
// The pipe is direction-symmetric and datagram-oriented. The caller
// owns the event loop: `send` schedules arrivals, `nextArrivalTime`
// tells the loop how far to advance the clock, `deliveries(upTo:)`
// hands back everything due. Nothing here knows about envelopes or
// ARQ — bytes in, bytes out.

public struct SimNetConfig: Sendable {
    /// Probability a datagram never arrives (0…1).
    public var lossRate: Double
    /// Probability a delivered datagram arrives twice, the copy taking
    /// its own independently-jittered path (0…1).
    public var duplicateRate: Double
    /// One-way base delay.
    public var baseDelayMicroseconds: Int64
    /// Uniform extra delay in 0…jitter; displacement reordering emerges
    /// from it.
    public var jitterMicroseconds: Int64

    public init(
        lossRate: Double = 0,
        duplicateRate: Double = 0,
        baseDelayMicroseconds: Int64 = 0,
        jitterMicroseconds: Int64 = 0
    ) {
        self.lossRate = lossRate
        self.duplicateRate = duplicateRate
        self.baseDelayMicroseconds = baseDelayMicroseconds
        self.jitterMicroseconds = jitterMicroseconds
    }
}

/// A two-endpoint duplex datagram pipe with seeded faults. Endpoints
/// are 0 and 1; virtual time is a plain µs counter the caller advances.
public struct SimNet: Sendable {
    public struct Delivery: Sendable {
        public var destination: Int
        public var arrivalMicroseconds: UInt64
        public var bytes: [UInt8]
    }

    public private(set) var config: SimNetConfig
    private var rng: SplitMix64
    private var inFlight: [Delivery] = []
    /// Tie-breaker so equal-arrival datagrams deliver in send order.
    private var admitted: UInt64 = 0
    private var tieBreakers: [UInt64] = []

    public private(set) var sentCount = 0
    public private(set) var lostCount = 0
    public private(set) var duplicatedCount = 0

    public init(config: SimNetConfig, seed: UInt64) {
        self.config = config
        self.rng = SplitMix64(seed: seed)
    }

    /// Replaces the fault profile mid-run (a netem-style phase change —
    /// e.g. the recovery phase of a scripted scenario going lossless).
    public mutating func setConfig(_ config: SimNetConfig) {
        self.config = config
    }

    /// Schedules one datagram from `source` at virtual instant `now`.
    public mutating func send(
        from source: Int, bytes: [UInt8], now: UInt64
    ) {
        sentCount += 1
        if Double.random(in: 0..<1, using: &rng) < config.lossRate {
            lostCount += 1
            return
        }
        admit(destination: 1 - source, bytes: bytes, now: now)
        if Double.random(in: 0..<1, using: &rng) < config.duplicateRate {
            duplicatedCount += 1
            admit(destination: 1 - source, bytes: bytes, now: now)
        }
    }

    private mutating func admit(
        destination: Int, bytes: [UInt8], now: UInt64
    ) {
        var delay = config.baseDelayMicroseconds
        if config.jitterMicroseconds > 0 {
            delay += Int64.random(
                in: 0...config.jitterMicroseconds, using: &rng
            )
        }
        inFlight.append(Delivery(
            destination: destination,
            arrivalMicroseconds: now &+ UInt64(max(delay, 0)),
            bytes: bytes
        ))
        tieBreakers.append(admitted)
        admitted &+= 1
    }

    /// The earliest scheduled arrival, nil when the pipe is empty.
    public var nextArrivalTime: UInt64? {
        inFlight.map(\.arrivalMicroseconds).min()
    }

    /// Removes and returns every delivery due at or before `now`, in
    /// arrival order (send order breaking ties).
    public mutating func deliveries(upTo now: UInt64) -> [Delivery] {
        var due: [(Delivery, UInt64)] = []
        var keepFlight: [Delivery] = []
        var keepTies: [UInt64] = []
        for (delivery, tie) in zip(inFlight, tieBreakers) {
            if delivery.arrivalMicroseconds <= now {
                due.append((delivery, tie))
            } else {
                keepFlight.append(delivery)
                keepTies.append(tie)
            }
        }
        inFlight = keepFlight
        tieBreakers = keepTies
        return due
            .sorted { ($0.0.arrivalMicroseconds, $0.1)
                < ($1.0.arrivalMicroseconds, $1.1) }
            .map(\.0)
    }
}
