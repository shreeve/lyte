// The chan=3 feedback cadence: every 25–50 ms, snapshot ReceiveDemux's
// per-channel ledgers and arrival samples into a FeedbackReport and send it.
// It feeds the host's estimator and doubles as its fast-liveness signal.
//
// NackPolicy's entries queue via `enqueueNacks` and ride the next report
// (up to FeedbackBounds.maxNackEntries; spill waits a beat). Reports are
// unreliable: a lost report is superseded by the next, a lost NACK is not
// re-queued (the IDR deadline covers it), and failures only count.

import LyteIO
import Dispatch
import Foundation
import LyteCore
import LyteWire

public final class FeedbackSender: @unchecked Sendable {
    public struct Stats: Sendable {
        public var reportsSent: UInt64 = 0
        public var reportsFailed: UInt64 = 0
        public var dispersionSamplesReported: UInt64 = 0
        public var dispersionSamplesDecimated: UInt64 = 0
        /// NACK entries carried on the wire.
        public var nackEntriesSent: UInt64 = 0
    }

    /// The cadence is clamped to 25–50 ms at init.
    public static let cadenceRangeMilliseconds = 25...50

    private let demux: ReceiveDemux
    private let sender: TransportSender
    private let intervalMilliseconds: Int
    private let now: @Sendable () -> ClientTimestamp
    /// Fires after each cadence report (the IdrRequester's flush hook).
    private let onTick: (@Sendable (ClientTimestamp) -> Void)?

    private let lock = NSLock()
    private var stats = Stats()
    private var timer: DispatchSourceTimer?
    /// A private serial queue so `stop()` can drain an in-flight beat.
    private let timerQueue = DispatchQueue(
        label: "lyte.feedback-cadence", qos: .userInitiated)
    /// NACK entries awaiting the next report; past the cap the oldest
    /// drop (closest to stale; the IDR deadline backstops them).
    private var pendingNacks = Deque<FeedbackReport.NackEntry>()
    private static let pendingNackCap = 24

    public init(
        demux: ReceiveDemux,
        sender: TransportSender,
        intervalMilliseconds: Int = 40,
        now: @escaping @Sendable () -> ClientTimestamp = {
            ClientTimestamp(microseconds: SystemMonotonicClock.nowMicroseconds)
        },
        onTick: (@Sendable (ClientTimestamp) -> Void)? = nil
    ) {
        self.demux = demux
        self.sender = sender
        self.intervalMilliseconds = min(
            max(intervalMilliseconds, Self.cadenceRangeMilliseconds.lowerBound),
            Self.cadenceRangeMilliseconds.upperBound)
        self.now = now
        self.onTick = onTick
    }

    /// The clamped cadence actually in force.
    public var cadenceMilliseconds: Int { intervalMilliseconds }

    /// Starts the cadence timer. Idempotent.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: timerQueue)
        source.schedule(
            deadline: .now() + .milliseconds(intervalMilliseconds),
            repeating: .milliseconds(intervalMilliseconds))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.tick(now: self.now())
        }
        source.resume()
        timer = source
    }

    public func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        guard let source else { return }
        source.cancel()
        // Join: an in-flight beat lands its counters before stop() returns.
        // Safe because nothing on the tick path calls stop().
        timerQueue.sync {}
    }

    /// Queues NACK entries for the next report.
    public func enqueueNacks(_ entries: [FeedbackReport.NackEntry]) {
        guard !entries.isEmpty else { return }
        lock.lock()
        pendingNacks.append(contentsOf: entries)
        if pendingNacks.count > Self.pendingNackCap {
            pendingNacks.removeFirst(pendingNacks.count - Self.pendingNackCap)
        }
        lock.unlock()
    }

    /// One cadence beat: build the report and send it.
    public func tick(now: ClientTimestamp) {
        let report = buildReport(now: now)
        do {
            let sent = try sender.send(
                channel: .feedback,
                timestamp: now,
                plaintext: report.encode())
            lock.lock()
            if sent { stats.reportsSent += 1 } else { stats.reportsFailed += 1 }
            lock.unlock()
        } catch {
            // Counted, not fatal: the next beat rebuilds from fresh state.
            lock.lock()
            stats.reportsFailed += 1
            lock.unlock()
        }
        onTick?(now)
    }

    /// Builds one report from the demux's ledgers and drained samples.
    public func buildReport(now: ClientTimestamp) -> FeedbackReport {
        var channels = [FeedbackReport.ChannelStats]()
        for (channel, stats) in demux.snapshotChannels()
            .prefix(FeedbackBounds.maxChannelBlocks) {
            channels.append(FeedbackReport.ChannelStats(
                channel: ChannelId(rawValue: channel),
                highestSeq: ChannelSeq(rawValue: stats.seqHighest ?? 0),
                // Truncation is the wire semantics: the host differences
                // successive reports.
                received: UInt32(truncatingIfNeeded: stats.datagrams - stats.seqDuplicates),
                missing: UInt32(truncatingIfNeeded: stats.seqMissing),
                duplicates: UInt32(truncatingIfNeeded: stats.seqDuplicates)))
        }

        let dispersion = buildDispersion(from: demux.drainArrivalSamples())

        // Drained entries are spent even if the report is lost.
        lock.lock()
        let nacks = Array(
            pendingNacks.prefix(FeedbackBounds.maxNackEntries))
        pendingNacks.removeFirst(nacks.count)
        stats.nackEntriesSent += UInt64(nacks.count)
        lock.unlock()

        return FeedbackReport(
            pathId: 0,   // v1: single path
            clientTimestamp: now,
            channels: channels,
            dispersion: dispersion,
            nacks: nacks,
            extensions: [])
    }

    public func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    // MARK: - Dispersion section

    /// Arrival samples → dispersion section: deltas from the earliest
    /// arrival. Deltas past the u24 field are dropped, not encoded wrong;
    /// overflow is decimated evenly to keep the trains' shape.
    private func buildDispersion(
        from arrivals: [ArrivalSample]
    ) -> FeedbackReport.Dispersion? {
        guard let base = arrivals.map(\.arrivalMicroseconds).min() else { return nil }

        var samples = [FeedbackReport.Dispersion.Sample]()
        samples.reserveCapacity(arrivals.count)
        var dropped: UInt64 = 0
        for arrival in arrivals {
            let delta = arrival.arrivalMicroseconds - base
            guard delta <= UInt64(FeedbackBounds.maxArrivalDeltaMicroseconds) else {
                dropped += 1
                continue
            }
            samples.append(FeedbackReport.Dispersion.Sample(
                channel: ChannelId(rawValue: arrival.channel),
                seq: ChannelSeq(rawValue: arrival.seq),
                arrivalDeltaMicroseconds: UInt32(delta)))
        }

        if samples.count > FeedbackBounds.maxDispersionSamples {
            let total = samples.count
            let keep = FeedbackBounds.maxDispersionSamples
            var decimated = [FeedbackReport.Dispersion.Sample]()
            decimated.reserveCapacity(keep)
            for i in 0..<keep {
                decimated.append(samples[i * total / keep])
            }
            dropped += UInt64(total - keep)
            samples = decimated
        }

        lock.lock()
        stats.dispersionSamplesReported += UInt64(samples.count)
        stats.dispersionSamplesDecimated += dropped
        lock.unlock()

        guard !samples.isEmpty else { return nil }
        return FeedbackReport.Dispersion(
            base: ClientTimestamp(microseconds: base), samples: samples)
    }
}
