import LyteWire

/// The assembler events the NACK policy consumes.
public enum VideoRepairSignal: Hashable, Sendable {
    case nackCandidates(
        frame: FrameNumber,
        missingShardIndices: [UInt8],
        parityShards: Int,
        frameAgeMicroseconds: Int64
    )
    /// A fresh-seq repair shard slotted into its group.
    case repairShardAccepted(frame: FrameNumber, shardIndex: UInt8)
    /// The frame decoded (by any mix of originals, FEC, repairs).
    case frameDecoded(frame: FrameNumber)
    /// Frames `from`…`through` will never complete (evicted or skipped)
    /// — repairs can no longer help them.
    case framesGone(from: FrameNumber, through: FrameNumber)
    /// A shard dropped because its slot (or group) was already satisfied;
    /// feeds the late/duplicate books only.
    case satisfiedShardDropped(frame: FrameNumber, shardIndex: UInt8)
    /// A shard dropped because its frame's turn passed; feeds the
    /// late/superseded books only.
    case staleShardDropped(frame: FrameNumber)

    /// The repair signal one assembler event carries, if any. Every shell
    /// feeding a `VideoAssembler` forwards these, in event order.
    public init?(_ event: VideoAssemblerEvent) {
        switch event {
        case .decoded(let unit):
            self = .frameDecoded(frame: unit.frameNumber)
        case .framesSkipped(let from, let through, _):
            self = .framesGone(from: from, through: through)
        case .evicted(let frame, _):
            self = .framesGone(from: frame, through: frame)
        case .shardDropped(.duplicateShard(let frame, let shardIndex)):
            self = .satisfiedShardDropped(frame: frame, shardIndex: shardIndex)
        case .shardDropped(.staleFrame(let frame)):
            self = .staleShardDropped(frame: frame)
        case .nackCandidates(let frame, _, let missing, let parity, let age):
            self = .nackCandidates(
                frame: frame, missingShardIndices: missing,
                parityShards: parity, frameAgeMicroseconds: age)
        case .repairShardAccepted(let frame, let index):
            self = .repairShardAccepted(frame: frame, shardIndex: index)
        case .shardDropped, .fecImpossible:
            return nil
        }
    }
}

/// The client's half of targeted repair, IO-free: turns VideoAssembler
/// presumption into NACK entries.
///
///   rule 1  NACK only past parity: below it, FEC owns the frame.
///   rule 2  the verdict is geometry-immediate (packet-threshold 3), no
///           timer.
///   rule 3  ask iff frameAge + min-RTT < the assembler's stale horizon
///           (RTT 0 before the first beacon echo; the host still gates).
///   rule 4  an asked frame not complete within the repair deadline
///           escalates to the coalesced IDR recovery.
///
/// Each (frame, shard) is asked at most once; a frame refused as stale is
/// refused forever and its fec-impossible verdict goes straight to IDR.
/// Time and the RTT arrive as parameters; every decision is returned.
public struct ClientNackPolicy: Sendable {
    /// What one input decided: entries for the next feedback report
    /// (send promptly — the host's freeze budget is cadence-derived) and
    /// frames to escalate to the coalesced IDR recovery.
    public struct Decision: Hashable, Sendable {
        public var nacks: [FeedbackReport.NackEntry] = []
        public var escalations: [FrameNumber] = []

        public init() {}
    }

    public struct Config: Sendable {
        /// Rule 3: ask iff frameAge + RTT < this budget (the assembler's
        /// staleAfterMicroseconds).
        public var staleBudgetMicroseconds: Int64
        /// Rule 4: an asked frame not completed this long after its first
        /// ask escalates to the coalesced IDR request.
        public var repairDeadlineMicroseconds: Int64
        /// Book ceiling against hostile frame-number spray; oldest evicted.
        public var maxTrackedFrames: Int

        public init(
            staleBudgetMicroseconds: Int64 = 250_000,
            repairDeadlineMicroseconds: Int64 = 250_000,
            maxTrackedFrames: Int = 128
        ) {
            self.staleBudgetMicroseconds = staleBudgetMicroseconds
            self.repairDeadlineMicroseconds = repairDeadlineMicroseconds
            self.maxTrackedFrames = maxTrackedFrames
        }
    }

