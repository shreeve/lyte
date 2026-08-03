// THE CONDUCTOR's shared primitives (tier 3 of the standardization,
// docs/20260803-050422-metronome-playout-design.md): the law-machinery
// that is LITERALLY IDENTICAL across instruments lives here, spelled
// once. Instruments keep their own verbs and constants — and their
// doctrine: audio's clock of record is the DAC (never HostClockModel;
// the ear forgives slow drift, never a click) and audio sizes its
// cushion from the detrended window SPREAD, not a percentile (the
// former p99 discarded exactly the late/PLC events — a measured fix,
// not drift). Those asymmetries are decisions of record; nothing in
// this file may flatten them.
//
//   ProofCounter     — the proof-before-shed law: cushion is easy to
//                      raise and slow to hand back; evidence must
//                      accumulate before one scheduled give-back
//                      (video's slip proof, audio's decay hold/step,
//                      audio's retarget cadence).

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
