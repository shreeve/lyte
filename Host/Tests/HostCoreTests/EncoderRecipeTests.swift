import XCTest
import HostCore

// THE GATE (HS-24): the shipped NVENC recipe, pinned as data. The C
// leaf holds no defaults — this policy is the only place the product's
// preset/tune/multipass/AQ posture lives, so a recipe change must move
// these pins deliberately, citing the A/B ladder table that justified
// it (the blessed adoption bar: measured PSNR-at-bitrate gain with fps
// and input→photon held).
final class EncoderRecipeTests: XCTestCase {

    func testShippedRecipePinned() {
        let r = EncoderRecipe.sessionDefault
        XCTAssertEqual(r.preset, "p4",
                       "the HS-24 adoption: +0.77/+0.85 dB at matched "
                           + "8/20 Mbps on motion, +12.4 dB at half the "
                           + "spend on text, encode well inside the "
                           + "60 fps budget — preset changes require a "
                           + "new ladder verdict, not drift")
        XCTAssertEqual(r.tune, "ull",
                       "ll measured ≤+0.06 dB ≈ noise (HS-24)")
        XCTAssertEqual(r.multipass, "qres",
                       "disabled lost 2-3 dB on motion; fullres was "
                           + "inconsistent for +0.5 ms (HS-24)")
        XCTAssertFalse(r.spatialAQ,
                       "spatial AQ measured -0.3…-0.4 dB PSNR at "
                           + "matched rate on BOTH corpora (HS-24)")
        XCTAssertFalse(r.temporalAQ,
                       "temporal AQ opens but is a measured no-op "
                           + "(HS-24)")
        XCTAssertEqual(r.aqStrength, 0)
        XCTAssertEqual(r.profile, "", "the Good tier leaves the wrapper's "
            + "profile default — V-4 touched only the Best tier")
        XCTAssertEqual(r.rgbMode, "", "packed RGB → the wrapper's 4:2:0 "
            + "path, unchanged")
        XCTAssertEqual(r.ratchetFloorQP, 12,
                       "spec §3's visually-lossless floor — the shipped "
                           + "Good-tier posture, byte-identical to HS-24's")
    }

    // THE GATE (H4 V-4): the Best-tier (4:4:4) recipe, pinned as data.
    // Chroma path per owner decision 2 (rgb_mode 601-limited under
    // Rext, V-1/V-2 co-signed at the glass); floor per the V-4 corpus
    // race (cq12/8/4/1): cq4 is the knee — pooled text +3.6…+3.9 dB
    // over cq12 at ~zero steady-state cost, and past it the
    // 601-limited round trip is the ceiling, not the codec.
    func testBestTierRecipePinned() {
        let b = EncoderRecipe.best444
        XCTAssertEqual(b.preset, "p4", "the Best tier shares HS-24's "
            + "adopted knobs — only chroma and the floor split")
        XCTAssertEqual(b.tune, "ull")
        XCTAssertEqual(b.multipass, "qres")
        XCTAssertFalse(b.spatialAQ)
        XCTAssertFalse(b.temporalAQ)
        XCTAssertEqual(b.aqStrength, 0)
        XCTAssertEqual(b.profile, "rext",
                       "declaration over inference — the wrapper would "
                           + "auto-select Rext for 4:4:4, we say it")
        XCTAssertEqual(b.rgbMode, "yuv444",
                       "owner decision 2: the driver's free conversion, "
                           + "601-limited, signed truthfully by the leaf")
        XCTAssertEqual(b.ratchetFloorQP, 4,
                       "the V-4 floor race's knee: cq1 buys ≤+0.2 dB "
                           + "more and loses 0.46 dB on text-200")
    }

    func testChroma444CarriesOperatorOverrides() {
        XCTAssertEqual(EncoderRecipe.sessionDefault.chroma444(),
                       EncoderRecipe.best444,
                       "the shipped Good recipe re-postured IS the "
                           + "shipped Best recipe")
        // An A/B leg's --enc-* override rides into the Best posture
        // unchanged; only the chroma knobs and floor move.
        var overridden = EncoderRecipe.sessionDefault
        overridden.preset = "p1"
        let best = overridden.chroma444()
        XCTAssertEqual(best.preset, "p1")
        XCTAssertEqual(best.profile, "rext")
        XCTAssertEqual(best.rgbMode, "yuv444")
        XCTAssertEqual(best.ratchetFloorQP, 4)
    }