    public struct Stats: Sendable, Equatable {
        /// Frames whose presumption went past parity (FEC failure).
        public var pastParityFrames: UInt64 = 0
        /// NACK entries handed to the feedback path.
        public var nackEntriesEmitted: UInt64 = 0
        /// Distinct (frame, shard) asks — the dedupe's denominator.
        public var shardsAsked: UInt64 = 0
        /// Frames refused by the rule-3 staleness gate.
        public var asksSuppressedStale: UInt64 = 0
        /// Fresh-seq repair shards the assembler accepted.
        public var repairShardsReceived: UInt64 = 0
        /// Asked frames that completed with at least one repair shard.
        public var framesCompletedByRepair: UInt64 = 0
        /// Asked frames answered by the rule-4 IDR escalation instead
        /// (deadline passed, or the group died first).
        public var framesEscalatedToIdr: UInt64 = 0
        /// fec-impossible verdicts deferred while a repair was pending.
        public var fecImpossibleDeferred: UInt64 = 0
        /// Answers that landed after their slot filled or the frame
        /// decoded. A straggling original for an asked shard is
        /// indistinguishable here and counts the same.
        public var repairsLate: UInt64 = 0
        /// Asked shards whose repair was already accepted once.
        public var repairsDuplicate: UInt64 = 0
        /// Explicit 0x23 refusals decoded off the wire.
        public var refusalsReceived: UInt64 = 0
        /// Refusals that ended a live ask's wait early.
        public var refusalsActedOn: UInt64 = 0
        /// Refusals with no live ask (unknown, or already settled).
        public var refusalsIgnored: UInt64 = 0
        /// Answers for frames already abandoned (skipped, evicted, or
        /// escalated to IDR).
        public var repairsSuperseded: UInt64 = 0
        /// Gone-ranges escalated by the whole-loss rule (one per range).
        public var whollyLostEscalations: UInt64 = 0
    }

    public let config: Config
    public private(set) var stats = Stats()

    private struct FrameBook: Sendable {
        /// Classifies later answers as late (decoded) or superseded (gone).
        enum Fate {
            case pending
            case decoded
            /// Skipped, evicted, or escalated to IDR.
            case gone
        }
        var askedIndices: Set<UInt8> = []
        /// Asked indices whose repair was accepted.
        var acceptedRepairIndices: Set<UInt8> = []
        var firstAskAt: ClientTimestamp?
        var refusedStale = false
        var sawRepair = false
        var fate: Fate = .pending
        var settled: Bool { fate != .pending }
        var lastTouched: ClientTimestamp
    }

    private var books: [UInt32: FrameBook] = [:]

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: Signals

    /// One forwarded assembler signal. `rttMicroseconds` is the newest
    /// min-RTT estimate, nil before the first beacon echo.
    public mutating func handle(
        _ signal: VideoRepairSignal,
        rttMicroseconds: Int64?,
        now: ClientTimestamp
    ) -> Decision {
        var decision = Decision()
        switch signal {
        case .nackCandidates(let frame, let missing, let parity, let age):
            if let entry = ask(
                frame: frame, missingIndices: missing,
                parityShards: parity, frameAgeMicroseconds: age,
                rttMicroseconds: rttMicroseconds, now: now
            ) {
                decision.nacks.append(entry)
            }
        case .repairShardAccepted(let frame, let index):
            stats.repairShardsReceived += 1
            if var book = books[frame.rawValue] {
                book.sawRepair = true
                if book.askedIndices.contains(index) {
                    book.acceptedRepairIndices.insert(index)
                }
                book.lastTouched = now
                books[frame.rawValue] = book
            }
        case .frameDecoded(let frame):
            if var book = books[frame.rawValue], !book.settled {
                if book.sawRepair, !book.askedIndices.isEmpty {
                    stats.framesCompletedByRepair += 1
                }
                book.fate = .decoded
                book.lastTouched = now
                books[frame.rawValue] = book
            }
        case .framesGone(let from, let through):
            // The range is host-chosen and may span ~2^32 frames: walk the
            // books (at most maxTrackedFrames), never the range.
            let span = through.rawValue &- from.rawValue
            var expired: [FrameNumber] = []
            var brokeUnhealed = false
            var booked: UInt64 = 0
            for (key, var book) in books where key &- from.rawValue <= span {
                booked += 1
                // Settled books never re-fire.
                guard !book.settled else { continue }
                if !book.askedIndices.isEmpty {
                    // Asked, never completed: rule 4, now.
                    stats.framesEscalatedToIdr += 1
                    expired.append(FrameNumber(rawValue: key))
                } else {
                    brokeUnhealed = true
                }
                book.fate = .gone
                book.lastTouched = now
                books[key] = book
            }
            // A frame with no book never landed a shard.
            if UInt64(span) + 1 > booked { brokeUnhealed = true }
            expired.sort {
                $0.rawValue &- from.rawValue < $1.rawValue &- from.rawValue
            }
            // Whole-loss rule: an unasked frame that died undecoded
            // breaks the reference chain, and no other path reaches the
            // IDR requester for it. One escalation heals the whole range
            // (unless a rule-4 escalation above already did).
            if brokeUnhealed, expired.isEmpty {
                stats.whollyLostEscalations += 1
                expired.append(from)
            }
            decision.escalations = expired
        case .satisfiedShardDropped(let frame, let index):
            // Only asked shards are repair accounting; an unasked
            // duplicate is ordinary network duplication of an original.
            if var book = books[frame.rawValue],
               book.askedIndices.contains(index) {
                if book.acceptedRepairIndices.contains(index) {
                    stats.repairsDuplicate += 1
                } else {
                    stats.repairsLate += 1
                }
                book.lastTouched = now
                books[frame.rawValue] = book
            }
        case .staleShardDropped(let frame):
            if var book = books[frame.rawValue], !book.askedIndices.isEmpty {
                // After decode an answer is late; otherwise superseded.
                if book.fate == .decoded {
                    stats.repairsLate += 1
                } else {
                    stats.repairsSuperseded += 1
                }
                book.lastTouched = now
                books[frame.rawValue] = book
            }
        }
        return decision
    }

