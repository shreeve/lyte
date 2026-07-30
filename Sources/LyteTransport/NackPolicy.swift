// NackPolicy (CL-12): the client's half of targeted repair — the policy
// that turns VideoAssembler presumption into W4a NACK entries, closing
// HS-17's deferred item. Resiliency §1.1 as written:
//
//   rule 1  FEC failure on a frame → NACK naming the missing shards.
//           "Failure" is the past-parity verdict, not first loss: while
//           presumed losses ≤ parity, RS completes from what is
//           plausibly in flight and a NACK would spend repair bandwidth
//           on a frame FEC already owns. The assembler's enriched
//           nackCandidates event carries the arithmetic (missing
//           indices vs parityShards).
//   rule 2  Receiver-side, the verdict is geometry-immediate (the
//           packet-threshold-3 presumption), no timer.
//   rule 3  mirrored client-side: don't ask for what will arrive stale.
//           The host gates on ITS freeze budget; this end gates on the
//           assembler's own horizon — a repair landing after the group's
//           `staleAfterMicroseconds` eviction is a wasted datagram, so
//           ask iff frameAge + RTT < that budget. RTT = the CL-10
//           model's min-RTT (0 before the first beacon echo: optimistic,
//           and the host's gate still protects the wire).
//   rule 4  the deadline backstop: an asked frame that hasn't completed
//           within `repairDeadlineMicroseconds` — repair lost, host
//           refused, or the ask's report died — escalates to the
//           EXISTING coalesced IDR requester. Never a new pathway.
//
// Dedupe discipline (the host enforces one-attempt per shard; don't
// spam): each (frame, shard index) is asked exactly ONCE, ever. A frame
// refused by the staleness gate is refused forever (frames only get
// older); its fec-impossible verdict falls straight through to the IDR
// path, undeferred.
//
// Sans-IO: no clock reads, no sockets — time arrives as parameters, the
// emit/escalate closures are the only exits. One lock; safe from the
// receive thread and the cadence timer alike.

import Foundation
import LyteWire

/// What the video pipeline forwards from the assembler's event stream —
/// everything this policy (and its books) needs, nothing more.
public enum VideoRepairSignal: Sendable {
    /// The assembler's enriched presumption picture for one frame.
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
    /// The assembler dropped a shard whose slot is already satisfied
    /// (filled, or the whole group decoded) — the late/duplicate repair
    /// classification input. The drop itself is the assembler's clean
    /// no-op; this signal only feeds the books.
    case satisfiedShardDropped(frame: FrameNumber, shardIndex: UInt8)
    /// The assembler dropped a shard for a frame whose turn has passed
    /// (emitted, skipped, or evicted from the tracker) — the
    /// late/superseded classification input.
    case staleShardDropped(frame: FrameNumber)
}

public struct NackPolicyConfig: Sendable {
    /// Rule 3's client mirror: ask iff frameAge + RTT < this budget.
    /// Defaults to the assembler's staleAfterMicroseconds — the horizon
    /// past which the group is evicted and a repair drops as stale.
    public var staleBudgetMicroseconds: Int64
    /// Rule 4: an asked frame not completed this long after its first
    /// ask escalates to the coalesced IDR request (the HS-17 probe's
    /// figure).
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

public final class NackPolicy: @unchecked Sendable {
    /// The wire-view stats line's diet.
    public struct Stats: Sendable {
        /// Frames whose presumption went past parity (FEC failure).
        public var pastParityFrames: UInt64 = 0
        /// NACK entries handed to the feedback path.
        public var nackEntriesEmitted: UInt64 = 0
        /// Distinct (frame, shard) asks — the dedupe's denominator.
        public var shardsAsked: UInt64 = 0
        /// Frames refused by the rule-3 staleness gate (no ask; their
        /// fec-impossible verdict goes straight to IDR).
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
        /// Answers to an ask that landed after the frame no longer
        /// needed them — the slot was already filled or the frame had
        /// already decoded (FEC or stragglers got there first). Clean
        /// no-ops at the assembler; counted here so the live books can
        /// reconcile against the host's repair ledger. Honesty note: a
        /// straggling ORIGINAL for an asked shard is indistinguishable
        /// at this seam (the drop event carries no seq) and counts the
        /// same — it is equally an answer the frame no longer needed.
        public var repairsLate: UInt64 = 0
        /// Asked shards whose repair was already ACCEPTED once — a
        /// duplicated answer (network duplication; the host itself
        /// one-attempts).
        public var repairsDuplicate: UInt64 = 0
        /// HS-32: explicit 0x23 refusals decoded off the wire.
        public var refusalsReceived: UInt64 = 0
        /// Refusals that ended a live ask's wait — straight to the
        /// (rate-windowed) IDR path, no 250 ms deadline burned.
        public var refusalsActedOn: UInt64 = 0
        /// Unknown/duplicate refusals, ignored loud (the drop-reason
        /// counter): no book for the frame, no live ask, or the ask
        /// had already settled (decoded, expired, or refused twice).
        public var refusalsIgnored: UInt64 = 0
        /// Answers for frames the client had already abandoned (skipped,
        /// evicted, or rule-4 escalated to IDR) — superseded by newer
        /// frames or the keyframe heal.
        public var repairsSuperseded: UInt64 = 0
    }

