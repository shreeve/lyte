// The video quiet/wake axis, sans-IO: the caller supplies seconds since
// the last damage or client input and gets back the keepalive interval
// in force plus, exactly once per step, the announcement to send. The
// ladder: 1 s while active (idle < 30 s), then 2 → 4 → 8 → 16 → 30 s,
// one rung per further 30 s of stillness. A wake steps straight back to
// 1 s and announces active once.

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

    /// Stillness before the first backoff rung.
    private static let quietAfterSeconds = 30.0
    /// Seconds of further stillness per additional rung.
    private static let rungSeconds = 30.0
    /// The deepest interval.
    public static let maxIntervalSeconds: UInt8 = 30

    /// The interval last announced (1 = active; the session starts
    /// active by contract, so no opening announcement fires).
    private var announcedInterval: UInt8 = 1

    public init() {}

    /// The ladder, as a pure function of stillness.
    public func interval(idleSeconds: Double) -> UInt8 {
        guard idleSeconds >= Self.quietAfterSeconds else { return 1 }
        // Rung 0 = 2 s, doubling each rung, capped at the ceiling. The
        // rung count is clamped while still a Double, so any idle
        // (including +infinity) converts safely; NaN never passes the guard.
        let rungs = Int(min(
            (idleSeconds - Self.quietAfterSeconds) / Self.rungSeconds, 6))
        let unclamped = 1 << (rungs + 1)
        return UInt8(min(unclamped, Int(Self.maxIntervalSeconds)))
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
