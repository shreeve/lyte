import Foundation

/// A value behind a lock, for test callbacks that cross queues.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    public init(_ value: Value) {
        stored = value
    }

    public var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    @discardableResult
    public func mutate<Result>(
        _ body: (inout Value) throws -> Result
    ) rethrows -> Result {
        try lock.withLock { try body(&stored) }
    }
}

extension Locked where Value: RangeReplaceableCollection {
    public convenience init() {
        self.init(Value())
    }

    public func append(_ element: Value.Element) {
        mutate { $0.append(element) }
    }

    public var all: Value { value }

    public var count: Int { value.count }
}

/// Datagrams collected from a transmit closure.
public typealias LockedBytePile = Locked<[[UInt8]]>
