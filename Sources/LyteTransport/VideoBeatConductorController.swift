import Foundation
import LyteCore

/// Synchronization shell for the sans-IO conductor policy. The renderer and
/// session may update the instrument from different queues; the policy itself
/// remains a single-threaded value in LyteCore.
public final class VideoBeatConductorController: @unchecked Sendable {
    private let lock = NSLock()
    private var policy: VideoBeatConductor

    public init(config: VideoBeatConductor.Config = .init()) {
        policy = VideoBeatConductor(config: config)
    }

    public func schedule(
        mappedCaptureMicroseconds: UInt64,
        arrivalMicroseconds: UInt64,
        sourceCaptureMicroseconds: UInt64? = nil,
        isRandomAccess: Bool = false
    ) -> VideoBeatConductor.Decision {
        lock.lock()
        defer { lock.unlock() }
        return policy.schedule(
            mappedCaptureMicroseconds: mappedCaptureMicroseconds,
            arrivalMicroseconds: arrivalMicroseconds,
            sourceCaptureMicroseconds: sourceCaptureMicroseconds,
            isRandomAccess: isRandomAccess)
    }

    public func reset() {
        lock.lock(); policy.reset(); lock.unlock()
    }

    public func updateCueCeiling(maximumCueMicroseconds: UInt64) {
        lock.lock()
        policy.updateCueCeiling(
            maximumCueMicroseconds: maximumCueMicroseconds)
        lock.unlock()
    }

    public func noteRandomAccessEnqueued() {
        lock.lock(); policy.noteRandomAccessEnqueued(); lock.unlock()
    }
}
