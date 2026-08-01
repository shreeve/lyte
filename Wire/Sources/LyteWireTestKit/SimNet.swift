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
    /// Per-direction link capacity. Nil or zero means no serialization
    /// delay, preserving SimNet's original behavior.
    public var bandwidthBitsPerSecond: UInt64?
    /// Bytes admitted to a direction's serializer, including the datagram
    /// currently in service. Nil means unbounded.
    public var maxQueueByteCount: Int?
    /// Optional packet-count burst-loss process, independent per direction.
    public var burstLoss: SimNetBurstLoss?

    public init(
        lossRate: Double = 0,
        duplicateRate: Double = 0,
        baseDelayMicroseconds: Int64 = 0,
        jitterMicroseconds: Int64 = 0,
        bandwidthBitsPerSecond: UInt64? = nil,
        maxQueueByteCount: Int? = nil,
        burstLoss: SimNetBurstLoss? = nil
    ) {
        self.lossRate = lossRate
        self.duplicateRate = duplicateRate
        self.baseDelayMicroseconds = baseDelayMicroseconds
        self.jitterMicroseconds = jitterMicroseconds
        self.bandwidthBitsPerSecond = bandwidthBitsPerSecond
        self.maxQueueByteCount = maxQueueByteCount
        self.burstLoss = burstLoss
    }
}

/// A simple deterministic burst process. When no burst is active, each
/// datagram starts one with `startRate`; that datagram and the chosen number
/// of following datagrams are lost. Ordinary `lossRate` remains active too.
public struct SimNetBurstLoss: Sendable {
    public var startRate: Double
    public var minimumDatagrams: Int
    public var maximumDatagrams: Int

    public init(
        startRate: Double,
        minimumDatagrams: Int,
        maximumDatagrams: Int
    ) {
        self.startRate = startRate
        self.minimumDatagrams = minimumDatagrams
        self.maximumDatagrams = maximumDatagrams
    }
}

/// A netem-style impairment phase beginning at an absolute virtual instant.
/// Phases are replayed in start-time order; equal starts retain input order
/// and the last one wins.
public struct SimNetPhase: Sendable {
    public var startMicroseconds: UInt64
    public var config: SimNetConfig