    /// A decoded 0x23 refusal ends a live ask's repair wait now and
    /// escalates to the coalesced IDR recovery; the deadline remains the
    /// fallback for lost refusals. Refusals with no live ask are counted
    /// and ignored.
    public mutating func handleRefusal(
        frame: FrameNumber, now: ClientTimestamp
    ) -> Decision {
        var decision = Decision()
        stats.refusalsReceived += 1
        if var book = books[frame.rawValue],
           !book.settled, !book.askedIndices.isEmpty {
            stats.refusalsActedOn += 1
            // Any answer still in flight now lands as superseded.
            book.fate = .gone
            book.lastTouched = now
            books[frame.rawValue] = book
            decision.escalations = [frame]
        } else {
            stats.refusalsIgnored += 1
        }
        return decision
    }

    /// True while a repair is pending within its deadline: hold the IDR.
    public mutating func shouldDeferFecImpossible(
        frame: FrameNumber, now: ClientTimestamp
    ) -> Bool {
        guard let book = books[frame.rawValue],
              !book.settled, !book.refusedStale,
              let asked = book.firstAskAt,
              now.microseconds(since: asked) < config.repairDeadlineMicroseconds
        else { return false }
        stats.fecImpossibleDeferred += 1
        return true
    }

    /// The cadence beat: rule-4 deadlines and book hygiene.
    public mutating func tick(now: ClientTimestamp) -> Decision {
        var decision = Decision()
        for (key, var book) in books {
            if !book.settled, let asked = book.firstAskAt,
               now.microseconds(since: asked)
                   >= config.repairDeadlineMicroseconds {
                stats.framesEscalatedToIdr += 1
                // Any answer still in flight now lands as superseded.
                book.fate = .gone
                book.lastTouched = now
                books[key] = book
                decision.escalations.append(FrameNumber(rawValue: key))
            }
            // Settled books linger one deadline for late signals, then go.
            if book.settled,
               now.microseconds(since: book.lastTouched)
                   >= config.repairDeadlineMicroseconds * 2 {
                books.removeValue(forKey: key)
            }
        }
        return decision
    }

    // MARK: Interior

    /// Rules 1 and 3 plus the dedupe: the entry to send, if any.
    private mutating func ask(
        frame: FrameNumber,
        missingIndices: [UInt8],
        parityShards: Int,
        frameAgeMicroseconds: Int64,
        rttMicroseconds: Int64?,
        now: ClientTimestamp
    ) -> FeedbackReport.NackEntry? {
        var book = books[frame.rawValue] ?? makeBook(now: now)
        book.lastTouched = now
        defer { books[frame.rawValue] = book }
        guard !book.settled, !book.refusedStale else { return nil }

        // Rule 1: FEC failure = past parity. Below it, FEC owns the frame.
        guard missingIndices.count > parityShards else { return nil }
        if book.askedIndices.isEmpty { stats.pastParityFrames += 1 }

        // Rule 3: refuse forever (the frame only gets older). The RTT is
        // host-influenced; clamped, the sum cannot overflow its budget.
        let rtt = min(max(rttMicroseconds ?? 0, 0),
                      config.staleBudgetMicroseconds)
        let (horizon, overflow) = frameAgeMicroseconds
            .addingReportingOverflow(rtt)
        guard !overflow, horizon < config.staleBudgetMicroseconds else {
            if book.askedIndices.isEmpty {
                book.refusedStale = true
                stats.asksSuppressedStale += 1
            }
            return nil
        }

        // Dedupe: each (frame, shard) asked once, ever.
        let fresh = missingIndices.filter { !book.askedIndices.contains($0) }
        guard !fresh.isEmpty,
              let entry = try? FeedbackReport.NackEntry(
                  frame: frame, missingShards: fresh
              )
        else { return nil }
        book.askedIndices.formUnion(fresh)
        if book.firstAskAt == nil { book.firstAskAt = now }
        stats.nackEntriesEmitted += 1
        stats.shardsAsked += UInt64(fresh.count)
        return entry
    }

    /// Evicts the oldest book at capacity (hostile frame spray).
    private mutating func makeBook(now: ClientTimestamp) -> FrameBook {
        if books.count >= config.maxTrackedFrames,
           let oldest = books.min(by: {
               $0.value.lastTouched < $1.value.lastTouched
           }) {
            books.removeValue(forKey: oldest.key)
        }
        return FrameBook(lastTouched: now)
    }
}
