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

/// Bounded queue policy behind a renderer handoff. Pressure or failure
/// discards the whole dependency episode (never a lone inter frame), enters
/// await-random-access, and asks for one recovery; the IRAP that ends the
/// wait heads a new episode. Invariant: while awaiting with no IRAP
/// pending, a recovery request is outstanding.
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
        if awaitingRandomAccess, !randomAccessPending {
            // Nothing decodable until an IRAP opens the next episode.
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

        // An accepted IRAP awaiting enqueue heads the queue; its inter
        // frames queue behind it under the same capacity and deadline.
        let expired = entries.first.map {
            Self.age(of: $0, at: frame.submittedMicroseconds)
                >= config.deadlineMicroseconds
        } ?? false
        if entries.count >= config.capacity || expired {
            var discarded = entries
            entries.removeAll(keepingCapacity: true)
            if frame.isRandomAccess {
                // The incoming IRAP restarts the chain itself: no recovery
                // is needed and nothing discarded reached the renderer.
                entries.append(incoming)
                return Outcome(
                    accepted: true,
                    recoveryRequested: false,
                    discarded: discarded)
            }
            discarded.append(incoming)
            return Outcome(
                accepted: false,
                recoveryRequested: awaitRandomAccess(),
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
        return Outcome(
            accepted: false,
            recoveryRequested: awaitRandomAccess(),
            discarded: discarded)
    }

    public mutating func expire(nowMicroseconds: UInt64) -> Outcome {
        guard let first = entries.first,
              Self.age(of: first, at: nowMicroseconds)
                >= config.deadlineMicroseconds else {
            return Outcome(
                accepted: false,
                recoveryRequested: false,
                discarded: [])
        }
        return failEpisode()
    }

    /// How long `entry` has waited at `now`. Stamps come from different
    /// threads, so `now` may trail the entry's; that is no wait at all.
    private static func age(of entry: Entry, at now: UInt64) -> UInt64 {
        now > entry.frame.submittedMicroseconds
            ? now - entry.frame.submittedMicroseconds : 0
    }

    /// Enters await-random-access with no IRAP in hand; returns whether
    /// that starts a recovery. An episode still waiting for its IRAP has
    /// already asked; one whose pending IRAP was just lost asks again.
    private mutating func awaitRandomAccess() -> Bool {
        let startsRecovery = !awaitingRandomAccess || randomAccessPending
        awaitingRandomAccess = true
        randomAccessPending = false
        return startsRecovery
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

    public var mayEnqueue: Bool { !isFlushInProgress }
}
