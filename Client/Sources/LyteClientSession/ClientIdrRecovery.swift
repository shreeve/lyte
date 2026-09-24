import LyteWire

/// The client's IDR-request policy, IO-free: every broken-reference verdict
/// (fec-impossible, abandoned repair, skipped frames) joins one bounded
/// recovery episode, which ends only when a usable IRAP is accepted.
///
/// The first demand is due at once. Further damage never mints a second
/// request; it only updates the episode's newest frame and count. An open
/// episode is also the render gate: frames already queued when damage was
/// found must not race the IRAP, so only random-access frames pass. Because
/// the 0x10 request is ARQ-exempt and fire-and-forget, an outstanding
/// episode re-asks every `retryIntervalMicroseconds` — by default 500 ms:
/// twice the 250 ms repair/stale horizon, ten or more feedback cadences, and
/// thirty 60 fps frame opportunities.
public struct ClientIdrRecovery: Sendable {
    public struct Stats: Sendable, Equatable {
        public var verdicts: UInt64 = 0
        public var requestsSent: UInt64 = 0
        public var episodesStarted: UInt64 = 0
        public var episodesCompleted: UInt64 = 0
        public var retryRequests: UInt64 = 0
        public var recoveryOutstanding = false

        public init() {}
    }

    public static let defaultRetryIntervalMicroseconds: UInt64 = 500_000

    public let retryIntervalMicroseconds: UInt64
    public private(set) var stats = Stats()

    private struct Episode {
        var newestDamagedFrame: FrameNumber
        var damageCount: UInt64
        var lastSentAt: ClientTimestamp?
    }
    private var episode: Episode?
    private var nextRequestSeq: UInt32 = 0

    public init(
        retryIntervalMicroseconds: UInt64 = defaultRetryIntervalMicroseconds
    ) {
        self.retryIntervalMicroseconds = max(1, retryIntervalMicroseconds)
    }

    public var isOutstanding: Bool { episode != nil }

    /// One broken-reference verdict. Opens an episode (its request is due
    /// immediately) or joins the open one; true when it joined.
    @discardableResult
    public mutating func recordDemand(frame: FrameNumber) -> Bool {
        stats.verdicts += 1
        if var current = episode {
            current.newestDamagedFrame = frame
            current.damageCount &+= 1
            episode = current
            return true
        }
        episode = Episode(
            newestDamagedFrame: frame, damageCount: 1, lastSentAt: nil)
        stats.episodesStarted += 1
        stats.recoveryOutstanding = true
        return false
    }

    /// Whether a frame may reach the renderer now: any frame outside an
    /// episode, only a random-access one inside it.
    public func admits(isRandomAccess: Bool) -> Bool {
        episode == nil || isRandomAccess
    }

    /// The request to send now: the episode's first, or a retry once the
    /// interval since the last one has passed. Nil when nothing is due.
    public mutating func requestDue(now: ClientTimestamp) -> IdrRequest? {
        guard var current = episode else { return nil }
        if let last = current.lastSentAt {
            guard now.microseconds(since: last)
                >= Int64(retryIntervalMicroseconds)
            else { return nil }
            stats.retryRequests += 1
        }
        current.lastSentAt = now
        episode = current
        let request = IdrRequest(
            requestSeq: nextRequestSeq,
            frame: current.newestDamagedFrame,
            coalescedCount: UInt8(min(current.damageCount, 255))
        )
        nextRequestSeq &+= 1
        stats.requestsSent += 1
        return request
    }

    /// Closes the open episode: the render path accepted an IRAP. Receiving
    /// shards, a refusal, or another clean inter frame never clears it.
    public mutating func noteUsableIrapAccepted() {
        guard episode != nil else { return }
        episode = nil
        stats.episodesCompleted += 1
        stats.recoveryOutstanding = false
    }
}
