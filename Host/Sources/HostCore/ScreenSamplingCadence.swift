/// Sans-IO cadence behind the direct eye's scanout observer.
///
/// Sampling is phase-stable and never catches up in a burst: when the shell
/// arrives late, the missed beats are counted and the next deadline remains
/// on the original 60 Hz grid. The platform loop owns sleeping.
public struct ScreenSamplingCadence: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case sample(skippedBeats: UInt64)
        case wait(untilMicroseconds: UInt64)
    }

    public let periodMicroseconds: UInt64
    private var nextBeatMicroseconds: UInt64?

    public init(periodMicroseconds: UInt64 = 16_667) {
        precondition(periodMicroseconds > 0)
        self.periodMicroseconds = periodMicroseconds
    }

    public mutating func poll(nowMicroseconds: UInt64) -> Verdict {
        guard let next = nextBeatMicroseconds else {
            nextBeatMicroseconds = nowMicroseconds &+ periodMicroseconds
            return .sample(skippedBeats: 0)
        }
        guard nowMicroseconds >= next else {
            return .wait(untilMicroseconds: next)
        }
        let skipped = (nowMicroseconds - next) / periodMicroseconds
        nextBeatMicroseconds = next &+ (skipped &+ 1) &* periodMicroseconds
        return .sample(skippedBeats: skipped)
    }

    public mutating func reset() {
        nextBeatMicroseconds = nil
    }
}
