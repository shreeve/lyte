import Synchronization

/// A tiny synchronized byte accumulator for client equipment whose callbacks
/// cross queues during deterministic tests.
public final class LockedBytePile: Sendable {
    private let stored = Mutex<[[UInt8]]>([])

    public init() {}

    public func append(_ bytes: [UInt8]) {
        stored.withLock { $0.append(bytes) }
    }

    public var all: [[UInt8]] {
        stored.withLock { $0 }
    }

    public var count: Int {
        stored.withLock { $0.count }
    }
}
