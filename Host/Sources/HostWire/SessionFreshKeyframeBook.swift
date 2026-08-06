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
    /// HS-25: an unprotectable frame was dropped — re-anchor references.
    public static let unprotectableDrop = FreshKeyframeDemand(rawValue: 1 << 4)
    /// A rate fall purged queued video mid-flight — re-anchor.
    public static let fallPurge = FreshKeyframeDemand(rawValue: 1 << 5)

    /// The books' short names, in bit order.
    public var names: [String] {
        var out: [String] = []
        if contains(.pathPromotion) { out.append("path-promotion") }
        if contains(.clientRequest) { out.append("client-request") }
        if contains(.machineWake) { out.append("wake") }
        if contains(.machineRecovery) { out.append("recovery") }
        if contains(.unprotectableDrop) { out.append("unprotectable") }
        if contains(.fallPurge) { out.append("fall-purge") }
        return out
    }
}

/// Production telemetry for demands actually consumed by the encoder poll.
/// `demands` counts forced-IDR opportunities; cause fields may sum higher
/// because one encoded IDR can satisfy several coalesced causes.
public struct FreshKeyframeDemandCounts: Equatable, Sendable {
    public private(set) var demands: UInt64 = 0
    public private(set) var pathPromotions: UInt64 = 0
    public private(set) var clientRequests: UInt64 = 0
    public private(set) var machineWakes: UInt64 = 0
    public private(set) var machineRecoveries: UInt64 = 0
    public private(set) var unprotectableDrops: UInt64 = 0
    public private(set) var fallPurges: UInt64 = 0

    public init() {}

    public mutating func record(_ demand: FreshKeyframeDemand) {
        guard !demand.isEmpty else { return }
        demands &+= 1
        if demand.contains(.pathPromotion) { pathPromotions &+= 1 }
        if demand.contains(.clientRequest) { clientRequests &+= 1 }
        if demand.contains(.machineWake) { machineWakes &+= 1 }
        if demand.contains(.machineRecovery) { machineRecoveries &+= 1 }
        if demand.contains(.unprotectableDrop) { unprotectableDrops &+= 1 }
        if demand.contains(.fallPurge) { fallPurges &+= 1 }
    }
}

/// The sans-IO, take-once owner of every Host fresh-keyframe demand.
public struct SessionFreshKeyframeBook: Equatable, Sendable {
    public private(set) var pending: FreshKeyframeDemand = []

    public init() {}

    public mutating func arm(_ demand: FreshKeyframeDemand) {
        pending.formUnion(demand)
    }

    /// Returns every coalesced cause and clears them as one encoder poll.
    public mutating func take() -> FreshKeyframeDemand {
        defer { pending = [] }
        return pending
    }
}
