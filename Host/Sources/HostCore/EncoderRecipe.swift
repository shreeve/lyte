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
    /// HEVC profile ("main"/"main10"/"rext"); "" leaves the wrapper's
    /// default. The Best-tier 4:4:4 posture sets "rext" explicitly —
    /// declaration over inference (V-1: the wrapper would auto-select
    /// it for 4:4:4 input, and we still say what we mean).
    public var profile: String
    /// nvenc `rgb_mode` ("yuv420"/"yuv444"): what the wrapper does with
    /// packed-RGB input; "" leaves its default (4:2:0). "yuv444" is the
    /// owner-decision-2 Best path — the driver converts internally,
    /// 601-limited, signed truthfully by the C leaf (V-1 measured the
    /// tag TRUE by 56 dB; V-2 proved it correct at the glass).
    public var rgbMode: String
    /// The capped-CQ ratchet floor (cq + qmin): where the static-desktop
    /// QP walk stops. 12 is the shipped Good-tier floor (spec §3's
    /// visually-lossless target); the Best tier carries its own (V-4).
    public var ratchetFloorQP: Int

    public init(preset: String, tune: String, multipass: String,
                spatialAQ: Bool, temporalAQ: Bool, aqStrength: Int,
                profile: String = "", rgbMode: String = "",
                ratchetFloorQP: Int = 12) {
        self.preset = preset
        self.tune = tune
        self.multipass = multipass
        self.spatialAQ = spatialAQ
        self.temporalAQ = temporalAQ
        self.aqStrength = aqStrength
        self.profile = profile
        self.rgbMode = rgbMode
        self.ratchetFloorQP = ratchetFloorQP
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

    /// The Best-tier (chroma 4:4:4) posture — sessionDefault plus the
    /// owner-decision-2 color path (rgb_mode 601-limited under Rext,
    /// V-1/V-2 co-signed) and the Best-mode ratchet floor.
    ///
    /// V-4 floor verdict (corpus harness, pup RTX 4050 → M5 VT
    /// hardware, cq12/8/4/1 raced): cq4 is the knee — pooled text
    /// +3.6…+3.9 dB over cq12 (41.7–44.3 → 45.6–47.1) at ~zero
    /// steady-state cost (keepalives 95→98 B, capacity ~145 fps both,
    /// converged all-skip either way); cq1 buys ≤+0.2 dB more on two
    /// corpora and LOSES 0.46 dB on the third. Beyond the floor the
    /// path saturates: the 601-limited round trip caps text at
    /// ~46–47 dB and gratings at ±3 even with transparent coding —
    /// that residual belongs to the conversion, not to any cq value.
    public static let best444 = EncoderRecipe(
        preset: "p4", tune: "ull", multipass: "qres",
        spatialAQ: false, temporalAQ: false, aqStrength: 0,
        profile: "rext", rgbMode: "yuv444", ratchetFloorQP: 4)

    /// This recipe re-postured for the Best tier: the chroma knobs and
    /// floor from `best444`, everything else (operator --enc-*
    /// overrides included) carried — so an A/B leg's preset override
    /// rides into a 4:4:4 session unchanged.
    public func chroma444() -> EncoderRecipe {
        var r = self
        r.profile = EncoderRecipe.best444.profile
        r.rgbMode = EncoderRecipe.best444.rgbMode
        r.ratchetFloorQP = EncoderRecipe.best444.ratchetFloorQP
        return r
    }

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
    public static let validProfiles = ["", "main", "main10", "rext"]
    public static let validRgbModes = ["", "yuv420", "yuv444"]

    /// Knob-level validation for the CLI seam: the C leaf would also
    /// reject bad values (loudly, at open), but the operator deserves
    /// the error at parse time, before capture starts.
    public enum KnobError: Error, Equatable {
        case preset(String)
        case tune(String)
        case multipass(String)
        case aqStrength(Int)
        case profile(String)
        case rgbMode(String)
        case ratchetFloorQP(Int)
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
        guard EncoderRecipe.validProfiles.contains(profile) else {
            throw KnobError.profile(profile)
        }
        guard EncoderRecipe.validRgbModes.contains(rgbMode) else {
            throw KnobError.rgbMode(rgbMode)
        }
        guard ratchetFloorQP >= 1, ratchetFloorQP <= 51 else {
            throw KnobError.ratchetFloorQP(ratchetFloorQP)
        }
        return self
    }

    /// One-line posture for the startup print and the harness summary,
    /// e.g. "p4/ull/qres" or "p4/ull/qres+rext/yuv444".
    public var summary: String {
        var s = "\(preset)/\(tune)/\(multipass)"
        if spatialAQ {
            s += "+saq"
            if aqStrength > 0 { s += "\(aqStrength)" }
        }
        if temporalAQ { s += "+taq" }
        if !profile.isEmpty { s += "+\(profile)" }
        if !rgbMode.isEmpty { s += "/\(rgbMode)" }
        return s
    }
}