    func testSunshineBaselineStaysTheIncumbent() {
        // The named A/B baseline is Sunshine's exact posture (their doc
        // §7) and never moves with our adoptions.
        let s = EncoderRecipe.sunshineBaseline
        XCTAssertEqual(s.preset, "p1")
        XCTAssertEqual(s.tune, "ull")
        XCTAssertEqual(s.multipass, "qres")
        XCTAssertFalse(s.spatialAQ)
        XCTAssertFalse(s.temporalAQ)
        XCTAssertEqual(s.aqStrength, 0)
    }

    func testValidationAcceptsTheWholeKnobSpace() throws {
        for preset in EncoderRecipe.validPresets {
            for tune in EncoderRecipe.validTunes {
                for multipass in EncoderRecipe.validMultipass {
                    _ = try EncoderRecipe(
                        preset: preset, tune: tune, multipass: multipass,
                        spatialAQ: true, temporalAQ: false,
                        aqStrength: 15
                    ).validated()
                }
            }
        }
        _ = try EncoderRecipe.sessionDefault.validated()
        _ = try EncoderRecipe.sunshineBaseline.validated()
        _ = try EncoderRecipe.best444.validated()
        for profile in EncoderRecipe.validProfiles {
            for rgbMode in EncoderRecipe.validRgbModes {
                var r = EncoderRecipe.sessionDefault
                r.profile = profile
                r.rgbMode = rgbMode
                _ = try r.validated()
            }
        }
    }

    func testValidationRejectsBadKnobs() {
        var r = EncoderRecipe.sessionDefault
        r.preset = "p8"
        XCTAssertThrowsError(try r.validated()) {
            XCTAssertEqual($0 as? EncoderRecipe.KnobError, .preset("p8"))
        }
        r = EncoderRecipe.sessionDefault
        r.tune = "uhq" // the tuning that explodes latency — never valid
        XCTAssertThrowsError(try r.validated()) {
            XCTAssertEqual($0 as? EncoderRecipe.KnobError, .tune("uhq"))
        }
        r = EncoderRecipe.sessionDefault
        r.multipass = "2pass"
        XCTAssertThrowsError(try r.validated()) {
            XCTAssertEqual($0 as? EncoderRecipe.KnobError,
                           .multipass("2pass"))
        }
        r = EncoderRecipe.sessionDefault
        r.aqStrength = 16
        XCTAssertThrowsError(try r.validated()) {
            XCTAssertEqual($0 as? EncoderRecipe.KnobError, .aqStrength(16))
        }
        r.aqStrength = -1
        XCTAssertThrowsError(try r.validated())
        r = EncoderRecipe.sessionDefault
        r.profile = "high444" // an H.264-ism, not this wrapper's surface
        XCTAssertThrowsError(try r.validated()) {
            XCTAssertEqual($0 as? EncoderRecipe.KnobError,
                           .profile("high444"))
        }
        r = EncoderRecipe.sessionDefault
        r.rgbMode = "yuv422" // dormant on Ada silicon — no encode path
        XCTAssertThrowsError(try r.validated()) {
            XCTAssertEqual($0 as? EncoderRecipe.KnobError,
                           .rgbMode("yuv422"))
        }
        r = EncoderRecipe.sessionDefault
        r.ratchetFloorQP = 0 // cq 0 means CBR at the leaf — never a floor
        XCTAssertThrowsError(try r.validated()) {
            XCTAssertEqual($0 as? EncoderRecipe.KnobError,
                           .ratchetFloorQP(0))
        }
        r.ratchetFloorQP = 52
        XCTAssertThrowsError(try r.validated())
    }

    func testSummaryFormatting() {
        XCTAssertEqual(EncoderRecipe.sessionDefault.summary, "p4/ull/qres")
        XCTAssertEqual(EncoderRecipe.sunshineBaseline.summary, "p1/ull/qres")
        XCTAssertEqual(EncoderRecipe.best444.summary,
                       "p4/ull/qres+rext/yuv444")
        let saq = EncoderRecipe(
            preset: "p4", tune: "ull", multipass: "qres",
            spatialAQ: true, temporalAQ: false, aqStrength: 8)
        XCTAssertEqual(saq.summary, "p4/ull/qres+saq8")
        let taq = EncoderRecipe(
            preset: "p4", tune: "ll", multipass: "fullres",
            spatialAQ: false, temporalAQ: true, aqStrength: 0)
        XCTAssertEqual(taq.summary, "p4/ll/fullres+taq")
    }
}
