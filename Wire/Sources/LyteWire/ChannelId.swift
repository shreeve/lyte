// The channel registry (overview §2, core plan §2): channel numbers are wire
// contract, delivery class and priority are the send-side policy every layer
// above agrees on. Reserved numbers stay unroutable until a spec revision
// assigns them.

/// How a channel's datagrams reach the far side.
public enum DeliveryClass: Equatable, Sendable {
    /// ARQ, one long-lived ordered stream (CTRL, feature channels).
    case reliableOrdered
    /// Fire-and-forget datagrams; loss handled above (FEC) or not at all.
    case unreliable
    /// ARQ, independent one-shot message groups — no cross-group blocking
    /// (sparse idle frames, the final ratchet frame).
    case reliableOneShotGroups
}

/// The unified send-priority order (overview §2, conflict 13; the bulk
/// rung is the W10/F-2 ruling): CTRL/input > audio > fresh video >
/// video tail + retransmits > ratchet refinement > feature channels >
/// telemetry > bulk. Lower rank sends first. `refinement` has no
/// channel of its own — it rides video-active and the pacer demotes it
/// by content, not by channel number. `bulk` sits STRICTLY below
/// telemetry: the 25–50 ms feedback reports feed the congestion
/// estimator that prices the path for every media class, and a 100 MB
/// transfer is infinitely patient where a stale report mis-prices
/// audio and video (design record 20260728-053300 §1).
public enum WirePriority: UInt8, Comparable, Sendable {
    case control = 0
    case audio = 1
    case freshVideo = 2
    case videoTail = 3
    case refinement = 4
    case feature = 5
    case telemetry = 6
    case bulk = 7

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A wire channel number with its registered metadata. Any raw byte can be
/// wrapped (decoders must not reject unknown channels — routing decides),
/// but only registered channels carry a delivery class and priority.
public struct ChannelId: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Handshake, capabilities, input, mode transitions, beacon, IDR requests.
    public static let ctrl = ChannelId(rawValue: 0)
    /// Continuous Opus audio.
    public static let audio = ChannelId(rawValue: 1)
    /// ACTIVE-mode video shards, including ratchet refinement frames.
    public static let videoActive = ChannelId(rawValue: 2)
    /// Client→host congestion feedback and telemetry, 25–50 ms cadence.
    public static let feedback = ChannelId(rawValue: 3)
    /// Sparse idle frames and the final converged ratchet frame.
    public static let videoIdle = ChannelId(rawValue: 4)
    /// The bulk-transfer channel (W10 / F-2): chunked, resumable,
    /// backpressured blob transfer over its own ARQ ordered stream —
    /// the first feature channel actually built. Send class `.bulk`,
    /// the ladder's tail; later feature channels (9+) keep `.feature`
    /// so small interactive feature messages never queue behind a
    /// file.
    public static let bulkTransfer = ChannelId(rawValue: 8)

    /// Feature channels (clipboard, files, printing) start at 8.
    public static let firstFeatureChannel: UInt8 = 8

    /// Returns nil below the feature range; features are 8…255.
    public static func feature(_ number: UInt8) -> ChannelId? {
        guard number >= firstFeatureChannel else { return nil }
        return ChannelId(rawValue: number)
    }

    /// Channels 5–7 are reserved: never sent, dropped on receive.
    public var isReserved: Bool {
        (5...7).contains(rawValue)
    }

    public var isFeature: Bool {
        rawValue >= Self.firstFeatureChannel
    }

    /// Nil for the reserved range — a reserved channel has no send policy.
    public var deliveryClass: DeliveryClass? {
        switch rawValue {
        case Self.ctrl.rawValue: return .reliableOrdered
        case Self.audio.rawValue: return .unreliable
        case Self.videoActive.rawValue: return .unreliable
        case Self.feedback.rawValue: return .unreliable
        case Self.videoIdle.rawValue: return .reliableOneShotGroups
        case Self.firstFeatureChannel...: return .reliableOrdered
        default: return nil
        }
    }

    /// The channel's default send class; nil for the reserved range.
    public var priority: WirePriority? {
        switch rawValue {
        case Self.ctrl.rawValue: return .control
        case Self.audio.rawValue: return .audio
        case Self.videoActive.rawValue: return .freshVideo
        case Self.feedback.rawValue: return .telemetry
        case Self.videoIdle.rawValue: return .videoTail
        case Self.bulkTransfer.rawValue: return .bulk
        case Self.firstFeatureChannel...: return .feature
        default: return nil
        }
    }
}
