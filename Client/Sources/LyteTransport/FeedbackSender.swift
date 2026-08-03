// The chan=3 feedback cadence (CL-3): every 25–50 ms, snapshot
// ReceiveDemux's per-channel ledgers, drain its arrival samples into the
// report's dispersion section, and send the FeedbackReport through the
// TransportSender. This is the host estimator's (HS-16) whole diet —
// cumulative loss/duplicate ledgers plus per-packet arrival spacing for
// the paced trains (resiliency §2.2, RFC 8888 semantics) — and doubles as
// the fast-liveness signal (350 ms of feedback silence is the host's
// blackout detector, resiliency §3).
//
// The NACK section (CL-12, closing §4.7's ruling): NackPolicy's entries
// queue here via `enqueueNacks` and ride the NEXT report — the policy's
// emit closure follows the enqueue with an immediate out-of-cadence
// `tick`, because the host's rule-3 freeze budget (2 frame intervals,
// ~33 ms) is tighter than the 25–50 ms cadence. Reports stay unreliable:
// a lost NACK is NOT re-queued (dedupe discipline — the host one-attempts
// per shard); rule 4's deadline escalation to IDR covers the loss.
// FeedbackBounds.maxNackEntries (6) caps a report's section; spill waits
// for the next beat.
//
// Reports are unreliable by design (build plan §4.11): a lost report is
// superseded 25–50 ms later, so sends never retry and failures only count.
// The timer is a DispatchSourceTimer for production; tests drive
// `tick(now:)` with an injected clock and never start the timer.

import LyteIO
import Dispatch
import Foundation
import LyteWire

public final class FeedbackSender: @unchecked Sendable {
    /// Cadence counters, snapshotted for the CLI.
    public struct Stats: Sendable {
        public var reportsSent: UInt64 = 0
        public var reportsFailed: UInt64 = 0
        public var dispersionSamplesReported: UInt64 = 0
        public var dispersionSamplesDecimated: UInt64 = 0
        /// NACK entries carried on the wire (CL-12).
        public var nackEntriesSent: UInt64 = 0
    }

    /// The build plan pins the cadence to 25–50 ms; anything outside is a
    /// caller bug, clamped loudly at init rather than silently obeyed.
    public static let cadenceRangeMilliseconds = 25...50

    private let demux: ReceiveDemux
    private let sender: TransportSender
    private let intervalMilliseconds: Int
    private let now: @Sendable () -> ClientTimestamp
    /// Fires after each cadence report — the IdrRequester's flushIfDue
    /// hook (the cadence is always shorter than the IDR rate window, so
    /// coalesced requests wait at most one tick).
    private let onTick: (@Sendable (ClientTimestamp) -> Void)?

    private let lock = NSLock()
    private var stats = Stats()
    private var timer: DispatchSourceTimer?
    /// The cadence beats on a private serial queue so `stop()` can drain
    /// an in-flight beat with a sync barrier — cancel alone returns while
    /// a tick may still be between its transmit and its counter update.
    private let timerQueue = DispatchQueue(
        label: "lyte.feedback-cadence", qos: .userInitiated)
    /// NACK entries awaiting the next report (CL-12). Bounded: the
    /// policy's dedupe keeps volume low; past the cap the OLDEST drop —
    /// their frames are closest to stale and rule 4 backstops them.
    private var pendingNacks: [FeedbackReport.NackEntry] = []
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
        // Teardown is a join: drain the serial queue so a beat that has
        // already transmitted also lands its counters before stop()
        // returns — callers may reconcile stats against sent datagrams.
        // Safe: nothing on the tick path (onTick → IdrRequester flush,
        // NackPolicy tick) ever calls stop().
        timerQueue.sync {}
    }

    /// Queues NACK entries for the next report. The caller (NackPolicy's
    /// emit closure) follows with `tick(now:)` when the freeze budget
    /// demands an out-of-cadence report.
    public func enqueueNacks(_ entries: [FeedbackReport.NackEntry]) {
        guard !entries.isEmpty else { return }
        lock.lock()
        pendingNacks.append(contentsOf: entries)
        if pendingNacks.count > Self.pendingNackCap {
            pendingNacks.removeFirst(pendingNacks.count - Self.pendingNackCap)
        }
        lock.unlock()
    }

    /// One cadence beat: build the report from live demux state and send
    /// it. The timer calls this; tests call it directly with their clock.
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
            // Encode rejects and seal failures are counted, not fatal:
            // the next beat rebuilds from fresh state.
            lock.lock()
            stats.reportsFailed += 1
            lock.unlock()
        }
        onTick?(now)
    }

    /// Builds one report from the demux's current ledgers and drained
    /// arrival samples. Public so tests can pin the mapping without a
    /// socket anywhere.
    public func buildReport(now: ClientTimestamp) -> FeedbackReport {
        var channels = [FeedbackReport.ChannelStats]()
        for (channel, stats) in demux.snapshotChannels()
            .prefix(FeedbackBounds.maxChannelBlocks) {
            channels.append(FeedbackReport.ChannelStats(
                channel: ChannelId(rawValue: channel),
                highestSeq: ChannelSeq(rawValue: stats.seqHighest ?? 0),
                // u32 wraps in days at peak rate and the host differences
                // successive reports (codec comment) — truncation is the
                // documented wire semantics, not data loss.
                received: UInt32(truncatingIfNeeded: stats.datagrams - stats.seqDuplicates),
                missing: UInt32(truncatingIfNeeded: stats.seqMissing),
                duplicates: UInt32(truncatingIfNeeded: stats.seqDuplicates)))
        }

        let dispersion = buildDispersion(from: demux.drainArrivalSamples())

        // Drain queued NACK entries up to the section bound; spill rides
        // the next beat. Drained entries are spent either way (header
        // comment: a lost report is NOT re-asked; rule 4 backstops).
        lock.lock()
        let nacks = Array(
            pendingNacks.prefix(FeedbackBounds.maxNackEntries))
        pendingNacks.removeFirst(nacks.count)
        stats.nackEntriesSent += UInt64(nacks.count)
        lock.unlock()

        return FeedbackReport(
            pathId: 0,   // v1: single path (resiliency §6)
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

    /// Arrival samples → the report's dispersion section: base = earliest
    /// arrival, deltas from it. Samples whose delta exceeds the u24 field
    /// (clock-domain mixups, multi-second stalls) are dropped rather than
    /// encoded wrong; when more samples than the section can carry
    /// survive, evenly-spaced decimation keeps the trains' shape (the
    /// estimator weights trains, it does not need every packet).
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
