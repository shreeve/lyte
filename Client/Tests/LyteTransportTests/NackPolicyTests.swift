import LyteClientTestKit
import LyteTransport
import LyteWire
import XCTest

final class NackPolicyTests: XCTestCase {
    // MARK: - Policy discipline (dedupe, deadline, permanence)

    func testPolicyAsksOnceEverAndEscalatesOnDeadline() throws {
        let emitted = LockedBytePile()
        let escalated = LockedBytePile()
        let policy = NackPolicy(
            config: NackPolicyConfig(
                staleBudgetMicroseconds: 250_000,
                repairDeadlineMicroseconds: 100_000),
            rtt: { 5_000 },
            emit: { entries in
                for entry in entries {
                    emitted.append([UInt8(entry.frame.rawValue)]
                                   + entry.missingShards)
                }
            },
            escalate: { frame, _ in
                escalated.append([UInt8(frame.rawValue)])
            })
        let t0 = ClientTimestamp(microseconds: 1_000)
        let frame = FrameNumber(rawValue: 9)

        // Below parity: FEC owns it — no ask.
        policy.handle(.nackCandidates(
            frame: frame, missingShardIndices: [2],
            parityShards: 2, frameAgeMicroseconds: 0), now: t0)
        XCTAssertEqual(emitted.count, 0)

        // Past parity: ask, once.
        policy.handle(.nackCandidates(
            frame: frame, missingShardIndices: [2, 5, 7],
            parityShards: 2, frameAgeMicroseconds: 1_000), now: t0)
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.all[0], [9, 2, 5, 7])

        // The same picture again: nothing new — silence (dedupe).
        policy.handle(.nackCandidates(
            frame: frame, missingShardIndices: [2, 5, 7],
            parityShards: 2, frameAgeMicroseconds: 2_000), now: t0)
        XCTAssertEqual(emitted.count, 1)

        // A grown picture: only the NEW index rides.
        policy.handle(.nackCandidates(
            frame: frame, missingShardIndices: [2, 5, 7, 8],
            parityShards: 2, frameAgeMicroseconds: 3_000), now: t0)
        XCTAssertEqual(emitted.count, 2)
        XCTAssertEqual(emitted.all[1], [9, 8])

        // A fec-impossible verdict inside the deadline defers.
        XCTAssertTrue(policy.shouldDeferFecImpossible(frame: frame, now: t0))

        // The deadline passes without completion: exactly ONE
        // escalation, and later beats stay quiet.
        policy.tick(now: t0.advanced(byMicroseconds: 100_000))
        XCTAssertEqual(escalated.count, 1)
        XCTAssertEqual(escalated.all[0], [9])
        policy.tick(now: t0.advanced(byMicroseconds: 150_000))
        XCTAssertEqual(escalated.count, 1)
        XCTAssertFalse(policy.shouldDeferFecImpossible(
            frame: frame, now: t0.advanced(byMicroseconds: 150_000)))

