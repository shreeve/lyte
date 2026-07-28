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
    }

    func testSummaryFormatting() {
        XCTAssertEqual(EncoderRecipe.sessionDefault.summary, "p4/ull/qres")
        XCTAssertEqual(EncoderRecipe.sunshineBaseline.summary, "p1/ull/qres")
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
