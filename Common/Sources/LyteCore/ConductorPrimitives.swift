// The Conductor's shared primitives
// (docs/decisions/20260803-050422-metronome-playout-design.md). Instruments
// keep their own constants: audio's clock of record is the DAC and its
// cushion comes from the detrended window spread, not a percentile.
//
//   ScoreBeat    — the one beat both ends play to; host sampling and the
//                  client grid must agree or every frame steps a beat.
//   ProofCounter — audio's sample-cadenced proof-before-shed law (video
//                  uses elapsed time because its cadence is content-driven).

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
