// THE CONDUCTOR's shared primitives (docs/20260803-050422-metronome-playout-
// design.md). Instruments keep their own verbs, constants and doctrine:
// audio's clock of record is the DAC (never HostClockModel) and audio sizes
// its cushion from the detrended window spread, not a percentile. Nothing
// here may flatten those asymmetries.
//
//   ScoreBeat    — the one beat both ends play to: the host samples the
//                  screen on it and the client conductor steps its grid by
//                  it. The two must be equal, or every frame steps a beat
//                  per mismatched source step.
//   ProofCounter — audio's sample-cadenced proof-before-shed law. Video uses
//                  elapsed injected time because its source cadence is
//                  content-driven.

/// The score's beat: 60 Hz, as whole microseconds.
public enum ScoreBeat {
    public static let periodMicroseconds: UInt64 = 16_667
}

/// The proof-before-shed law's counter: evidence accumulates one
/// sample at a time, any contrary event resets it, and the shed may
/// fire only once the threshold is reached. Cushion rises free and
/// is handed back only against sustained proof — one scheduled move
/// per proof, never a smear.
public struct ProofCounter: Sendable, Equatable {
    public private(set) var count = 0

    public init() {}

    public mutating func advance() { count += 1 }

    public mutating func reset() { count = 0 }

    public func reached(_ threshold: Int) -> Bool {
        count >= threshold
    }
}
