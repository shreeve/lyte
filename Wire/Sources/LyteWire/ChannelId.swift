// The channel registry: channel numbers are wire contract; delivery class
// and priority are the send-side policy every layer above agrees on.

/// How a channel's datagrams reach the far side.
public enum DeliveryClass: Equatable, Sendable {
    /// ARQ, one long-lived ordered stream (CTRL, feature channels).
    case reliableOrdered
    /// Fire-and-forget datagrams; loss handled above (FEC) or not at all.
    case unreliable
    /// ARQ, independent one-shot message groups — no cross-group blocking.
    /// Registered for sparse idle frames; no v1 end sends on such a channel.
    case reliableOneShotGroups
}

/// The unified send-priority order; lower rank sends first.
/// `refinement` has no channel of its own — it rides video-active and the
/// pacer demotes it by content. `bulk` sits strictly below telemetry: the
/// feedback reports price the path for every media class, and a bulk
/// transfer is patient where a stale report mis-prices audio and video.
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
    /// Registered for sparse idle frames; unused in v1 — IdleFrame rides
    /// CTRL one-shot groups and nothing sends on chan 4.
    public static let videoIdle = ChannelId(rawValue: 4)
    /// Chunked, resumable blob transfer over its own ARQ ordered stream.
    /// Send class `.bulk`; channels 9+ keep `.feature` so small interactive
    /// messages never queue behind a file.
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

extension ChannelId: CustomStringConvertible {
    /// The registry name, for logs and dissectors: `ctrl`, `audio`,
    /// `video-active`, `feedback`, `video-idle`, `reserved` (5–7),
    /// `bulk-transfer` (8), and `feature` for the rest of 9…255.
    public var description: String {
        switch self {
        case .ctrl: return "ctrl"
        case .audio: return "audio"
        case .videoActive: return "video-active"
        case .feedback: return "feedback"
        case .videoIdle: return "video-idle"
        case .bulkTransfer: return "bulk-transfer"
        default: return isReserved ? "reserved" : "feature"
        }
    }
}
