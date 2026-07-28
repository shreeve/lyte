// EncoderRecipe: the product's NVENC recipe knobs in one testable place
// (HS-24, the supremacy plan's R4). The C leaf (CHevcEncode) takes every
// knob explicitly and holds none of its own defaults — what the product
// ships is decided HERE and pinned by tests, so a recipe change is a
// deliberate, reviewed policy move instead of drift inside a Linux-only
// C file no Mac test ever compiles.
//
// What is a knob and what is not: preset / tune / multipass / AQ are
// knobs — the A/B ladder races them under matched content and rate and
// adopts only what clears the blessed bar (measured PSNR-at-bitrate
// gain with fps and input→photon held; supremacy plan §3.4). The
// latency frame is NOT a knob: infinite GOP, zero B-frames, zero
// reorder delay, one surface live in the C leaf as invariants —
// a B-frame or a lookahead frame is buffered latency by definition.
public struct EncoderRecipe: Equatable, Sendable {
    /// NVENC performance→quality preset ladder, "p1" (fastest) …
    /// "p7" (slowest/best).
    public var preset: String
    /// "ull" (ultra-low-latency) or "ll" — tuning owns the latency
    /// shape; both forbid lookahead/B-frames at our delay=0 posture.
    public var tune: String
    /// Rate-control passes: "disabled" | "qres" | "fullres".
    public var multipass: String
    /// Spatial adaptive quantization — steers bits toward complex
    /// regions (text edges, gradients on a desktop).
    public var spatialAQ: Bool
    /// Temporal AQ. On this libavcodec wrapper it requires lookahead,
    /// which the latency frame forbids — selectable so the ladder can
    /// record the loud reject, never shippable while that holds.
    public var temporalAQ: Bool
    /// nvenc aq-strength 1…15; 0 leaves the encoder's default (8).
    public var aqStrength: Int

    public init(preset: String, tune: String, multipass: String,
                spatialAQ: Bool, temporalAQ: Bool, aqStrength: Int) {
        self.preset = preset
        self.tune = tune
        self.multipass = multipass
        self.spatialAQ = spatialAQ
        self.temporalAQ = temporalAQ
        self.aqStrength = aqStrength
    }

    /// The shipped recipe — what every session and file-mode run uses
    /// unless the operator overrides a knob for an A/B leg. Any change
    /// here cites the measured ladder table in the HS-24 wave entry.
    ///
    /// HS-24 ladder verdict (pup RTX 4050, encoder-ab.sh, matched
    /// content + rate, 360-frame legs): preset p1 → **p4** ADOPTED —
    /// +0.77/+0.85 dB luma at matched 8/20 Mbps CBR on motion,
    /// +12.4 dB at HALF the spend on scrolling text (p1's rate control
    /// is genuinely pathological on text: 2× the bits for −12 dB),
    /// +0.27 dB at −4.7% bits in the capped-CQ session posture, and
    /// the ratchet's static keepalives got ~2.5× cheaper (227 B vs
    /// 563 B at converged QP 12). Encode mean 3.1 → 4.6 ms (p99 ~6 ms,
    /// ~215 fps capacity) — a small fraction of the 60 fps budget.
    /// p5–p7 add encode time for ≤+0.09 dB over p4 (p5/p6 measured
    /// byte-identical); spatial AQ REJECTED (−0.3…−0.4 dB everywhere
    /// measured); temporal AQ REJECTED (opens, but a measured no-op);
    /// ll tuning REJECTED (≤+0.06 dB ≈ noise; ull is the established
    /// posture); multipass disabled REJECTED (−2.1…−3.0 dB motion —
    /// its desk "win" was 2.8× bit-spend, not quality-per-bit);
    /// multipass fullres REJECTED (inconsistent sign, +0.5 ms).
    public static let sessionDefault = EncoderRecipe(
        preset: "p4", tune: "ull", multipass: "qres",
        spatialAQ: false, temporalAQ: false, aqStrength: 0)

    /// Sunshine's exact posture (their doc §7) — the H0 "match the
    /// incumbent, ship" recipe. Kept as the ladder's named baseline so
    /// every A/B leg can race the incumbent recipe by name.
    public static let sunshineBaseline = EncoderRecipe(
        preset: "p1", tune: "ull", multipass: "qres",
        spatialAQ: false, temporalAQ: false, aqStrength: 0)

    public static let validPresets =
        ["p1", "p2", "p3", "p4", "p5", "p6", "p7"]
    public static let validTunes = ["ull", "ll"]
    public static let validMultipass = ["disabled", "qres", "fullres"]

    /// Knob-level validation for the CLI seam: the C leaf would also
    /// reject bad values (loudly, at open), but the operator deserves
    /// the error at parse time, before capture starts.
    public enum KnobError: Error, Equatable {
        case preset(String)
        case tune(String)
        case multipass(String)
        case aqStrength(Int)
    }

    /// Validates the assembled recipe; returns self for chaining.
    public func validated() throws -> EncoderRecipe {
        guard EncoderRecipe.validPresets.contains(preset) else {
            throw KnobError.preset(preset)
        }
        guard EncoderRecipe.validTunes.contains(tune) else {
            throw KnobError.tune(tune)
        }
        guard EncoderRecipe.validMultipass.contains(multipass) else {
            throw KnobError.multipass(multipass)
        }
        guard aqStrength >= 0, aqStrength <= 15 else {
            throw KnobError.aqStrength(aqStrength)
        }
        return self
    }

    /// One-line posture for the startup print and the harness summary,
    /// e.g. "p4/ull/qres" or "p1/ull/qres+saq8".
    public var summary: String {
        var s = "\(preset)/\(tune)/\(multipass)"
        if spatialAQ {
            s += "+saq"
            if aqStrength > 0 { s += "\(aqStrength)" }
        }
        if temporalAQ { s += "+taq" }
        return s
    }
}
