// The channel registry: channel numbers are wire contract. Send policy
// per channel (delivery class, pacing priority) belongs to the ends.

/// A wire channel number. Any raw byte can be wrapped (decoders must not
/// reject unknown channels — routing decides).
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
    /// Chunked, resumable blob transfer over its own ARQ ordered stream,
    /// the first feature channel (8…255).
    public static let bulkTransfer = ChannelId(rawValue: 8)

    /// Channels 5–7 are reserved: never sent, dropped on receive.
    public var isReserved: Bool {
        (5...7).contains(rawValue)
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
