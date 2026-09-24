import LyteClientSession
import LyteWire
import Synchronization

/// The session's one host-clock model, shared by every consumer that maps
/// host time — video delivery, input echoes, the stats rows: the IO-free
/// ClientHostClock fit behind a lock. All consumers read the same
/// instance; divergent estimates are an A/V sync error.
public final class HostClockModel: Sendable {
    public typealias Config = ClientHostClock.Config
    public typealias Estimate = ClientHostClock.Estimate

    private let clock: Mutex<ClientHostClock>

    public init(config: Config = Config()) {
        clock = Mutex(ClientHostClock(config: config))
    }

    /// Feeds one raw sample; an implausible one is dropped.
    public func ingest(_ sample: ClockSample) {
        clock.withLock { $0.ingest(sample) }
    }

    /// The newest `limit` samples still in the window, in arrival order.
    /// Every RTT among them lies in [0, ClockSample.maxPlausibleRtt].
    public func recentSamples(_ limit: Int) -> [ClockSample] {
        clock.withLock { $0.recentSamples(limit) }
    }

    /// The current fit, or nil before the first sample.
    public func estimate() -> Estimate? {
        clock.withLock { $0.estimate() }
    }

    /// One-shot mapping against the current fit; nil before the first
    /// sample. Consumers mapping in a loop should snapshot `estimate()`.
    public func map(_ host: HostTimestamp) -> ClientTimestamp? {
        estimate()?.map(host)
    }
}
