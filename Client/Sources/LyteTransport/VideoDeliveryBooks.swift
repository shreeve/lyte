import LyteCore
import Synchronization

/// Cross-queue synchronization shell for the sans-IO delivery gauge. The
/// receive/delivery path records hops while the main actor reads the overlay;
/// all arithmetic and retention policy remain single-threaded LyteCore state.
public final class VideoDeliveryBooks: Sendable {
    private let gauge = Mutex(VideoDeliveryGauge())

    public init() {}

    public func record(hopMilliseconds: Double) {
        gauge.withLock { $0.record(hopMilliseconds: hopMilliseconds) }
    }

    public func reset() {
        gauge.withLock { $0.reset() }
    }

    public func snapshot(
        nowMicroseconds: UInt64
    ) -> VideoDeliveryGauge.Snapshot {
        gauge.withLock {
            $0.collectEvidence(nowMicroseconds: nowMicroseconds)
        }.snapshot()
    }
}
