// The coalescing IDR requester: the thread-safe shell over
// LyteClientSession's ClientIdrRecovery (the episode policy the browser
// shares). It emits each due 0x10 request through the injected sender;
// the feedback cadence's timer drives the retries.

import Foundation
import LyteClientSession
import LyteWire

public final class IdrRequester: @unchecked Sendable {
    public typealias Stats = ClientIdrRecovery.Stats

    private let emit: @Sendable (IdrRequest) -> Void
    private let lock = NSLock()
    private var recovery: ClientIdrRecovery

    /// - Parameter emit: sends one encoded request (TransportSender via
    ///   CTRL in production, a capture closure in tests).
    public init(
        retryIntervalMilliseconds: Int = 500,
        emit: @escaping @Sendable (IdrRequest) -> Void
    ) {
        self.recovery = ClientIdrRecovery(
            retryIntervalMicroseconds:
                UInt64(max(1, retryIntervalMilliseconds)) * 1_000)
        self.emit = emit
    }

    /// One broken-reference verdict from any recovery pathway. The first
    /// starts an episode and emits immediately; later verdicts join it and
    /// emit only when its retry is due.
    public func recordRecoveryDemand(
        frame: FrameNumber, now: ClientTimestamp
    ) {
        lock.lock()
        recovery.recordDemand(frame: frame)
        let request = recovery.requestDue(now: now)
        lock.unlock()
        if let request { emit(request) }
    }

    /// The feedback-cadence timer's retry wake. Quiet when no episode is
    /// outstanding or before its retry boundary.
    public func flushIfDue(now: ClientTimestamp) {
        lock.lock()
        let request = recovery.requestDue(now: now)
        lock.unlock()
        if let request { emit(request) }
    }

    /// Closes the outstanding episode only after the render path accepted
    /// an IRAP sample.
    public func noteUsableIrapAccepted() {
        lock.lock()
        recovery.noteUsableIrapAccepted()
        lock.unlock()
    }

    public func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return recovery.stats
    }
}
