/// The radio watchdog's debounce, extracted pure so it can be pinned
/// (the loop that drives it lives in the app target, out of any test
/// bundle's reach). Semantics — one `check` per 5 s tick while a
/// stream is active, fed awdl0's own UP flag:
///
/// - radio DOWN (held): healthy; the strike count and alarm clear.
/// - radio UP (loose): first sighting asks the caller to RE-ENGAGE
///   (a crashed daemon's connection already invalidated, so a fresh
///   engage respawns it via launchd); three consecutive loose checks
///   latch the alarm — the hold is NOT working and the overlay must
///   say so instead of pretending.
public struct RadioHoldPolicy: Sendable, Equatable {
    public private(set) var looseChecks = 0
    /// Latched while loose ≥ 3 consecutive checks; clears the moment
    /// the radio is seen held again.
    public var alarm: Bool { looseChecks >= 3 }

    public enum Action: Equatable, Sendable {
        case none
        /// First loose sighting: re-engage the helper through the full
        /// client path (only if the caller's connection isn't engaged).
        case reengage
    }

    public init() {}

    public mutating func check(radioUp: Bool) -> Action {
        guard radioUp else {
            looseChecks = 0
            return .none
        }
        looseChecks += 1
        return looseChecks == 1 ? .reengage : .none
    }

    /// Stream ended: the watchdog stops; nothing may linger into the
    /// next stream's first check.
    public mutating func reset() {
        looseChecks = 0
    }
}