        let stats = policy.snapshotStats()
        XCTAssertEqual(stats.pastParityFrames, 1)
        XCTAssertEqual(stats.nackEntriesEmitted, 2)
        XCTAssertEqual(stats.shardsAsked, 4)
        XCTAssertEqual(stats.framesEscalatedToIdr, 1)
    }

    /// The whole-loss rule (the HS-33 unmasked gap): a frame that never
    /// landed a single shard has no book, no ask, and no fecImpossible
    /// verdict — before this rule, NOTHING reached the IDR requester and
    /// the broken reference chain stood until an unrelated wake IDR. A
    /// gone-range of such frames must escalate exactly once (one IDR
    /// heals everything), and a range already covered by a rule-4
    /// asked-frame escalation must NOT double-fire.
    func testWhollyLostFrameEscalatesToIdrOncePerRange() throws {
        let escalated = LockedBytePile()
        let policy = NackPolicy(
            config: NackPolicyConfig(
                staleBudgetMicroseconds: 250_000,
                repairDeadlineMicroseconds: 100_000),
            rtt: { 5_000 },
            emit: { _ in },
            escalate: { frame, _ in
                escalated.append([UInt8(frame.rawValue)])
            })
        let t0 = ClientTimestamp(microseconds: 1_000)

        // A three-frame numbering gap, no shard ever seen for any of
        // them: ONE escalation, anchored at the range's first frame.
        policy.handle(.framesGone(
            from: FrameNumber(rawValue: 20),
            through: FrameNumber(rawValue: 22)), now: t0)
        XCTAssertEqual(escalated.count, 1)
        XCTAssertEqual(escalated.all[0], [20])
        XCTAssertEqual(policy.snapshotStats().whollyLostEscalations, 1)

        // A range where one frame WAS asked (rule 4's territory): the
        // asked frame escalates, the whole-loss rule stands down.
        let asked = FrameNumber(rawValue: 31)
        policy.handle(.nackCandidates(
            frame: asked, missingShardIndices: [1, 2, 3],
            parityShards: 2, frameAgeMicroseconds: 0), now: t0)
        policy.handle(.framesGone(
            from: FrameNumber(rawValue: 30),
            through: FrameNumber(rawValue: 32)), now: t0)
        XCTAssertEqual(escalated.count, 2)
        XCTAssertEqual(escalated.all[1], [31])
        let stats = policy.snapshotStats()
        XCTAssertEqual(stats.framesEscalatedToIdr, 1)
        XCTAssertEqual(stats.whollyLostEscalations, 1)
    }

    /// A gone-range holding only settled books changes nothing: decoded
    /// frames emitted (no reference break), and an already-escalated
    /// range never re-fires.
    func testWholeLossRuleIgnoresSettledBooks() throws {
        let escalated = LockedBytePile()
        let policy = NackPolicy(
            config: NackPolicyConfig(
                staleBudgetMicroseconds: 250_000,
                repairDeadlineMicroseconds: 100_000),
            rtt: { 5_000 },
            emit: { _ in },
            escalate: { frame, _ in
                escalated.append([UInt8(frame.rawValue)])
            })
        let t0 = ClientTimestamp(microseconds: 1_000)
        let frame = FrameNumber(rawValue: 40)

        // A tracked, below-parity frame (book exists, never asked)
        // that then DECODES: its later gone-signal must not escalate.
        policy.handle(.nackCandidates(
            frame: frame, missingShardIndices: [2],
            parityShards: 2, frameAgeMicroseconds: 0), now: t0)
        policy.handle(.frameDecoded(frame: frame), now: t0)
        policy.handle(.framesGone(from: frame, through: frame), now: t0)
        XCTAssertEqual(escalated.count, 0)

        // An undecoded gone-range escalates once — and the SAME range
        // signalled again (books now settled .gone) stays quiet.
        let lost = FrameNumber(rawValue: 41)
        policy.handle(.nackCandidates(
            frame: lost, missingShardIndices: [2],
            parityShards: 2, frameAgeMicroseconds: 0), now: t0)
        policy.handle(.framesGone(from: lost, through: lost), now: t0)
        XCTAssertEqual(escalated.count, 1)
        policy.handle(.framesGone(from: lost, through: lost), now: t0)
        XCTAssertEqual(escalated.count, 1)
        XCTAssertEqual(policy.snapshotStats().whollyLostEscalations, 1)
    }

    func testPolicyStaleRefusalIsPermanentAndCompletionCounts() throws {
        let emitted = LockedBytePile()
        let escalated = LockedBytePile()
        let policy = NackPolicy(
            config: NackPolicyConfig(staleBudgetMicroseconds: 50_000),
            rtt: { 40_000 },   // a slow path: 40 ms RTT
            emit: { entries in
                for _ in entries { emitted.append([]) }
            },
            escalate: { _, _ in escalated.append([]) })
        let t0 = ClientTimestamp(microseconds: 1_000)

        // age 20 ms + rtt 40 ms ≥ 50 ms budget → refused, forever.
        let old = FrameNumber(rawValue: 3)
        policy.handle(.nackCandidates(
            frame: old, missingShardIndices: [0, 1],
            parityShards: 1, frameAgeMicroseconds: 20_000), now: t0)
        XCTAssertEqual(emitted.count, 0)
        policy.handle(.nackCandidates(
            frame: old, missingShardIndices: [0, 1, 2],
            parityShards: 1, frameAgeMicroseconds: 25_000), now: t0)
        XCTAssertEqual(emitted.count, 0)
        XCTAssertFalse(policy.shouldDeferFecImpossible(frame: old, now: t0))
        XCTAssertEqual(policy.snapshotStats().asksSuppressedStale, 1)

        // A young frame asks; repairs land; completion books the heal
        // and the deadline never escalates it.
        let young = FrameNumber(rawValue: 4)
        policy.handle(.nackCandidates(
            frame: young, missingShardIndices: [1, 2],
            parityShards: 1, frameAgeMicroseconds: 2_000), now: t0)
        XCTAssertEqual(emitted.count, 1)
        policy.handle(.repairShardAccepted(frame: young, shardIndex: 1),
                      now: t0)
        policy.handle(.repairShardAccepted(frame: young, shardIndex: 2),
                      now: t0)
        policy.handle(.frameDecoded(frame: young), now: t0)
        policy.tick(now: t0.advanced(byMicroseconds: 300_000))
        XCTAssertEqual(escalated.count, 0)
        let stats = policy.snapshotStats()
        XCTAssertEqual(stats.repairShardsReceived, 2)
        XCTAssertEqual(stats.framesCompletedByRepair, 1)

        // An asked frame whose group DIES escalates immediately — and
        // is never asked for again, whatever pictures still arrive.
        let doomed = FrameNumber(rawValue: 5)
        policy.handle(.nackCandidates(
            frame: doomed, missingShardIndices: [0, 1],
            parityShards: 1, frameAgeMicroseconds: 2_000), now: t0)
        policy.handle(.framesGone(from: doomed, through: doomed), now: t0)
        XCTAssertEqual(escalated.count, 1)
        let askedBefore = emitted.count
        policy.handle(.nackCandidates(
            frame: doomed, missingShardIndices: [0, 1, 3],
            parityShards: 1, frameAgeMicroseconds: 3_000), now: t0)
        XCTAssertEqual(emitted.count, askedBefore,
                       "a settled frame must never be re-asked")

        // Answer classification, pinned per branch: an answer for the
        // GONE frame is superseded; a straggler for the DECODED frame
        // is late; a second copy of an ACCEPTED repair is a duplicate;
        // and signals for never-asked shards touch no repair book.
        policy.handle(.staleShardDropped(frame: doomed), now: t0)
        policy.handle(.staleShardDropped(frame: young), now: t0)
        policy.handle(.satisfiedShardDropped(frame: young, shardIndex: 1),
                      now: t0)
        let unasked = FrameNumber(rawValue: 77)
        policy.handle(.staleShardDropped(frame: unasked), now: t0)
        policy.handle(.satisfiedShardDropped(frame: unasked, shardIndex: 0),
                      now: t0)
        let classified = policy.snapshotStats()
        XCTAssertEqual(classified.repairsSuperseded, 1)
        XCTAssertEqual(classified.repairsLate, 1)
        XCTAssertEqual(classified.repairsDuplicate, 1)
    }

    func testRefusalActsOnceOnlyForALiveAsk() throws {
        let emitted = LockedBytePile()
        let escalated = LockedBytePile()
        let policy = NackPolicy(
            rtt: { 1_000 },
            emit: { entries in
                for _ in entries { emitted.append([]) }
            },
            escalate: { frame, _ in
                escalated.append([UInt8(frame.rawValue)])
            }
        )
        let now = ClientTimestamp(microseconds: 10_000)
        let asked = FrameNumber(rawValue: 5)

        policy.handle(.nackCandidates(
            frame: asked,
            missingShardIndices: [0, 1],
            parityShards: 1,
            frameAgeMicroseconds: 0
        ), now: now)
        XCTAssertEqual(emitted.count, 1)

        policy.handleRefusal(frame: asked, now: now)
        policy.handleRefusal(frame: asked, now: now)
        policy.handleRefusal(
            frame: FrameNumber(rawValue: 77),
            now: now
        )

        XCTAssertEqual(escalated.all, [[5]], "one ask acts at most once")
        let stats = policy.snapshotStats()
        XCTAssertEqual(stats.refusalsReceived, 3)
        XCTAssertEqual(stats.refusalsActedOn, 1)
        XCTAssertEqual(stats.refusalsIgnored, 2)
    }

}
