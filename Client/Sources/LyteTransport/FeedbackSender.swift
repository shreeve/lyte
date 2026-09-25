// The chan=3 feedback cadence: every 25–50 ms, LyteClientSession's
// ClientFeedbackReporter turns ReceiveDemux's per-channel ledgers, its
// drained arrival samples and any queued NACK entries into one report, and
// this shell seals and sends it. Failures only count.

import LyteIO
import Dispatch
import LyteClientSession
import LyteWire
import Synchronization

public final class FeedbackSender: Sendable {
    public struct Stats: Sendable {
        public var reportsSent: UInt64 = 0
        public var reportsFailed: UInt64 = 0
        public var dispersionSamplesReported: UInt64 = 0
        public var dispersionSamplesDecimated: UInt64 = 0
        /// NACK entries carried on the wire.
        public var nackEntriesSent: UInt64 = 0
    }

    private struct Books {
        var reporter = ClientFeedbackReporter()
        var reportsSent: UInt64 = 0
        var reportsFailed: UInt64 = 0
    }

    private let demux: ReceiveDemux
    private let sender: TransportSender
    private let intervalMilliseconds: Int
    private let now: @Sendable () -> ClientTimestamp
    /// Fires after each cadence report (the IdrRequester's flush hook).
    private let onTick: (@Sendable (ClientTimestamp) -> Void)?

    private let books = Mutex(Books())
    private let timer = Mutex<(any DispatchSourceTimer)?>(nil)
    /// A private serial queue so `stop()` can drain an in-flight beat.
    private let timerQueue = DispatchQueue(
        label: "lyte.feedback-cadence", qos: .userInitiated)

    public init(
        demux: ReceiveDemux,
        sender: TransportSender,
        intervalMilliseconds: Int = ClientFeedbackReporter.cadenceMilliseconds,
        now: @escaping @Sendable () -> ClientTimestamp = {
            ClientTimestamp(microseconds: SystemMonotonicClock.nowMicroseconds)
        },
        onTick: (@Sendable (ClientTimestamp) -> Void)? = nil
    ) {
        self.demux = demux
        self.sender = sender
        let band = ClientFeedbackReporter.cadenceRangeMilliseconds
        self.intervalMilliseconds = min(
            max(intervalMilliseconds, band.lowerBound), band.upperBound)
        self.now = now
        self.onTick = onTick
    }

    /// The clamped cadence actually in force.
    public var cadenceMilliseconds: Int { intervalMilliseconds }

    /// Starts the cadence timer. Idempotent.
    public func start() {
        timer.withLock { timer in
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
    }

    public func stop() {
        guard let source = timer.withLock({ timer in
            defer { timer = nil }
            return timer
        }) else { return }
        source.cancel()
        // Join: an in-flight beat lands its counters before stop() returns.
        // Safe because nothing on the tick path calls stop().
        timerQueue.sync {}
    }

    /// Queues NACK entries for the next report.
    public func enqueueNacks(_ entries: [FeedbackReport.NackEntry]) {
        guard !entries.isEmpty else { return }
        books.withLock { $0.reporter.enqueueNacks(entries) }
    }

    /// One cadence beat: build the report and send it.
    public func tick(now: ClientTimestamp) {
        let report = buildReport(now: now)
        // Counted, not fatal: the next beat rebuilds from fresh state.
        let sent = (try? sender.send(
            channel: .feedback,
            timestamp: now,
            plaintext: report.encode())) ?? false
        books.withLock {
            if sent { $0.reportsSent += 1 } else { $0.reportsFailed += 1 }
        }
        onTick?(now)
    }

    /// Builds one report from the demux's ledgers and drained samples.
    public func buildReport(now: ClientTimestamp) -> FeedbackReport {
        let ledgers = demux.snapshotChannels().map {
            ClientFeedbackReporter.Ledger(
                channel: ChannelId(rawValue: $0.channel),
                highestSeq: $0.stats.seqHighest.map { ChannelSeq(rawValue: $0) },
                datagrams: $0.stats.datagrams,
                duplicates: $0.stats.seqDuplicates,
                missing: $0.stats.seqMissing)
        }
        let arrivals = demux.drainArrivalSamples()
        return books.withLock {
            $0.reporter.report(ledgers: ledgers, arrivals: arrivals, now: now)
        }
    }

    public func snapshotStats() -> Stats {
        books.withLock {
            Stats(
                reportsSent: $0.reportsSent,
                reportsFailed: $0.reportsFailed,
                dispersionSamplesReported:
                    $0.reporter.stats.dispersionSamplesReported,
                dispersionSamplesDecimated:
                    $0.reporter.stats.dispersionSamplesDecimated,
                nackEntriesSent: $0.reporter.stats.nackEntriesSent)
        }
    }
}