    public let config: NackPolicyConfig

    /// Newest min-RTT estimate in µs, nil before the first beacon echo.
    private let rtt: @Sendable () -> Int64?
    /// Sends freshly-minted entries down the feedback path (enqueue +
    /// out-of-cadence flush — the host's cadence-derived freeze budget
    /// (HS-32, ~1.5 cadences) rewards asks that travel promptly).
    private let emit: @Sendable ([FeedbackReport.NackEntry]) -> Void
    /// Rule 4's exit: the existing coalesced IDR requester.
    private let escalate: @Sendable (FrameNumber, ClientTimestamp) -> Void

    private struct FrameBook {
        /// How an asked frame's story ended — the late-vs-superseded
        /// discriminator for answers that keep arriving afterward.
        enum Fate {
            case pending
            /// Decoded (originals, FEC, repairs — any mix).
            case decoded
            /// Abandoned: skipped/evicted, or rule-4 escalated to IDR.
            case gone
        }
        var askedIndices: Set<UInt8> = []
        /// Asked indices whose repair was accepted (the duplicate
        /// discriminator).
        var acceptedRepairIndices: Set<UInt8> = []
        var firstAskAt: ClientTimestamp?
        var refusedStale = false
        var sawRepair = false
        var fate: Fate = .pending
        var settled: Bool { fate != .pending }
        var lastTouched: ClientTimestamp
    }

    private let lock = NSLock()
    private var books: [UInt32: FrameBook] = [:]
    private var stats = Stats()

    public init(
        config: NackPolicyConfig = NackPolicyConfig(),
        rtt: @escaping @Sendable () -> Int64?,
        emit: @escaping @Sendable ([FeedbackReport.NackEntry]) -> Void,
        escalate: @escaping @Sendable (FrameNumber, ClientTimestamp) -> Void
    ) {
        self.config = config
        self.rtt = rtt
        self.emit = emit
        self.escalate = escalate
    }

    public func snapshotStats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    // MARK: Signals

    /// One forwarded assembler signal. Emissions/escalations fire
    /// outside the lock.
    public func handle(_ signal: VideoRepairSignal, now: ClientTimestamp) {
        switch signal {
        case .nackCandidates(let frame, let missing, let parity, let age):
            handleCandidates(
                frame: frame, missingIndices: missing,
                parityShards: parity, frameAgeMicroseconds: age, now: now
            )
        case .repairShardAccepted(let frame, let index):
            lock.lock()
            stats.repairShardsReceived += 1
            if var book = books[frame.rawValue] {
                book.sawRepair = true
                if book.askedIndices.contains(index) {
                    book.acceptedRepairIndices.insert(index)
                }
                book.lastTouched = now
                books[frame.rawValue] = book
            }
            lock.unlock()
        case .frameDecoded(let frame):
            lock.lock()
            if var book = books[frame.rawValue], !book.settled {
                if book.sawRepair, !book.askedIndices.isEmpty {
                    stats.framesCompletedByRepair += 1
                }
                book.fate = .decoded
                book.lastTouched = now
                books[frame.rawValue] = book
            }
            lock.unlock()
        case .framesGone(let from, let through):
            var expired: [FrameNumber] = []
            lock.lock()
            var frame = from
            while true {
                if var book = books[frame.rawValue], !book.settled {
                    if !book.askedIndices.isEmpty {
                        // Asked, never completed: rule 4, now.
                        stats.framesEscalatedToIdr += 1
                        expired.append(frame)
                    }
                    book.fate = .gone
                    book.lastTouched = now
                    books[frame.rawValue] = book
                }
                if frame == through { break }
                frame = frame.next
            }
            lock.unlock()
            for frame in expired { escalate(frame, now) }
        case .satisfiedShardDropped(let frame, let index):
            // Only asked shards are repair accounting; an unasked
            // duplicate is ordinary network duplication of an original.
            lock.lock()
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
            lock.unlock()
        case .staleShardDropped(let frame):
            lock.lock()
            if var book = books[frame.rawValue], !book.askedIndices.isEmpty {
                // Decoded frames age out of the tracker and their turn
                // passes — a straggling answer is merely LATE. A frame
                // that died undecoded (skipped/evicted/escalated) was
                // SUPERSEDED by newer frames or the IDR heal. (.pending
                // cannot reach here in practice: a frame's turn passing
                // always emits decoded or framesGone first; classified
                // as superseded if it ever does.)
                if book.fate == .decoded {
                    stats.repairsLate += 1
                } else {
                    stats.repairsSuperseded += 1
                }
                book.lastTouched = now
                books[frame.rawValue] = book
            }
            lock.unlock()
        }
    }

