import LyteWire

/// The chan-3 feedback report's content, IO-free: per-channel receive
/// ledgers, the arrival dispersion section and the queued NACK entries.
/// The report feeds the host's estimator and doubles as its fast-liveness
/// signal. The shell owns the 25–50 ms cadence, the ledgers and the send.
///
/// Reports are unreliable: a lost report is superseded by the next, and
/// entries drained into a report are spent even if it is lost (the repair
/// deadline covers a lost NACK).
public struct ClientFeedbackReporter: Sendable {
    public struct Stats: Sendable, Equatable {
        public var dispersionSamplesReported: UInt64 = 0
        public var dispersionSamplesDecimated: UInt64 = 0
        /// NACK entries carried in a report.
        public var nackEntriesSent: UInt64 = 0

        public init() {}
    }

    /// One channel's receive ledger, cumulative since the session began.
    public struct Ledger: Hashable, Sendable {
        public var channel: ChannelId
        public var highestSeq: ChannelSeq?
        public var datagrams: UInt64
        public var duplicates: UInt64
        /// Gaps not (yet) filled by late arrivals.
        public var missing: UInt64

        public init(
            channel: ChannelId, highestSeq: ChannelSeq?,
            datagrams: UInt64, duplicates: UInt64, missing: UInt64
        ) {
            self.channel = channel
            self.highestSeq = highestSeq
            self.datagrams = datagrams
            self.duplicates = duplicates
            self.missing = missing
        }
    }

    /// One accepted datagram's arrival; only the spacing is meaningful.
    public struct Arrival: Hashable, Sendable {
        public var channel: ChannelId
        public var seq: ChannelSeq
        public var arrivalMicroseconds: UInt64

        public init(channel: ChannelId, seq: ChannelSeq,
                    arrivalMicroseconds: UInt64) {
            self.channel = channel
            self.seq = seq
            self.arrivalMicroseconds = arrivalMicroseconds
        }
    }

    /// NACK entries awaiting a report; past the cap the oldest drop
    /// (closest to stale; the repair deadline backstops them).
    public static let pendingNackCap = 24

    public private(set) var stats = Stats()
    private var pendingNacks: [FeedbackReport.NackEntry] = []

    public init() {}

    /// Queues entries for the next report; one report carries at most
    /// FeedbackBounds.maxNackEntries and the rest wait a beat.
    public mutating func enqueueNacks(_ entries: [FeedbackReport.NackEntry]) {
        pendingNacks.append(contentsOf: entries)
        if pendingNacks.count > Self.pendingNackCap {
            pendingNacks.removeFirst(pendingNacks.count - Self.pendingNackCap)
        }
    }

    /// The report for this beat. The ledger counters truncate to the
    /// wire's u32 fields: the host differences successive reports.
    public mutating func report(
        ledgers: [Ledger], arrivals: [Arrival], now: ClientTimestamp
    ) -> FeedbackReport {
        let channels = ledgers.prefix(FeedbackBounds.maxChannelBlocks).map {
            FeedbackReport.ChannelStats(
                channel: $0.channel,
                highestSeq: $0.highestSeq ?? ChannelSeq(rawValue: 0),
                received: UInt32(truncatingIfNeeded:
                    $0.datagrams &- $0.duplicates),
                missing: UInt32(truncatingIfNeeded: $0.missing),
                duplicates: UInt32(truncatingIfNeeded: $0.duplicates))
        }
        let nacks = Array(pendingNacks.prefix(FeedbackBounds.maxNackEntries))
        pendingNacks.removeFirst(nacks.count)
        stats.nackEntriesSent += UInt64(nacks.count)
        return FeedbackReport(
            pathId: 0,   // v1: single path
            clientTimestamp: now,
            channels: Array(channels),
            dispersion: dispersion(from: arrivals),
            nacks: nacks,
            extensions: [])
    }

    /// Arrivals → deltas from the earliest. Deltas past the u24 field are
    /// dropped, not encoded wrong; overflow is decimated evenly so the
    /// trains keep their shape.
    private mutating func dispersion(
        from arrivals: [Arrival]
    ) -> FeedbackReport.Dispersion? {
        guard let base = arrivals.map(\.arrivalMicroseconds).min() else {
            return nil
        }
        var samples: [FeedbackReport.Dispersion.Sample] = []
        samples.reserveCapacity(arrivals.count)
        var dropped: UInt64 = 0
        for arrival in arrivals {
            let delta = arrival.arrivalMicroseconds - base
            guard delta <= UInt64(FeedbackBounds.maxArrivalDeltaMicroseconds)
            else {
                dropped += 1
                continue
            }
            samples.append(FeedbackReport.Dispersion.Sample(
                channel: arrival.channel,
                seq: arrival.seq,
                arrivalDeltaMicroseconds: UInt32(delta)))
        }
        if samples.count > FeedbackBounds.maxDispersionSamples {
            let total = samples.count
            let keep = FeedbackBounds.maxDispersionSamples
            samples = (0..<keep).map { samples[$0 * total / keep] }
            dropped += UInt64(total - keep)
        }
        stats.dispersionSamplesReported += UInt64(samples.count)
        stats.dispersionSamplesDecimated += dropped
        guard !samples.isEmpty else { return nil }
        return FeedbackReport.Dispersion(
            base: ClientTimestamp(microseconds: base), samples: samples)
    }
}
