// The coalescing IDR requester: the thread-safe shell over
// LyteClientSession's ClientIdrRecovery (the episode policy the browser
// shares). It emits each due 0x10 request through the injected sender;
// the feedback cadence's timer drives the retries. The open episode is
// also the render gate: until an IRAP is accepted, only random-access
// frames may reach the renderer.

import LyteClientSession
import LyteWire
import Synchronization

public final class IdrRequester: Sendable {
    public typealias Stats = ClientIdrRecovery.Stats

    private let emit: @Sendable (IdrRequest) -> Void
    private let recovery: Mutex<ClientIdrRecovery>

    /// - Parameter emit: sends one encoded request.
    public init(
        retryIntervalMilliseconds: Int = 500,
        emit: @escaping @Sendable (IdrRequest) -> Void
    ) {
        self.recovery = Mutex(ClientIdrRecovery(
            retryIntervalMicroseconds:
                UInt64(max(1, retryIntervalMilliseconds)) * 1_000))
        self.emit = emit
    }

    /// One broken-reference verdict from any recovery pathway. The first
    /// starts an episode and emits immediately; later verdicts join it and
    /// emit only when its retry is due. True when an episode was already
    /// open.
    @discardableResult
    public func recordRecoveryDemand(
        frame: FrameNumber, now: ClientTimestamp
    ) -> Bool {
        let (joined, request) = recovery.withLock {
            let joined = $0.recordDemand(frame: frame)
            return (joined, $0.requestDue(now: now))
        }
        if let request { emit(request) }
        return joined
    }

    /// The feedback-cadence timer's retry wake. Quiet when no episode is
    /// outstanding or before its retry boundary.
    public func flushIfDue(now: ClientTimestamp) {
        if let request = recovery.withLock({ $0.requestDue(now: now) }) {
            emit(request)
        }
    }

    /// Whether a frame may reach the renderer now.
    public func admits(isRandomAccess: Bool) -> Bool {
        recovery.withLock { $0.admits(isRandomAccess: isRandomAccess) }
    }

    /// Closes the outstanding episode only after the render path accepted
    /// an IRAP sample.
    public func noteUsableIrapAccepted() {
        recovery.withLock { $0.noteUsableIrapAccepted() }
    }

    public func snapshotStats() -> Stats {
        recovery.withLock { $0.stats }
    }
}