    /// HS-32: one decoded 0x23 refusal off the wire. The host judged
    /// the ask stale (budget gone, superseded by a newer IDR, or
    /// store-evicted) — the frame's repair wait ends NOW, straight to
    /// the existing coalesced IDR requester (already rate-windowed)
    /// instead of burning the rest of the 250 ms deadline. The
    /// deadline REMAINS as the fallback for lost refusals (the message
    /// is fire-and-forget by contract). Unknown and duplicate refusals
    /// are ignored loud (the drop-reason counter): a refusal for a
    /// frame never asked, or for an ask that already settled, acts on
    /// nothing. Reasons are not distinguished here — every actionable
    /// refusal has the same exit, and the reason traveled for the logs.
    public func handleRefusal(frame: FrameNumber, now: ClientTimestamp) {
        var act = false
        lock.lock()
        stats.refusalsReceived += 1
        if var book = books[frame.rawValue],
           !book.settled, !book.askedIndices.isEmpty {
            stats.refusalsActedOn += 1
            // The IDR supersedes the repair path (the rule-4 shape):
            // any answer still in flight lands as superseded.
            book.fate = .gone
            book.lastTouched = now
            books[frame.rawValue] = book
            act = true
        } else {
            stats.refusalsIgnored += 1
        }
        lock.unlock()
        if act { escalate(frame, now) }
    }

    /// The core's fec-impossible funnel asks before routing to the IDR
    /// requester: true = a repair is pending and within its deadline —
    /// hold the IDR (rule 4's window); false = request away.
    public func shouldDeferFecImpossible(
        frame: FrameNumber, now: ClientTimestamp
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let book = books[frame.rawValue],
              !book.settled, !book.refusedStale,
              let asked = book.firstAskAt,
              now.microseconds(since: asked) < config.repairDeadlineMicroseconds
        else { return false }
        stats.fecImpossibleDeferred += 1
        return true
    }

    /// The cadence beat: rule-4 deadlines and book hygiene. Escalations
    /// fire outside the lock.
    public func tick(now: ClientTimestamp) {
        var expired: [FrameNumber] = []
        lock.lock()
        for (key, var book) in books {
            if !book.settled, let asked = book.firstAskAt,
               now.microseconds(since: asked)
                   >= config.repairDeadlineMicroseconds {
                stats.framesEscalatedToIdr += 1
                // The IDR supersedes the repair path: any answer still
                // in flight lands as superseded, not late.
                book.fate = .gone
                book.lastTouched = now
                books[key] = book
                expired.append(FrameNumber(rawValue: key))
            }
            // Settled books linger one deadline for late signals, then go.
            if book.settled,
               now.microseconds(since: book.lastTouched)
                   >= config.repairDeadlineMicroseconds * 2 {
                books.removeValue(forKey: key)
            }
        }
        lock.unlock()
        for frame in expired { escalate(frame, now) }
    }

    // MARK: Interior

    private func handleCandidates(
        frame: FrameNumber,
        missingIndices: [UInt8],
        parityShards: Int,
        frameAgeMicroseconds: Int64,
        now: ClientTimestamp
    ) {
        var entryToEmit: FeedbackReport.NackEntry?
        lock.lock()
        var book = books[frame.rawValue]
            ?? makeBookLocked(now: now)
        book.lastTouched = now
        defer {
            books[frame.rawValue] = book
            lock.unlock()
            if let entryToEmit { emit([entryToEmit]) }
        }
        guard !book.settled, !book.refusedStale else { return }

        // Rule 1: FEC failure = past parity. Below it, FEC owns the frame.
        guard missingIndices.count > parityShards else { return }
        if book.askedIndices.isEmpty { stats.pastParityFrames += 1 }

        // Rule 3, mirrored: a repair that lands past the assembler's
        // stale horizon is wasted — refuse, and refuse forever (the
        // frame only gets older). Its fecImpossible then IDRs directly.
        let rttMicroseconds = rtt() ?? 0
        guard frameAgeMicroseconds + rttMicroseconds
            < config.staleBudgetMicroseconds
        else {
            if book.askedIndices.isEmpty {
                book.refusedStale = true
                stats.asksSuppressedStale += 1
            }
            return
        }

        // Dedupe: each (frame, shard) asked once, ever.
        let fresh = missingIndices.filter { !book.askedIndices.contains($0) }
        guard !fresh.isEmpty,
              let entry = try? FeedbackReport.NackEntry(
                  frame: frame, missingShards: fresh
              )
        else { return }
        book.askedIndices.formUnion(fresh)
        if book.firstAskAt == nil { book.firstAskAt = now }
        stats.nackEntriesEmitted += 1
        stats.shardsAsked += UInt64(fresh.count)
        entryToEmit = entry
    }

    /// Capacity discipline for the books (hostile frame spray).
    private func makeBookLocked(now: ClientTimestamp) -> FrameBook {
        if books.count >= config.maxTrackedFrames,
           let oldest = books.min(by: {
               $0.value.lastTouched < $1.value.lastTouched
           }) {
            books.removeValue(forKey: oldest.key)
        }
        return FrameBook(lastTouched: now)
    }
}
