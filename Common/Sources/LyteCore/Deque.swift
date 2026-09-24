// Shared FIFO storage for sans-IO policies: `Deque` (unbounded) and
// `BoundedRing` (fixed capacity, overwrites the oldest). Both are value
// types that iterate oldest to newest and never allocate in a steady state;
// members are @inlinable so hot callers in other modules specialize.

/// A FIFO queue over an array with a head index.
///
/// `append` and `removeFirst` are amortized O(1). Consumed slots are
/// reclaimed in bulk once they make up half the array (or immediately when
/// the queue empties), so retained storage stays within about twice the peak
/// live count and a queue that never fully drains cannot keep its history
/// alive. Reclaiming keeps capacity, so a steady state never reallocates.
public struct Deque<Element> {
    @usableFromInline var storage: [Element]
    @usableFromInline var head: Int

    @inlinable
    public init() {
        storage = []
        head = 0
    }

    @inlinable
    public init(minimumCapacity: Int) {
        storage = []
        storage.reserveCapacity(minimumCapacity)
        head = 0
    }

    @inlinable
    public init<S: Sequence>(_ elements: S) where S.Element == Element {
        storage = Array(elements)
        head = 0
    }

    /// Slots the queue currently retains, live or consumed. Bounded by about
    /// twice the peak live count.
    @inlinable
    public var retainedCapacity: Int { storage.capacity }

    @inlinable
    public mutating func append(_ element: Element) {
        storage.append(element)
    }

    @inlinable
    public mutating func append<S: Sequence>(contentsOf elements: S)
    where S.Element == Element {
        storage.append(contentsOf: elements)
    }

    /// Removes and returns the oldest element, or nil when empty.
    @inlinable
    public mutating func popFirst() -> Element? {
        guard head < storage.count else { return nil }
        let element = storage[head]
        head += 1
        reclaim()
        return element
    }

    /// Removes and returns the oldest element. The queue must not be empty.
    @inlinable
    @discardableResult
    public mutating func removeFirst() -> Element {
        guard let element = popFirst() else {
            preconditionFailure("removeFirst on an empty Deque")
        }
        return element
    }

    /// Removes the `k` oldest elements.
    @inlinable
    public mutating func removeFirst(_ k: Int) {
        precondition(k >= 0 && k <= count, "removeFirst count out of range")
        head += k
        reclaim()
    }

    /// Removes every element matching `shouldBeRemoved`, keeping the order
    /// of the rest.
    @inlinable
    public mutating func removeAll(
        where shouldBeRemoved: (Element) throws -> Bool
    ) rethrows {
        compact()
        try storage.removeAll(where: shouldBeRemoved)
    }

    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = true) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        head = 0
    }

    /// Borrows the live elements, oldest first, as one contiguous buffer.
    /// The pointer is valid only for the duration of `body`.
    @inlinable
    public func withUnsafeBufferPointer<R>(
        _ body: (UnsafeBufferPointer<Element>) throws -> R
    ) rethrows -> R {
        try storage.withUnsafeBufferPointer {
            try body(UnsafeBufferPointer(rebasing: $0[head...]))
        }
    }

    @inlinable
    public func withContiguousStorageIfAvailable<R>(
        _ body: (UnsafeBufferPointer<Element>) throws -> R
    ) rethrows -> R? {
        try withUnsafeBufferPointer(body)
    }

    @inlinable
    mutating func reclaim() {
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 32, head &* 2 >= storage.count {
            compact()
        }
    }

    @inlinable
    mutating func compact() {
        guard head > 0 else { return }
        storage.removeSubrange(0..<head)
        head = 0
    }
}

extension Deque: RandomAccessCollection {
    public typealias Index = Int

    @inlinable public var startIndex: Int { 0 }
    @inlinable public var endIndex: Int { storage.count &- head }
    @inlinable public var count: Int { storage.count &- head }
    @inlinable public var isEmpty: Bool { head == storage.count }

    @inlinable
    public subscript(position: Int) -> Element {
        get {
            precondition(position >= 0 && position < count, "index out of range")
            return storage[head &+ position]
        }
        set {
            precondition(position >= 0 && position < count, "index out of range")
            storage[head &+ position] = newValue
        }
    }
}

extension Deque: MutableCollection {}
extension Deque: Sendable where Element: Sendable {}
extension Deque: Equatable where Element: Equatable {
    @inlinable
    public static func == (lhs: Deque, rhs: Deque) -> Bool {
        lhs.elementsEqual(rhs)
    }
}

/// A fixed-capacity window of the most recent elements.
///
/// Appending to a full ring overwrites the oldest element. Iteration runs
/// oldest to newest. Storage grows on demand up to `capacity` and never
/// beyond it.
public struct BoundedRing<Element> {
    public let capacity: Int
    @usableFromInline var storage: [Element]
    /// Index of the oldest element once the ring is full; zero before.
    @usableFromInline var oldest: Int

    @inlinable
    public init(capacity: Int) {
        precondition(capacity > 0, "BoundedRing capacity must be positive")
        self.capacity = capacity
        storage = []
        oldest = 0
    }

    @inlinable
    public var isFull: Bool { storage.count == capacity }

    /// Appends `element`, returning the element it evicted when the ring
    /// was already full.
    @inlinable
    @discardableResult
    public mutating func append(_ element: Element) -> Element? {
        if storage.count < capacity {
            storage.append(element)
            return nil
        }
        let evicted = storage[oldest]
        storage[oldest] = element
        oldest = oldest &+ 1 == capacity ? 0 : oldest &+ 1
        return evicted
    }

    @inlinable
    public mutating func removeAll(keepingCapacity: Bool = true) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        oldest = 0
    }
}

extension BoundedRing: RandomAccessCollection {
    public typealias Index = Int

    @inlinable public var startIndex: Int { 0 }
    @inlinable public var endIndex: Int { storage.count }
    @inlinable public var count: Int { storage.count }
    @inlinable public var isEmpty: Bool { storage.isEmpty }

    @inlinable
    public subscript(position: Int) -> Element {
        precondition(position >= 0 && position < storage.count, "index out of range")
        let physical = oldest &+ position
        return storage[physical >= storage.count ? physical &- storage.count : physical]
    }
}

extension BoundedRing: Sendable where Element: Sendable {}
