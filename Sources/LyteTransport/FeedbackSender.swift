// The chan=3 feedback cadence (CL-3): every 25–50 ms, snapshot
// ReceiveDemux's per-channel ledgers, drain its arrival samples into the
// report's dispersion section, and send the FeedbackReport through the
// TransportSender. This is the host estimator's (HS-16) whole diet —
// cumulative loss/duplicate ledgers plus per-packet arrival spacing for
// the paced trains (resiliency §2.2, RFC 8888 semantics) — and doubles as
// the fast-liveness signal (350 ms of feedback silence is the host's
// blackout detector, resiliency §3).
//
// The NACK section is EMPTY in v1: ruling §4.7 — the host ignores NACKs
// until HS-17's responder exists, and the heal path for FEC-impossible
// frames is the IdrRequester's CTRL message. When HS-17 lands, the
// assembler's nackCandidates events route here and fill the section; the
// codec and wire shape are ready (W4a), only this sender abstains.
//
// Reports are unreliable by design (build plan §4.11): a lost report is
// superseded 25–50 ms later, so sends never retry and failures only count.
// The timer is a DispatchSourceTimer for production; tests drive
// `tick(now:)` with an injected clock and never start the timer.

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

    public init(
        demux: ReceiveDemux,
        sender: TransportSender,
        intervalMilliseconds: Int = 40,
        now: @escaping @Sendable () -> ClientTimestamp = {
            ClientTimestamp(microseconds: DispatchTime.now().uptimeNanoseconds / 1000)
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
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
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
        source?.cancel()
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

        return FeedbackReport(
            pathId: 0,   // v1: single path (resiliency §6)
            clientTimestamp: now,
            channels: channels,
            dispersion: dispersion,
            nacks: [],   // empty until HS-17 (ruling §4.7, header comment)
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
