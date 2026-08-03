// Chroma pairing is declaration-as-choice: Best is represented by exactly
// one advertised mode, never by preference order inside a multi-mode list.
// Role types keep their own policy; this function owns the shared singleton
// shape they exchange and recognize.

public enum ChromaPairing: Sendable {
    public static func bestSingleton<Mode>(_ yuv444: Mode) -> [Mode] {
        [yuv444]
    }
}
