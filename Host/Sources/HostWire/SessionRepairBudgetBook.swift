import LyteWire

/// The sans-IO owner of the Host session's HS-32 repair-budget evidence.
///
/// Feedback cadence derives the ordinary freeze budget. Before anything has
/// plausibly reached the client glass, the opening IDR may instead use a
/// separately bounded attempt/byte exemption. `Session` retains report
/// decoding, repair-store access, estimator policy, counters, and events.
public struct SessionRepairBudgetBook: Equatable, Sendable {
    public private(set) var observedFeedbackCadenceNanoseconds: UInt64?
    public private(set) var lastFeedbackAtNanoseconds: UInt64?
    public private(set) var hasClientGlassEvidence = false
    public private(set) var openingIdrShardCount: Int?
    public private(set) var openingExemptRepairAttempts = 0
    public private(set) var openingExemptRepairBytes = 0

    public init() {}

    /// Retains the first opening IDR geometry; later keyframes cannot move the
    /// evidence threshold before the opening exemption has closed.
    public mutating func noteOpeningIdr(shardCount: Int) {
        guard openingIdrShardCount == nil else { return }
        openingIdrShardCount = shardCount
    }

    /// Adds one parsed report to the cadence EWMA and sticky glass-evidence
    /// book. Inter-arrival samples are clamped to the wire-pinned 25–50 ms
    /// cadence range before α = 1/8 is applied.
    public mutating func noteFeedback(
        _ report: FeedbackReport,
        now: UInt64
    ) {
        if let last = lastFeedbackAtNanoseconds {
            let sample = min(max(now &- last, 25_000_000), 50_000_000)
            observedFeedbackCadenceNanoseconds =
                observedFeedbackCadenceNanoseconds.map {
                    ($0 * 7 &+ sample) / 8
                } ?? sample
        }
        lastFeedbackAtNanoseconds = now

        guard !hasClientGlassEvidence,
              let total = openingIdrShardCount
        else { return }
        for block in report.channels
        where block.channel == .videoActive
            && block.missing == 0
            && block.received >= UInt32(total) {
            hasClientGlassEvidence = true
        }
    }

    /// The config override when present, otherwise the cadence-derived budget.
    public func freezeBudgetNanoseconds(
        override: UInt64?,
        cadenceMultiplier: Double,
        jitterAllowanceNanoseconds: UInt64
    ) -> UInt64 {
        if let override { return override }
        let cadence = observedFeedbackCadenceNanoseconds ?? 50_000_000
        let scaled = UInt64(cadenceMultiplier * Double(cadence))
        return scaled &+ jitterAllowanceNanoseconds
    }

    /// Whether this repair may bypass the ordinary freeze-budget gate.
    public func openingExemptionAvailable(
        lastIdrMatches: Bool,
        repairBytes: Int,
        maxAttempts: Int,
        maxBytes: Int
    ) -> Bool {
        !hasClientGlassEvidence
            && lastIdrMatches
            && openingExemptRepairAttempts < maxAttempts
            && openingExemptRepairBytes + repairBytes <= maxBytes
    }

    /// Commits one exemption only after the repair entered the channel.
    public mutating func commitOpeningExemptRepair(bytes: Int) {
        openingExemptRepairAttempts += 1
        openingExemptRepairBytes += bytes
    }
}
