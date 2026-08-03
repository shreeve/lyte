import Foundation

/// A tiny synchronized byte accumulator for client equipment whose callbacks
/// cross queues during deterministic tests.
public final class LockedBytePile: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[UInt8]] = []

    public init() {}

    public func append(_ bytes: [UInt8]) {
        lock.lock()
        stored.append(bytes)
        lock.unlock()
    }

    public var all: [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored.count
    }
}
