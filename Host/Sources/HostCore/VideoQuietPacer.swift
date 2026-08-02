// VideoQuietPacer — the postures design's video quiet/wake axis
// (docs/20260802-013946-postures-design.md), sans-IO: the caller
// supplies "seconds since the last damage or client input" and gets
// back the keepalive interval now in force plus, exactly once per
// step, the announcement to send. The ladder: 1 s while active
// (idle < 30 s), then 2 → 4 → 8 → 16 → 30 s, one rung per further
// 30 s of stillness. A wake (idle collapsing back under the
// threshold — fresh damage or an input packet) steps straight back
// to 1 s and announces active once.
//
// Pure function of idle time plus one word of memory (the interval
// last announced) — no clocks, no wire, no thread opinions.

public struct VideoQuietPacerConfig: Sendable {
    /// Stillness before the first backoff rung — the doc's ~30 s.
    public var quietAfterSeconds: Double
    /// Seconds of further stillness per additional rung.
    public var rungSeconds: Double
    /// The deepest interval (the doc's ceiling; beacon-only "zero"
    /// is a future posture, not an interval).
    public var maxIntervalSeconds: UInt8

    public init(
        quietAfterSeconds: Double = 30,
        rungSeconds: Double = 30,
        maxIntervalSeconds: UInt8 = 30
    ) {
        self.quietAfterSeconds = max(quietAfterSeconds, 1)
        self.rungSeconds = max(rungSeconds, 1)
        self.maxIntervalSeconds = max(maxIntervalSeconds, 2)
    }
}

public struct VideoQuietPacer: Sendable {
    /// What to announce, when a step just happened.
    public struct Announcement: Equatable, Sendable {
        public var quiet: Bool
        public var keepaliveSeconds: UInt8
    }

    public struct Verdict: Equatable, Sendable {
        /// The keepalive interval now in force.
        public var keepaliveSeconds: Double
        /// Non-nil exactly once per posture/interval change.
        public var announce: Announcement?
    }

    public let config: VideoQuietPacerConfig
    /// The interval last announced (1 = active; the session starts
    /// active by contract, so no opening announcement fires).
    private var announcedInterval: UInt8 = 1

    public init(config: VideoQuietPacerConfig = VideoQuietPacerConfig()) {
        self.config = config
    }

    /// The ladder, as a pure function of stillness.
    public func interval(idleSeconds: Double) -> UInt8 {
        guard idleSeconds >= config.quietAfterSeconds else { return 1 }
        let rungs = Int((idleSeconds - config.quietAfterSeconds)
            / config.rungSeconds)
        // Rung 0 = 2 s, doubling each rung, capped at the ceiling
        // (the exponent clamp keeps the shift safe for any idle).
        let unclamped = 1 << min(rungs + 1, 7)
        return UInt8(min(unclamped, Int(config.maxIntervalSeconds)))
    }

    /// One assessment beat. Announcements fire exactly on changes —
    /// steps down the ladder announce quiet with the new interval;
    /// the collapse back to 1 s announces active once.
    public mutating func assess(idleSeconds: Double) -> Verdict {
        let now = interval(idleSeconds: idleSeconds)
        guard now != announcedInterval else {
            return Verdict(keepaliveSeconds: Double(now), announce: nil)
        }
        announcedInterval = now
        return Verdict(
            keepaliveSeconds: Double(now),
            announce: Announcement(quiet: now > 1, keepaliveSeconds: now))
    }
}