    public init(startMicroseconds: UInt64, config: SimNetConfig) {
        self.startMicroseconds = startMicroseconds
        self.config = config
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
    private var phases: [SimNetPhase] = []
    private var serializerAvailableAt: [UInt64] = [0, 0]
    private var queued: [[(completion: UInt64, byteCount: Int)]] = [[], []]
    private var burstRemaining: [Int] = [0, 0]

    public private(set) var sentCount = 0
    public private(set) var lostCount = 0
    public private(set) var duplicatedCount = 0
    public private(set) var queueDroppedCount = 0
    public private(set) var peakQueuedByteCount = 0

    public init(
        config: SimNetConfig,
        seed: UInt64,
        schedule: [SimNetPhase] = []
    ) {
        self.config = config
        self.rng = SplitMix64(seed: seed)
        self.phases = Self.sortedPhases(schedule)
    }

    /// Replaces the fault profile mid-run (a netem-style phase change —
    /// e.g. the recovery phase of a scripted scenario going lossless).
    public mutating func setConfig(_ config: SimNetConfig) {
        self.config = config
        phases = []
    }

    /// Installs absolute-time phases. The base `config` applies before the
    /// first phase. Existing in-flight datagrams keep their scheduled times.
    public mutating func setSchedule(_ schedule: [SimNetPhase]) {
        phases = Self.sortedPhases(schedule)
    }

    /// Schedules one datagram from `source` at virtual instant `now`.
    public mutating func send(
        from source: Int, bytes: [UInt8], now: UInt64
    ) {
        sentCount += 1
        let active = effectiveConfig(at: now)
        let direction = max(0, min(source, 1))
        if Double.random(in: 0..<1, using: &rng)
            < max(0, min(active.lossRate, 1))
        {
            lostCount += 1
            return
        }
        if burstDrops(direction: direction, config: active) {
            lostCount += 1
            return
        }
        admit(
            direction: direction,
            destination: 1 - source,
            bytes: bytes,
            now: now,
            config: active
        )
        if Double.random(in: 0..<1, using: &rng)
            < max(0, min(active.duplicateRate, 1))
        {
            duplicatedCount += 1
            admit(
                direction: direction,
                destination: 1 - source,
                bytes: bytes,
                now: now,
                config: active
            )
        }
    }

    private mutating func admit(
        direction: Int,
        destination: Int,
        bytes: [UInt8],
        now: UInt64,
        config: SimNetConfig
    ) {
        reclaimQueue(direction: direction, at: now)
        let queuedBytes = queued[direction].reduce(0) { $0 + $1.byteCount }
        if let bound = config.maxQueueByteCount,
           bytes.count > max(bound, 0) - min(queuedBytes, max(bound, 0)) {
            queueDroppedCount += 1
            return
        }

        let completion: UInt64
        if let bandwidth = config.bandwidthBitsPerSecond, bandwidth > 0 {
            let start = max(now, serializerAvailableAt[direction])
            let duration = serializationMicroseconds(
                byteCount: bytes.count, bitsPerSecond: bandwidth
            )
            completion = start &+ duration
            serializerAvailableAt[direction] = completion
            queued[direction].append((completion, bytes.count))
            peakQueuedByteCount = max(
                peakQueuedByteCount, queuedBytes + bytes.count
            )
        } else {
            completion = now
        }

        var delay = config.baseDelayMicroseconds
        if config.jitterMicroseconds > 0 {
            delay += Int64.random(
                in: 0...config.jitterMicroseconds, using: &rng
            )
        }
        inFlight.append(Delivery(
            destination: destination,
            arrivalMicroseconds: completion &+ UInt64(max(delay, 0)),
            bytes: bytes
        ))
        tieBreakers.append(admitted)
        admitted &+= 1
    }

    /// Bytes waiting for or occupying a direction's serializer at `now`.
    /// Calling this only advances internal queue accounting, never delivery.
    public mutating func queuedByteCount(
        from source: Int, at now: UInt64
    ) -> Int {
        let direction = max(0, min(source, 1))
        reclaimQueue(direction: direction, at: now)
        return queued[direction].reduce(0) { $0 + $1.byteCount }
    }

    private mutating func burstDrops(
        direction: Int, config: SimNetConfig
    ) -> Bool {
        if burstRemaining[direction] > 0 {
            burstRemaining[direction] -= 1
            return true
        }
        guard let burst = config.burstLoss,
              Double.random(in: 0..<1, using: &rng)
                < max(0, min(burst.startRate, 1))
        else {
            return false
        }
        let lower = max(burst.minimumDatagrams, 1)
        let upper = max(burst.maximumDatagrams, lower)
        let length = Int.random(in: lower...upper, using: &rng)
        burstRemaining[direction] = length - 1
        return true
    }

    private mutating func reclaimQueue(direction: Int, at now: UInt64) {
        queued[direction].removeAll { $0.completion <= now }
        if queued[direction].isEmpty {
            serializerAvailableAt[direction] = max(
                serializerAvailableAt[direction], now
            )
        }
    }

    private func effectiveConfig(at now: UInt64) -> SimNetConfig {
        var active = config
        for phase in phases {
            guard phase.startMicroseconds <= now else { break }
            active = phase.config
        }
        return active
    }

    private static func sortedPhases(
        _ phases: [SimNetPhase]
    ) -> [SimNetPhase] {
        phases.enumerated().sorted {
            ($0.element.startMicroseconds, $0.offset)
                < ($1.element.startMicroseconds, $1.offset)
        }.map(\.element)
    }

    private func serializationMicroseconds(
        byteCount: Int, bitsPerSecond: UInt64
    ) -> UInt64 {
        guard byteCount > 0 else { return 0 }
        let bits = UInt64(byteCount) * 8
        let scaled = bits.multipliedFullWidth(by: 1_000_000)
        let quotient = bitsPerSecond.dividingFullWidth(scaled)
        return quotient.remainder == 0
            ? quotient.quotient
            : quotient.quotient &+ 1
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
