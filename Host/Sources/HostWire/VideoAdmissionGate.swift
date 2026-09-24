// VideoAdmissionGate: pre-encode admission for the capture leg. Encoding
// another changed frame while the queued video already needs its whole
// latency budget of wire time only deepens the queue — every later frame
// waits behind it — so the frame is not encoded at all. The damage is not
// lost: the leg re-observes the screen on its next beat and encodes the
// newest pixels once the queue drains below the budget.
//
// The backlog and the budget come from one locked Session snapshot
// (SessionWire.videoAdmissionPosture): kernel-pressure service debt
// against the clean/impaired queue budget, the same budget the fall purge
// uses, so admission and purge never disagree about "too deep".

public struct VideoAdmissionGate: Sendable {
    public private(set) var admitted = 0
    public private(set) var skipped = 0

    public init() {}

    /// Whether to encode this changed frame.
    public mutating func admit(
        backlogWireTimeNS: UInt64, budgetNS: UInt64
    ) -> Bool {
        guard backlogWireTimeNS < budgetNS else {
            skipped += 1
            return false
        }
        admitted += 1
        return true
    }
}
