import Foundation
import LyteCore

/// Cross-queue synchronization shell for the sans-IO delivery gauge. The
/// receive/delivery path records hops while the main actor reads the overlay;
/// all arithmetic and retention policy remain single-threaded LyteCore state.
public final class VideoDeliveryBooks: @unchecked Sendable {
    private let lock = NSLock()
    private var gauge = VideoDeliveryGauge()

    public init() {}

    public func record(hopMilliseconds: Double) {
        lock.lock()
        gauge.record(hopMilliseconds: hopMilliseconds)
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        gauge.reset()
        lock.unlock()
    }

    public func snapshot(
        nowMicroseconds: UInt64
    ) -> VideoDeliveryGauge.Snapshot {
        lock.lock()
        let evidence = gauge.collectEvidence(
            nowMicroseconds: nowMicroseconds)
        lock.unlock()
        return evidence.snapshot()
    }
}
