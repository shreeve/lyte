/// The radio watchdog's debounce, pure so it can be tested. One `check`
/// per 5 s tick while a stream is active, fed awdl0's own UP flag:
///
/// - radio DOWN (held): healthy; the strike count and alarm clear.
/// - radio UP (loose): the first sighting asks the caller to re-engage
///   (a fresh engage respawns a crashed daemon via launchd); three
///   consecutive loose checks latch the alarm.
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
