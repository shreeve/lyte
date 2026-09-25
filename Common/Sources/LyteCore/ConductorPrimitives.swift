// The Conductor's score
// (docs/decisions/20260803-050422-metronome-playout-design.md): the one
// beat both ends play to. Host sampling and the client grid must agree or
// every frame steps a beat.

/// The score's beat: 60 Hz, as whole microseconds.
public enum ScoreBeat {
    public static let periodMicroseconds: UInt64 = 16_667
}
