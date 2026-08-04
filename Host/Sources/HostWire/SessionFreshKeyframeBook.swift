/// Why a fresh keyframe is owed (the estimator-ramp hunt's IDR books):
/// every source coalesces here and one frame can answer several at once.
public struct FreshKeyframeDemand: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// HS-12: a path promotion re-anchors the new primary.
    public static let pathPromotion = FreshKeyframeDemand(rawValue: 1 << 0)
    /// A client 0x10 IDR request.
    public static let clientRequest = FreshKeyframeDemand(rawValue: 1 << 1)
    /// The lifecycle machine's WAKE (armNextDamageAsIdr, .lastGoodRate).
    public static let machineWake = FreshKeyframeDemand(rawValue: 1 << 2)
    /// The lifecycle machine's RECOVERY (forceIdr, .halfStaleEstimate).
    public static let machineRecovery = FreshKeyframeDemand(rawValue: 1 << 3)
    /// HS-17: a stale NACK verdict left the client stuck — re-anchor.
    public static let staleNackArm = FreshKeyframeDemand(rawValue: 1 << 4)
    /// HS-25: an unprotectable frame was dropped — re-anchor references.
    public static let unprotectableDrop = FreshKeyframeDemand(rawValue: 1 << 5)
    /// A rate fall purged queued video mid-flight — re-anchor.
    public static let fallPurge = FreshKeyframeDemand(rawValue: 1 << 6)

    /// The books' short names, in bit order.
    public var names: [String] {
        var out: [String] = []
        if contains(.pathPromotion) { out.append("path-promotion") }
        if contains(.clientRequest) { out.append("client-request") }
        if contains(.machineWake) { out.append("wake") }
        if contains(.machineRecovery) { out.append("recovery") }
        if contains(.staleNackArm) { out.append("stale-nack") }
        if contains(.unprotectableDrop) { out.append("unprotectable") }
        if contains(.fallPurge) { out.append("fall-purge") }
        return out
    }
}

/// The sans-IO, take-once owner of every Host fresh-keyframe demand.
public struct SessionFreshKeyframeBook: Equatable, Sendable {
    public private(set) var pending: FreshKeyframeDemand = []
    private var lastUnknownFrameArmAtNanoseconds: UInt64?

    public init() {}

    public mutating func arm(_ demand: FreshKeyframeDemand) {
        pending.formUnion(demand)
    }

    /// Arms the shared stale-NACK demand. Authenticated guesses naming an
    /// unknown frame are rate-limited; verdicts tied to real frame history
    /// remain unthrottled. Taking the pending demand does not reset this
    /// peer-pressure window.
    @discardableResult
    public mutating func armStaleNack(
        unknownFrame: Bool,
        now: UInt64,
        minimumUnknownFrameInterval: UInt64
    ) -> Bool {
        if unknownFrame {
            let admitted = lastUnknownFrameArmAtNanoseconds.map {
                now &- $0 >= minimumUnknownFrameInterval
            } ?? true
            guard admitted else { return false }
            lastUnknownFrameArmAtNanoseconds = now
        }
        arm(.staleNackArm)
        return true
    }

    /// Returns every coalesced cause and clears them as one encoder poll.
    public mutating func take() -> FreshKeyframeDemand {
        defer { pending = [] }
        return pending
    }
}
