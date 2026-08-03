// CaptureBeatBook — the Conductor's witness on the host side. The
// #83 metronome made the client's cadence exact, and the residual
// shudder moved upstream: ~20 capture beats per 30 s never flip on
// the glass under encode load. This book decides WHO skipped them.
//
// The doorbell (an FB_ID poll) is the only eye on the compositor,
// and it is blind while the loop works (grab, blit, encode, deliver,
// service all share the thread). So every skip has exactly two
// possible authors, and the doorbell's own poll cadence tells them
// apart:
//
//   source — the doorbell was watching the whole gap (no blind
//            interval reached the threshold) and the FB never
//            changed: the COMPOSITOR skipped the beat.
//   loop   — the doorbell went blind long enough to miss a flip:
//            OUR loop ate the beat; the caller's stage timings say
//            which stage.
//
// Sans-IO: the caller feeds monotonic microsecond stamps for every
// doorbell poll and every detected flip; the book returns skip
// verdicts and keeps the totals. Gaps at or beyond the stillness
// threshold are a quiet desktop, not a skip — booked separately.

public struct CaptureBeatBookConfig: Sendable {
    /// Flip-to-flip gap that books as a skipped beat (~1.5 beats
    /// at 60 Hz).
    public var skipThresholdMicroseconds: UInt64
    /// Gap at or beyond this is stillness (no motion), never a skip.
    public var stillThresholdMicroseconds: UInt64
    /// A doorbell blind interval this long inside the gap convicts
    /// the loop; anything shorter leaves the compositor guilty.
    public var blindThresholdMicroseconds: UInt64

    public init(
        skipThresholdMicroseconds: UInt64 = 25_000,
        stillThresholdMicroseconds: UInt64 = 250_000,
        blindThresholdMicroseconds: UInt64 = 8_000
    ) {
        self.skipThresholdMicroseconds = max(skipThresholdMicroseconds, 1)
        self.stillThresholdMicroseconds = max(
            stillThresholdMicroseconds, self.skipThresholdMicroseconds)
        self.blindThresholdMicroseconds = max(blindThresholdMicroseconds, 1)
    }
}

public struct CaptureBeatBook: Sendable {
    public enum Verdict: String, Sendable {
        case source
        case loop
    }

    public struct SkipEvent: Equatable, Sendable {
        public var gapMicroseconds: UInt64
        /// The longest doorbell blind interval inside the gap.
        public var blindMicroseconds: UInt64
        public var verdict: Verdict
    }

    private let config: CaptureBeatBookConfig
    private var lastPollMicroseconds: UInt64?
    private var lastFlipMicroseconds: UInt64?
    private var blindMaxSinceFlipMicroseconds: UInt64 = 0

    public private(set) var flips = 0
    public private(set) var skips = 0
    public private(set) var sourceSkips = 0
    public private(set) var loopSkips = 0
    public private(set) var stillGaps = 0
    /// Largest motion-window gap seen (stillness excluded).
    public private(set) var gapMaxMicroseconds: UInt64 = 0
    /// Largest doorbell blind interval seen anywhere in the run.
    public private(set) var blindMaxMicroseconds: UInt64 = 0

    public init(config: CaptureBeatBookConfig = CaptureBeatBookConfig()) {
        self.config = config
    }

    /// Every doorbell read (change or not) — including the read that
    /// detects a flip, called before noteFlip for that read.
    public mutating func notePoll(nowMicroseconds: UInt64) {
        defer { lastPollMicroseconds = nowMicroseconds }
        guard let last = lastPollMicroseconds,
              nowMicroseconds > last else { return }
        let blind = nowMicroseconds - last
        if blind > blindMaxSinceFlipMicroseconds {
            blindMaxSinceFlipMicroseconds = blind
        }
        if blind > blindMaxMicroseconds {
            blindMaxMicroseconds = blind
        }
    }

    /// A detected FB change, stamped at detection (not at grab).
    /// Returns the skip event when the gap books as a skipped beat.
    public mutating func noteFlip(
        nowMicroseconds: UInt64
    ) -> SkipEvent? {
        defer {
            lastFlipMicroseconds = nowMicroseconds
            blindMaxSinceFlipMicroseconds = 0
        }
        flips += 1
        guard let last = lastFlipMicroseconds,
              nowMicroseconds > last else { return nil }
        let gap = nowMicroseconds - last
        if gap >= config.stillThresholdMicroseconds {
            stillGaps += 1
            return nil
        }
        if gap > gapMaxMicroseconds { gapMaxMicroseconds = gap }
        guard gap >= config.skipThresholdMicroseconds else { return nil }
        skips += 1
        let blind = blindMaxSinceFlipMicroseconds
        let verdict: Verdict = blind >= config.blindThresholdMicroseconds
            ? .loop : .source
        switch verdict {
        case .source: sourceSkips += 1
        case .loop: loopSkips += 1
        }
        return SkipEvent(
            gapMicroseconds: gap, blindMicroseconds: blind,
            verdict: verdict)
    }
}
