import LyteClientSession
import LyteWire
import Synchronization

public typealias NackPolicyConfig = ClientNackPolicy.Config

/// The native shell over the IO-free ClientNackPolicy: one lock, the RTT
/// read before it is taken, and the decision's exits run after it is
/// released — `emit` sends entries down the feedback path promptly (the
/// host's freeze budget is cadence-derived), `escalate` feeds the
/// coalesced IDR recovery.
public final class NackPolicy: Sendable {
    public typealias Stats = ClientNackPolicy.Stats

    public let config: NackPolicyConfig
    private let policy: Mutex<ClientNackPolicy>
    /// Newest min-RTT estimate in µs, nil before the first beacon echo.
    private let rtt: @Sendable () -> Int64?
    private let emit: @Sendable ([FeedbackReport.NackEntry]) -> Void
    private let escalate: @Sendable (FrameNumber, ClientTimestamp) -> Void

    public init(
        config: NackPolicyConfig = NackPolicyConfig(),
        rtt: @escaping @Sendable () -> Int64?,
        emit: @escaping @Sendable ([FeedbackReport.NackEntry]) -> Void,
        escalate: @escaping @Sendable (FrameNumber, ClientTimestamp) -> Void
    ) {
        self.config = config
        self.policy = Mutex(ClientNackPolicy(config: config))
        self.rtt = rtt
        self.emit = emit
        self.escalate = escalate
    }

    public func snapshotStats() -> Stats {
        policy.withLock { $0.stats }
    }

    public func handle(_ signal: VideoRepairSignal, now: ClientTimestamp) {
        let rtt = rtt()
        execute(policy.withLock {
            $0.handle(signal, rttMicroseconds: rtt, now: now)
        }, now: now)
    }

    public func handleRefusal(frame: FrameNumber, now: ClientTimestamp) {
        execute(policy.withLock {
            $0.handleRefusal(frame: frame, now: now)
        }, now: now)
    }

    /// True while a repair is pending within its deadline: hold the IDR.
    public func shouldDeferFecImpossible(
        frame: FrameNumber, now: ClientTimestamp
    ) -> Bool {
        policy.withLock { $0.shouldDeferFecImpossible(frame: frame, now: now) }
    }

    /// The cadence beat: rule-4 deadlines and book hygiene.
    public func tick(now: ClientTimestamp) {
        execute(policy.withLock { $0.tick(now: now) }, now: now)
    }

    private func execute(
        _ decision: ClientNackPolicy.Decision, now: ClientTimestamp
    ) {
        if !decision.nacks.isEmpty { emit(decision.nacks) }
        for frame in decision.escalations { escalate(frame, now) }
    }
}
