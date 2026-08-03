// Renderer handoff policy owns dependency episodes, never media objects.
// Platform shells translate their native samples into this descriptor and
// retain ownership of the payload carried as Element.

public struct RendererFrameDescriptor: Sendable, Equatable {
    public var isRandomAccess: Bool
    public var submittedMicroseconds: UInt64

    public init(isRandomAccess: Bool, submittedMicroseconds: UInt64) {
        self.isRandomAccess = isRandomAccess
        self.submittedMicroseconds = submittedMicroseconds
    }
}

/// Bounded queue policy behind a renderer handoff. Inter frames are never
/// discarded individually: pressure or failure discards the whole dependency
/// episode, enters await-random-access, and asks for one recovery.
public struct BoundedRendererHandoff<Element: Sendable>: Sendable {
    public struct Config: Sendable, Equatable {
        public var capacity: Int
        public var deadlineMicroseconds: UInt64

        public init(capacity: Int = 4, deadlineMicroseconds: UInt64 = 50_000) {
            precondition(capacity > 0)
            self.capacity = capacity
            self.deadlineMicroseconds = deadlineMicroseconds
        }
    }

    public struct Entry: Sendable {
        public var element: Element
        public var frame: RendererFrameDescriptor
    }

    public struct Outcome: Sendable {
        public var accepted: Bool
        public var recoveryRequested: Bool
        public var discarded: [Entry]
    }

    public let config: Config
    public private(set) var awaitingRandomAccess = false
    public private(set) var randomAccessPending = false
    private var entries: [Entry] = []

    public init(config: Config = Config()) {
        self.config = config
        entries.reserveCapacity(config.capacity)
    }

    public var count: Int { entries.count }

    public mutating func offer(
        _ element: Element,
        frame: RendererFrameDescriptor
    ) -> Outcome {
        let incoming = Entry(element: element, frame: frame)
        if awaitingRandomAccess {
            guard !randomAccessPending else {
                return Outcome(
                    accepted: false,
                    recoveryRequested: false,
                    discarded: [incoming])
            }
            guard frame.isRandomAccess else {
                return Outcome(
                    accepted: false,
                    recoveryRequested: false,
                    discarded: [incoming])
            }
            randomAccessPending = true
            entries.append(incoming)
            return Outcome(
                accepted: true, recoveryRequested: false, discarded: [])
        }

        let expired = entries.first.map {
            frame.submittedMicroseconds &- $0.frame.submittedMicroseconds
                >= config.deadlineMicroseconds
        } ?? false
        if entries.count >= config.capacity || expired {
            var discarded = entries
            entries.removeAll(keepingCapacity: true)
            if frame.isRandomAccess {
                entries.append(incoming)
            } else {
                discarded.append(incoming)
                awaitingRandomAccess = true
            }
            return Outcome(
                accepted: frame.isRandomAccess,
                recoveryRequested: true,
                discarded: discarded)
        }

        entries.append(incoming)
        return Outcome(
            accepted: true, recoveryRequested: false, discarded: [])
    }

    public mutating func popReady() -> Entry? {
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst()
    }

    /// Closes recovery only after the accepted random-access sample was
    /// actually handed to the platform renderer. Queueing it is not enough.
    public mutating func noteRandomAccessEnqueued() {
        guard awaitingRandomAccess, randomAccessPending else { return }
        awaitingRandomAccess = false
        randomAccessPending = false
    }

    public mutating func failEpisode() -> Outcome {
        let discarded = entries
        entries.removeAll(keepingCapacity: true)
        let startsRecovery = !awaitingRandomAccess
        awaitingRandomAccess = true
        randomAccessPending = false
        return Outcome(
            accepted: false,
            recoveryRequested: startsRecovery,
            discarded: discarded)
    }

    public mutating func expire(nowMicroseconds: UInt64) -> Outcome {
        guard let first = entries.first,
              nowMicroseconds &- first.frame.submittedMicroseconds
                >= config.deadlineMicroseconds else {
            return Outcome(
                accepted: false,
                recoveryRequested: false,
                discarded: [])
        }
        return failEpisode()
    }

    public mutating func reset() -> [Entry] {
        let discarded = entries
        entries.removeAll(keepingCapacity: true)
        awaitingRandomAccess = false
        randomAccessPending = false
        return discarded
    }
}

/// State seam for a platform renderer's asynchronous recovery flush. No
/// compressed sample may dequeue until the completion callback.
public struct RendererRecoveryFlushBarrier: Sendable, Equatable {
    public private(set) var isFlushInProgress = false

    public init() {}

    @discardableResult
    public mutating func begin() -> Bool {
        guard !isFlushInProgress else { return false }
        isFlushInProgress = true
        return true
    }

    public mutating func complete() {
        isFlushInProgress = false
    }

    public mutating func reset() {
        isFlushInProgress = false
    }

    public var mayEnqueue: Bool { !isFlushInProgress }
}
