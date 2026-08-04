import LyteWire

/// The sans-IO owner of the Host session's ACTIVE → IDLE frame handoff.
///
/// The retained converged frame waits for damage to stay quiet, then receives
/// a nonzero reliable one-shot group. `Session` owns ARQ admission and the
/// lifecycle machine; this value commits allocation only after ARQ accepts the
/// send and retires the handoff only when that exact group is acknowledged.
public struct SessionIdleHandoffBook: Equatable, Sendable {
    public private(set) var lastDamageAtNanoseconds: UInt64?
    public private(set) var nextDeadlineNanoseconds: UInt64?
    public private(set) var finalFrameGroup: ArqGroupId?

    private var retainedFrame: IdleFrame?
    private var nextOneShotGroup: UInt16

    public init() {
        nextOneShotGroup = 1
    }

    init(nextOneShotGroup: UInt16) {
        self.nextOneShotGroup = nextOneShotGroup == 0 ? 1 : nextOneShotGroup
    }

    /// Fresh damage aborts every pending or in-flight idle handoff while
    /// retaining the damage instant as the quiet-window anchor.
    public mutating func noteDamage(now: UInt64) {
        retainedFrame = nil
        lastDamageAtNanoseconds = now
        nextDeadlineNanoseconds = nil
        finalFrameGroup = nil
    }

    /// Retains the newest converged frame. Returns true when the lifecycle
    /// machine may begin the handoff immediately; otherwise `nextDeadline`
    /// names the end of the damage-quiet window.
    public mutating func noteConverged(
        _ frame: IdleFrame,
        now: UInt64,
        quietWindowNanoseconds: UInt64
    ) -> Bool {
        retainedFrame = frame
        if let damagedAt = lastDamageAtNanoseconds,
           now &- damagedAt < quietWindowNanoseconds {
            nextDeadlineNanoseconds = damagedAt &+ quietWindowNanoseconds
            return false
        }
        nextDeadlineNanoseconds = nil
        return true
    }

    /// Releases one quiet-window hold exactly once.
    public mutating func takeDueHandoff(now: UInt64) -> Bool {
        guard retainedFrame != nil,
              let due = nextDeadlineNanoseconds,
              now >= due
        else { return false }
        nextDeadlineNanoseconds = nil
        return true
    }

    /// The retained frame and next group without consuming either. A refused
    /// ARQ admission can therefore retry byte-for-byte with the same group.
    public func pendingFinalFrameSend() -> (
        frame: IdleFrame, group: ArqGroupId
    )? {
        guard let retainedFrame else { return nil }
        return (retainedFrame, ArqGroupId(rawValue: nextOneShotGroup))
    }

    /// Commits a group only after ARQ accepted the prepared send.
    @discardableResult
    public mutating func commitFinalFrameSent() -> ArqGroupId {
        let group = ArqGroupId(rawValue: nextOneShotGroup)
        finalFrameGroup = group
        nextOneShotGroup &+= 1
        if nextOneShotGroup == 0 { nextOneShotGroup = 1 }
        return group
    }

    /// Retires only the exact in-flight final frame. Foreign and late groups
    /// cannot clear a newer handoff or trigger the lifecycle transition.
    public mutating func acknowledge(_ group: ArqGroupId) -> Bool {
        guard group == finalFrameGroup else { return false }
        finalFrameGroup = nil
        retainedFrame = nil
        nextDeadlineNanoseconds = nil
        return true
    }
}
