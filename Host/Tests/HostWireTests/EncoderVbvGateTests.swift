import XCTest
import HostCore
import HostWire
import LyteWire

// THE GATE (H3 plan Wave 0, D-1 — HS-20; clean-path rule + multi-window
// VBV — HS-22; the RUNG LADDER — HS-27: rate moves must stop minting
// IDRs). Pinned behaviors, each a leg below:
//
//   • THE CLEAN PATH (HS-22) — while the ceiling-derived rate (8×C/B)
//     sits at or above (1 − deadband) × the opening recipe's cap, the
//     policy is SILENT: zero directives, no first-look imposition, the
//     opening recipe rides. (Every directive is a known encoder reset +
//     forced IDR through the FFmpeg wrapper — verified against pup's
//     exact build, 8.0.1: resetEncoder=1 + forceIDR=1 on ANY rc delta,
//     unconditionally — so a withheld directive is an avoided IDR.)
//   • THE RUNG LADDER (HS-27) — the encoder posture is QUANTIZED to
//     halving rungs of the recipe cap (rung_i = baselineMax / 2^i) and
//     the applied rung is the smallest rung ≥ the live ceiling-rate
//     (round UP: the posture never sits below the wire; the PACER
//     enforces the exact fine-grained rate at zero encoder cost).
//     Every estimator move that lands inside the applied band touches
//     nothing — no directive, no reset, no IDR — and is counted in
//     `rateMovesAbsorbed` (the books' proof the new path rides). The
//     932a4c3 red this retires: 31 of 38 IDRs in 150 s were the old
//     exact-tracking policy following the estimator's saw-tooth.
//   • MAPPING at a rung — the HS-20/HS-22 derivation at the RUNG rate
//     R: max = min(baseline, R); avg follows in CBR; vbv = min(baseline
//     vbv, k × 8×C') with C' = R×B/8 and k the HS-22 window ladder at
//     R/baselineMax (≥80% ⇒ 4, ≥65% ⇒ 3, ≥50% ⇒ 2, deeper ⇒ 1). All
//     params stay CAPS against the opening posture. Corollary: rung_0
//     mins back to the baseline under a live guarded posture (HS-25),
//     so marginal squeezes and clean-boundary flapping are FREE.
//   • ASYMMETRIC HYSTERESIS — a TIGHTEN past a rung boundary (judged
//     at ceilingRate × (1 + deadband) — boundary dither parks) applies
//     IMMEDIATELY: the oversized-frame harm is the fall side, and B2's
//     protections live there. A LOOSENING (rung climb or restore)
//     fires only after the want held CONTINUOUSLY for riseSustainNS
//     (10 s default) and jumps to the rung of the window's MINIMUM
//     ceiling — the level the wire actually held. A saw-tooth hunt
//     resets the clock every fall: the posture PARKS, the whole hunt
//     costs zero encoder touches.
//   • recovery returns exactly to the baseline posture and then goes
//     silent — the policy can never leave the encoder tighter (or
//     looser) than its opening recipe once the squeeze lifts. For
//     capped-CQ without a baseline VBV ("no VBV" is inexpressible on
//     the way back — the wrapper only reads rc_buffer_size > 0) the
//     restore carries one second at the baseline cap.

final class EncoderVbvGateTests: XCTestCase {

    private static let ms: UInt64 = 1_000_000
    private static let sec: UInt64 = 1_000_000_000

    /// The HS-6 figures at 60 fps the RateEstimator gate already pins:
    /// 20 Mbps live rate → ceiling 59,937 B; 5 Mbps → 13,062 B.
    private static let ceilingAt20M = 59_937
    private static let ceilingAt5M = 13_062

    private func cbrPolicy() -> EncoderVbvPolicy {
        // lyte-host's CBR opening posture at --bitrate-mbps 10, 60 fps:
        // avg = max = 10 Mbps, single-frame VBV (bitrate / fps bits).
        EncoderVbvPolicy(config: EncoderVbvConfig(
            fps: 60,
            baselineAverageBitsPerSecond: 10_000_000,
            baselineMaxBitsPerSecond: 10_000_000,
            baselineVbvBits: 10_000_000 / 60
        ))
    }

    private func cappedCqPolicy() -> EncoderVbvPolicy {
        // --ratchet's opening posture: only the max-rate cap exists
        // (FFmpeg's nvenc wrapper zeroes avg/VBV in CQ mode).
        EncoderVbvPolicy(config: EncoderVbvConfig(
            fps: 60,
            baselineMaxBitsPerSecond: 10_000_000
        ))
    }

    // MARK: - The budget window the mapping inverts

    func testFrameBudgetWindowPinned() {
        // B = min(2/fps, 25 ms): 60 and 30 fps cap at 25 ms, 120 fps
        // rides 2/fps — the same figures the ceiling tests pin.
        XCTAssertEqual(RateEstimator.frameBudgetNS(fps: 60), 25_000_000)
        XCTAssertEqual(RateEstimator.frameBudgetNS(fps: 30), 25_000_000)
        XCTAssertEqual(RateEstimator.frameBudgetNS(fps: 120), 16_666_666)
    }

    // MARK: - The rung ladder itself

    func testRungsAreHalvingsOfTheRecipeCapRoundedUp() {
        let policy = cappedCqPolicy()
        // Round UP: the smallest rung that still covers the rate.
        XCTAssertEqual(policy.rungIndex(for: 10_000_000), 0)
        XCTAssertEqual(policy.rungIndex(for: 5_000_001), 0)
        XCTAssertEqual(policy.rungIndex(for: 5_000_000), 1)
        XCTAssertEqual(policy.rungIndex(for: 2_500_001), 1)
        XCTAssertEqual(policy.rungIndex(for: 1_920_000), 2)
        XCTAssertEqual(policy.rungIndex(for: 320_000), 4)
        XCTAssertEqual(policy.rungRate(atIndex: 0), 10_000_000)
        XCTAssertEqual(policy.rungRate(atIndex: 2), 2_500_000)
        XCTAssertEqual(policy.rungRate(atIndex: 4), 625_000)
    }

    // MARK: - Steady state (the HS-22 clean path)

    func testCbrStricterThanTheWireStaysUntouched() {
        // 10 Mbps CBR under a 20 Mbps wire: the encoder's own posture
        // is stricter than anything the ceiling derives — the policy
        // must never touch it, on the first look or the hundredth.
        let policy = cbrPolicy()
        for i in 0..<100 {
            XCTAssertNil(policy.note(
                frameByteCeiling: Self.ceilingAt20M,
                now: UInt64(i) * 16 * Self.ms
            ))
        }
        XCTAssertEqual(policy.directivesIssued, 0)
    }

    func testCleanPathCappedCqStaysOnTheOpeningRecipe() {
        // THE HS-22 HEADLINE. The wire outruns the recipe ⇒ ZERO
        // directives, ever — the opening recipe (no VBV, CQ quality)
        // rides the whole session.
        let policy = cappedCqPolicy()
        for i in 0..<100 {
            XCTAssertNil(policy.note(
                frameByteCeiling: Self.ceilingAt20M,
                now: UInt64(i) * 16 * Self.ms
            ))
        }
        XCTAssertEqual(policy.directivesIssued, 0)
        XCTAssertFalse(policy.squeezeEngaged)
    }

    func testCleanBoundaryIsTheDeadband() {
        // The clean/squeezed line is (1 − deadband) × the recipe cap =
        // 9 Mbps here, i.e. ceiling 28,125 B at the 25 ms window. AT
        // the line: clean, silent. One byte below: a squeeze — the
        // first look engages the required rung immediately (a WAKE-arm
        // tightening never waits). 8,999,680 bps needs rung_0 (10M),
        // whose capped-CQ posture is the 4-window VBV at the cap.
        let atLine = cappedCqPolicy()
        XCTAssertEqual(atLine.cleanPathRateBitsPerSecond, 9_000_000)
        XCTAssertNil(atLine.note(frameByteCeiling: 28_125, now: 0))
        XCTAssertFalse(atLine.squeezeEngaged)

        let below = cappedCqPolicy()
        let directive = below.note(frameByteCeiling: 28_124, now: 0)
        XCTAssertEqual(directive, EncoderRateDirective(
            averageBitsPerSecond: nil,
            maxBitsPerSecond: 10_000_000,
            vbvBits: 1_000_000,
            frameByteCeiling: 28_124,
            kind: .tighten
        ))
        XCTAssertTrue(below.squeezeEngaged)
        XCTAssertEqual(below.appliedRungIndex, 0)
    }

    func testMarginalSqueezeUnderTheLiveGuardedPostureIsFree() {
        // HS-25 live shape: the baseline VBV is the unprotectable-frame
        // guard's ceiling, TIGHTER than rung_0's 4-window VBV. rung_0
        // then mins back to the baseline exactly — the engage flips the
        // flag and touches NOTHING (no directive, no reset, no IDR),
        // and the later return to clean is equally free.
        let policy = EncoderVbvPolicy(config: EncoderVbvConfig(
            fps: 60,
            baselineMaxBitsPerSecond: 10_000_000,
            baselineVbvBits: 500_000
        ))
        XCTAssertNil(policy.note(frameByteCeiling: 28_124, now: 0))
        XCTAssertTrue(policy.squeezeEngaged)
        XCTAssertEqual(policy.directivesIssued, 0)

        // Sustained clean afterwards: the restore is ALSO identical to
        // what the encoder runs — silent flag-flip, still no IDR.
        for i in 1...12 {
            _ = policy.note(
                frameByteCeiling: Self.ceilingAt20M,
                now: UInt64(i) * Self.sec
            )
        }
        XCTAssertFalse(policy.squeezeEngaged)
        XCTAssertEqual(policy.directivesIssued, 0)
    }

    /// HS-23: the recipe is 50 Mbps now, and every boundary must scale
    /// WITH it — nothing in the clean-path rule, the rung ladder, or
    /// the k-ladder may be an absolute number.
    func testRecipeBoundariesScaleWithTheFiftyMbpsCeiling() {
        let policy = EncoderVbvPolicy(config: EncoderVbvConfig(
            fps: 60,
            baselineMaxBitsPerSecond: 50_000_000
        ))
        XCTAssertEqual(policy.cleanPathRateBitsPerSecond, 45_000_000)
        // At the boundary: clean, silent — the recipe rides.
        XCTAssertNil(policy.note(frameByteCeiling: 140_625, now: 0))
        XCTAssertFalse(policy.squeezeEngaged)
        // Rungs are halvings of 50 M.
        XCTAssertEqual(policy.rungRate(atIndex: 1), 25_000_000)
        XCTAssertEqual(policy.rungIndex(for: 17_000_000), 1)
        XCTAssertEqual(policy.rungIndex(for: 12_500_000), 2)
    }

    // MARK: - The mapping at a rung

    func testRateDropMapsOntoTheCoveringRung() {
        // The estimator falls to 5 Mbps (ceiling 13,062 B → 4,179,840
        // bps). The covering rung is rung_1 = 5 Mbps: avg AND max move
        // to the rung rate (CBR's min = avg = max contract), and the
        // VBV mins the rung's 2-window budget (250,000 bits at 50% —
        // k=2) against the baseline single-frame 166,666: the baseline
        // is tighter and rides.
        let policy = cbrPolicy()
        let directive = policy.note(
            frameByteCeiling: Self.ceilingAt5M, now: 1_000 * Self.ms
        )
        XCTAssertEqual(directive, EncoderRateDirective(
            averageBitsPerSecond: 5_000_000,
            maxBitsPerSecond: 5_000_000,
            vbvBits: 166_666,
            frameByteCeiling: Self.ceilingAt5M,
            kind: .tighten
        ))
        XCTAssertEqual(policy.appliedRungIndex, 1)
    }

    func testVbvWindowLadderScalesWithTheRungDepth() {
        // The k-ladder now quantizes WITH the rung (k judged at the
        // rung's own fraction of the recipe): rung_0 = 100% ⇒ k=4,
        // rung_1 = 50% ⇒ k=2, rung_2 = 25% ⇒ k=1. Capped-CQ (no
        // baseline VBV) shows the rung budgets bare.
        // rung_0: C' = 31,250 B ⇒ vbv = 4×31,250×8 = 1,000,000.
        XCTAssertEqual(
            cappedCqPolicy().note(frameByteCeiling: 28_124, now: 0)?
                .vbvBits,
            1_000_000
        )
        // rung_1 (engage at 4.18 Mbps): C' = 15,625 B ⇒ 2×15,625×8 =
        // 250,000.
        XCTAssertEqual(
            cappedCqPolicy().note(
                frameByteCeiling: Self.ceilingAt5M, now: 0
            )?.vbvBits,
            250_000
        )
        // rung_2 (engage at 1.92 Mbps, ceiling 6,000 B): C' = 7,812 B
        // ⇒ 1×7,812×8 = 62,496.
        XCTAssertEqual(
            cappedCqPolicy().note(frameByteCeiling: 6_000, now: 0)?
                .vbvBits,
            62_496
        )
    }

    func testFloorCeilingNeverGoesDegenerate() {
        // The estimator clamps its ceiling at one shard (1,152 B even
        // at the 500 kbps floor → 368,640 bps, rung_4 = 625 kbps) —
        // the mapped posture must stay strictly positive.
        let policy = cbrPolicy()
        let directive = policy.note(frameByteCeiling: 1_152, now: 0)
        XCTAssertEqual(directive?.maxBitsPerSecond, 625_000)
        XCTAssertEqual(directive?.averageBitsPerSecond, 625_000)
        XCTAssertEqual(directive?.vbvBits, 15_624)
        XCTAssertEqual(directive?.kind, .tighten)
    }

    // MARK: - HS-27 headline: the hunt is absorbed

    func testSawToothHuntPaysZeroEncoderTouches() {
        // THE SLICE'S HEADLINE PIN. The 932a4c3 red: the estimator
        // saw-tooths (falls to ~0.85× delivery, climbs ≤10%/s) and the
        // old exact-tracking policy paid an IDR per material move — 31
        // reconfigure IDRs in 150 s. Now: the posture parks on the
        // hunt's covering rung and every subsequent move inside (or
        // briefly above) the band is ABSORBED — rate deltas through
        // the new path emit NO directive, hence no reset and no IDR.
        let policy = cappedCqPolicy()
        // Engage: ceiling 6,000 B (1.92 Mbps → rung_2 = 2.5 Mbps).
        XCTAssertNotNil(policy.note(frameByteCeiling: 6_000, now: 0))
        XCTAssertEqual(policy.directivesIssued, 1)

        // Ten hunt cycles of ~8 s: fall inside the band, climb to just
        // above the rung, fall again before any 10 s sustain can pass.
        var now = Self.sec
        for _ in 0..<10 {
            // The fall (in-band move: 4,500 B → 1.44 Mbps).
            XCTAssertNil(policy.note(frameByteCeiling: 4_500, now: now))
            now &+= 3 * Self.sec
            // The climb tops out ABOVE the rung (9,000 B → 2.88 Mbps —
            // wants looser)…
            XCTAssertNil(policy.note(frameByteCeiling: 9_000, now: now))
            now &+= 5 * Self.sec
            // …but the next fall arrives inside the sustain window,
            // resetting the clock every cycle.
        }
        XCTAssertEqual(policy.directivesIssued, 1,
            "the whole hunt must ride on the engage directive alone")
        XCTAssertTrue(policy.squeezeEngaged)
        XCTAssertEqual(policy.appliedRungIndex, 2)
        // Every polled move was carried by the pacer alone — the books
        // must say so.
        XCTAssertEqual(policy.rateMovesAbsorbed, 20)
    }

    func testAbsorbedMovesAreCountedOnlyWhenTheCeilingMoves() {
        // The counter is a rate-move book, not a poll book: repeats of
        // the same ceiling count nothing; the first poll has no
        // predecessor to move from.
        let policy = cappedCqPolicy()
        XCTAssertNil(policy.note(frameByteCeiling: Self.ceilingAt20M, now: 0))
        XCTAssertEqual(policy.rateMovesAbsorbed, 0)
        XCTAssertNil(policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: 16 * Self.ms
        ))
        XCTAssertEqual(policy.rateMovesAbsorbed, 0)
        XCTAssertNil(policy.note(
            frameByteCeiling: 50_000, now: 32 * Self.ms
        ))
        XCTAssertNil(policy.note(
            frameByteCeiling: 45_000, now: 48 * Self.ms
        ))
        XCTAssertEqual(policy.rateMovesAbsorbed, 2)
        XCTAssertEqual(policy.directivesIssued, 0)
    }

    // MARK: - Hysteresis

    func testBoundaryDitherParksButRealFallsTighten() {
        // Applied rung_1 (5 Mbps band: 2.5–5 Mbps). A dither just
        // under the lower boundary (2.4 Mbps — within the 10% margin)
        // parks; a fall materially inside the next band fires at once.
        let policy = cappedCqPolicy()
        XCTAssertNotNil(policy.note(
            frameByteCeiling: Self.ceilingAt5M, now: 0
        ))
        XCTAssertEqual(policy.appliedRungIndex, 1)
        // 7,500 B → 2.4 Mbps; ×1.1 = 2.64 Mbps still needs rung_1.
        XCTAssertNil(policy.note(
            frameByteCeiling: 7_500, now: 16 * Self.ms
        ))
        XCTAssertEqual(policy.appliedRungIndex, 1)
        // 6,875 B → 2.2 Mbps; ×1.1 = 2.42 Mbps needs rung_2: fires.
        let deeper = policy.note(
            frameByteCeiling: 6_875, now: 32 * Self.ms
        )
        XCTAssertEqual(deeper?.kind, .tighten)
        XCTAssertEqual(deeper?.maxBitsPerSecond, 2_500_000)
        XCTAssertEqual(policy.appliedRungIndex, 2)
    }

    func testDeepFallTightensImmediatelyThroughAnyHold() {
        // HS-20's protection survives the ladder: a deep fall fires
        // with NO wait of any kind — 10 ms after the last apply, all
        // the way to its covering rung (the fall side is B2's).
        let policy = cappedCqPolicy()
        XCTAssertNotNil(policy.note(frameByteCeiling: 6_000, now: 0))
        let deep = policy.note(
            frameByteCeiling: 1_000, now: 10 * Self.ms
        )
        XCTAssertEqual(deep, EncoderRateDirective(
            averageBitsPerSecond: nil,
            maxBitsPerSecond: 625_000,
            vbvBits: 15_624,
            frameByteCeiling: 1_000,
            kind: .tighten
        ))
        XCTAssertEqual(policy.directivesIssued, 2)
    }

    // MARK: - The sustained loosening

    func testLooseningWaitsTheSustainAndJumpsToTheHeldRung() {
        // Engaged deep (rung_4 via the one-shard floor ceiling). The
        // ceiling recovers to 1.6 Mbps and HOLDS: no loosening until
        // the want has been continuous for the 10 s sustain, then ONE
        // jump to the held level's rung (rung_2 = 2.5 Mbps) — not to
        // the freshest optimism, not one rung at a time.
        let policy = cappedCqPolicy()
        XCTAssertNotNil(policy.note(frameByteCeiling: 1_152, now: 0))
        XCTAssertEqual(policy.appliedRungIndex, 4)

        // 5,000 B → 1.6 Mbps, wants rung_2. The want clock starts at
        // the FIRST wanting poll (t = 1 s).
        XCTAssertNil(policy.note(frameByteCeiling: 5_000, now: Self.sec))
        XCTAssertNil(policy.note(
            frameByteCeiling: 5_000, now: 6 * Self.sec
        ))
        XCTAssertNil(policy.note(
            frameByteCeiling: 5_000, now: 10 * Self.sec + 900 * Self.ms
        ))
        let rung = policy.note(
            frameByteCeiling: 5_000, now: 11 * Self.sec + 100 * Self.ms
        )
        XCTAssertEqual(rung, EncoderRateDirective(
            averageBitsPerSecond: nil,
            maxBitsPerSecond: 2_500_000,
            vbvBits: 62_496,
            frameByteCeiling: 5_000,
            kind: .loosen
        ))
        XCTAssertEqual(policy.appliedRungIndex, 2)
        XCTAssertTrue(policy.squeezeEngaged)
    }

    func testRecurringFallsResetTheSustainClock() {
        // The hunt-parking mechanism itself: 8 s of want, one fall back
        // into the band, 8 s of want again — the clock restarts at the
        // interruption and no loosening ever fires.
        let policy = cappedCqPolicy()
        XCTAssertNotNil(policy.note(frameByteCeiling: 6_000, now: 0))
        XCTAssertNil(policy.note(frameByteCeiling: 9_000, now: 1 * Self.sec))
        XCTAssertNil(policy.note(frameByteCeiling: 9_000, now: 8 * Self.sec))
        // The fall: back inside rung_2's band — want broken.
        XCTAssertNil(policy.note(frameByteCeiling: 4_500, now: 9 * Self.sec))
        XCTAssertNil(policy.note(frameByteCeiling: 9_000, now: 10 * Self.sec))
        XCTAssertNil(policy.note(frameByteCeiling: 9_000, now: 17 * Self.sec))
        XCTAssertEqual(policy.directivesIssued, 1)
        XCTAssertEqual(policy.appliedRungIndex, 2)
    }

    func testMixedSustainTargetsTheMinimumHeldLevel() {
        // A want window that visits 5.6 Mbps but also 1.6 Mbps jumps
        // to the rung of the MINIMUM (rung_2), never the peak — the
        // wire only proved the level it held throughout.
        let policy = cappedCqPolicy()
        XCTAssertNotNil(policy.note(frameByteCeiling: 1_152, now: 0))
        XCTAssertNil(policy.note(frameByteCeiling: 17_500, now: Self.sec))
        XCTAssertNil(policy.note(frameByteCeiling: 5_000, now: 5 * Self.sec))
        XCTAssertNil(policy.note(
            frameByteCeiling: 17_500, now: 10 * Self.sec
        ))
        let rung = policy.note(
            frameByteCeiling: 17_500, now: 11 * Self.sec + 100 * Self.ms
        )
        XCTAssertEqual(rung?.kind, .loosen)
        XCTAssertEqual(rung?.maxBitsPerSecond, 2_500_000)
        XCTAssertEqual(policy.appliedRungIndex, 2)
    }

    // MARK: - Recovery

    func testSustainedCleanRestoresExactlyToTheBaseline() {
        // Squeeze then a SUSTAINED release: the restore returns the
        // opening posture bit-for-bit (caps never leave the encoder
        // looser than its recipe), tagged .restore, and steady state
        // goes silent again.
        let policy = cbrPolicy()
        XCTAssertNotNil(policy.note(
            frameByteCeiling: Self.ceilingAt5M, now: 0
        ))
        XCTAssertTrue(policy.squeezeEngaged)
        // Clean, but the want must sustain 10 s (clock starts 1 s in).
        XCTAssertNil(policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: Self.sec
        ))
        XCTAssertNil(policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: 10 * Self.sec
        ))
        let release = policy.note(
            frameByteCeiling: Self.ceilingAt20M,
            now: 11 * Self.sec + 100 * Self.ms
        )
        XCTAssertEqual(release, EncoderRateDirective(
            averageBitsPerSecond: 10_000_000,
            maxBitsPerSecond: 10_000_000,
            vbvBits: 10_000_000 / 60,
            frameByteCeiling: Self.ceilingAt20M,
            kind: .restore
        ))
        XCTAssertFalse(policy.squeezeEngaged)
        XCTAssertNil(policy.appliedRungIndex)
        XCTAssertNil(policy.note(
            frameByteCeiling: Self.ceilingAt20M,
            now: 12 * Self.sec
        ))
    }

    func testCappedCqRestoreCarriesTheExpressibleRecipe() {
        // Capped-CQ opened with NO VBV; the wrapper cannot remove one
        // once set (rc_buffer_size > 0 only). The restore therefore
        // carries one second at the baseline cap — far above any real
        // frame, effectively the recipe.
        let policy = cappedCqPolicy()
        XCTAssertNotNil(policy.note(
            frameByteCeiling: Self.ceilingAt5M, now: 0
        ))
        XCTAssertNil(policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: Self.sec
        ))
        XCTAssertNil(policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: 10 * Self.sec
        ))
        let restore = policy.note(
            frameByteCeiling: Self.ceilingAt20M,
            now: 11 * Self.sec + 100 * Self.ms
        )
        XCTAssertEqual(restore, EncoderRateDirective(
            averageBitsPerSecond: nil,
            maxBitsPerSecond: 10_000_000,
            vbvBits: 10_000_000,
            frameByteCeiling: Self.ceilingAt20M,
            kind: .restore
        ))
        XCTAssertFalse(policy.squeezeEngaged)
        XCTAssertEqual(policy.directivesIssued, 2)
    }

    // MARK: - HS-33: the no-reset retune (half-rungs, short sustain)
    // and the reconfigure-cost books

    func testHalfRungLadderRatesPinned() {
        // rungsPerOctave = 2 (the shell's posture under the vendored
        // no-reset libavcodec): whole octaves stay the exact integer
        // halvings, half-rungs are rung/√2 rounded — posture/pacer
        // slack drops from 2× to ≤√2. Only 1 and 2 are defined.
        let policy = EncoderVbvPolicy(config: EncoderVbvConfig(
            fps: 60,
            baselineMaxBitsPerSecond: 50_000_000,
            rungsPerOctave: 2
        ))
        XCTAssertEqual(policy.rungRate(atIndex: 0), 50_000_000)
        XCTAssertEqual(policy.rungRate(atIndex: 1), 35_355_339)
        XCTAssertEqual(policy.rungRate(atIndex: 2), 25_000_000)
        XCTAssertEqual(policy.rungRate(atIndex: 3), 17_677_670)
        XCTAssertEqual(policy.rungRate(atIndex: 4), 12_500_000)
        // Round UP: the smallest rung that still covers the rate.
        XCTAssertEqual(policy.rungIndex(for: 40_000_000), 0)
        XCTAssertEqual(policy.rungIndex(for: 35_355_339), 1)
        XCTAssertEqual(policy.rungIndex(for: 30_000_000), 1)
        XCTAssertEqual(policy.rungIndex(for: 25_000_000), 2)
        XCTAssertEqual(policy.rungIndex(for: 20_000_000), 2)
        XCTAssertEqual(policy.rungIndex(for: 17_677_670), 3)
    }

    func testHalfRungTightenLandsOnTheCoveringHalfLadder() {
        // The 4.18 Mbps fall under a 10 Mbps recipe: the half-rung
        // ladder's covering rung is index 2 = 5 Mbps (index 3 =
        // 3,535,534 sits below the wire — never chosen). The mapping
        // at the rung is unchanged HS-20/HS-22 math.
        let policy = EncoderVbvPolicy(config: EncoderVbvConfig(
            fps: 60,
            baselineMaxBitsPerSecond: 10_000_000,
            rungsPerOctave: 2
        ))
        XCTAssertEqual(policy.rungRate(atIndex: 1), 7_071_068)
        let directive = policy.note(
            frameByteCeiling: Self.ceilingAt5M, now: 0
        )
        XCTAssertEqual(directive?.kind, .tighten)
        XCTAssertEqual(directive?.maxBitsPerSecond, 5_000_000)
        XCTAssertEqual(directive?.vbvBits, 250_000)
        XCTAssertEqual(policy.appliedRungIndex, 2)
    }

    func testSustainKnobScalesTheLooseningWait() {
        // riseSustainNS is config, not law — the mechanics must scale
        // with it: want from t=1 s, no loosen at 2.9 s, the jump to
        // the held minimum's rung at 3.2 s under a 2 s sustain. (The
        // SHELL ships 10 s even under no-reset: a live 2 s sustain
        // chased every climb into a queuing-delay floor limit cycle —
        // the HS-33 armed A/B; this pin is the knob's contract, not a
        // shipped value.)
        let policy = EncoderVbvPolicy(config: EncoderVbvConfig(
            fps: 60,
            baselineMaxBitsPerSecond: 10_000_000,
            riseSustainNS: 2 * Self.sec
        ))
        XCTAssertNotNil(policy.note(frameByteCeiling: 1_152, now: 0))
        XCTAssertEqual(policy.appliedRungIndex, 4)
        XCTAssertNil(policy.note(frameByteCeiling: 5_000, now: Self.sec))
        XCTAssertNil(policy.note(
            frameByteCeiling: 5_000, now: 2 * Self.sec + 900 * Self.ms
        ))
        let rung = policy.note(
            frameByteCeiling: 5_000, now: 3 * Self.sec + 200 * Self.ms
        )
        XCTAssertEqual(rung?.kind, .loosen)
        XCTAssertEqual(rung?.maxBitsPerSecond, 2_500_000)
    }

    func testReconfigureBooksSplitIdrMintingFromNoReset() {
        // THE HS-33 BOOKS PIN. A rate directive that applies with the
        // reconfigure counted but ZERO IDR minted lands in `noReset`,
        // never in the IDR-minting tally — the idr-books cause tags
        // stay truthful under either libavcodec, decided by the
        // observed outcome of the encode the directive rode into.
        var books = EncoderReconfigureBooks()
        books.note(.tighten, mintedIdr: false)
        XCTAssertEqual(books.applied, 1)
        XCTAssertEqual(books.noResetTotal, 1)
        XCTAssertEqual(books.idrMintingTotal, 0,
            "a no-IDR rate move must never read as an IDR cause")

        // The distro path: the same directive kind, observed to reset.
        books.note(.tighten, mintedIdr: true)
        books.note(.loosen, mintedIdr: false)
        books.note(.restore, mintedIdr: false)
        XCTAssertEqual(books.applied, 4)
        XCTAssertEqual(books.idrMintingTotal, 1)
        XCTAssertEqual(books.noResetTotal, 3)
        // The stats-line vocabulary matches the idr-books tags.
        XCTAssertEqual(
            EncoderReconfigureBooks.summary(books.noReset),
            "tighten 1, rung 1, restore 1"
        )
        XCTAssertEqual(
            EncoderReconfigureBooks.summary(books.idrMinting),
            "tighten 1"
        )
        XCTAssertEqual(EncoderReconfigureBooks.summary([:]), "none")
    }

    func testDefaultLadderIsUnchangedByTheRetuneKnob() {
        // The HS-27 pins ride verbatim under the distro posture: the
        // default config is rungsPerOctave 1 / sustain 10 s, and the
        // knob's integer-halving path is byte-for-byte the old math.
        let policy = cappedCqPolicy()
        XCTAssertEqual(policy.config.rungsPerOctave, 1)
        XCTAssertEqual(policy.config.riseSustainNS, 10 * Self.sec)
        XCTAssertEqual(policy.rungRate(atIndex: 3), 1_250_000)
        XCTAssertEqual(policy.rungIndex(for: 1_250_000), 3)
    }

    func testACleanBlipInsideTheSustainDoesNotRestore() {
        // One clean report inside a hunt must not pop the recipe back:
        // the restore needs the whole sustain window clean-or-wanting,
        // and the MINIMUM rule keeps a mixed window on the ladder (the
        // mixed-sustain leg above); a broken want resets outright.
        let policy = cappedCqPolicy()
        XCTAssertNotNil(policy.note(frameByteCeiling: 6_000, now: 0))
        XCTAssertNil(policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: Self.sec
        ))
        // The fall arrives 3 s later — clock dead, no restore ever ran.
        XCTAssertNil(policy.note(frameByteCeiling: 4_500, now: 4 * Self.sec))
        XCTAssertTrue(policy.squeezeEngaged)
        XCTAssertEqual(policy.directivesIssued, 1)
    }

    // MARK: - HS-33's second harvest: exact tighten (no-reset gate only)

    /// The no-reset shell's full posture: half-rung ladder AND exact
    /// tightens (both flags follow the same proven-capability gate).
    private func exactPolicy() -> EncoderVbvPolicy {
        EncoderVbvPolicy(config: EncoderVbvConfig(
            fps: 60,
            baselineAverageBitsPerSecond: 10_000_000,
            baselineMaxBitsPerSecond: 10_000_000,
            baselineVbvBits: 10_000_000 / 60,
            rungsPerOctave: 2,
            exactTighten: true
        ))
    }

    func testExactTightenLandsOnTheCeilingRateNotTheRungAbove() {
        // 12,500 B at 60 fps ⇒ exactly 4 Mbps. The half-rung ladder
        // would park the posture at the covering 5 Mbps rung (√2-ish
        // slack above the wire); exact mode lands on 4 Mbps to the bit.
        let directive = exactPolicy().note(frameByteCeiling: 12_500, now: 0)
        XCTAssertEqual(directive?.kind, .tighten)
        XCTAssertEqual(directive?.maxBitsPerSecond, 4_000_000)
        XCTAssertEqual(directive?.averageBitsPerSecond, 4_000_000)
        // The HS-22 window mapping rides the exact rate: 40% squeeze ⇒
        // 1 budget window of 12,500 B ⇒ 100,000 bits.
        XCTAssertEqual(directive?.vbvBits, 100_000)
    }

    func testExactTightenStillParksInsideTheDeadband() {
        let policy = exactPolicy()
        _ = policy.note(frameByteCeiling: 12_500, now: 0) // 4.0 Mbps
        // −4%: margined (×1.1) still clears the applied max — dither
        // parks exactly as the ladder always did.
        XCTAssertNil(policy.note(frameByteCeiling: 12_000, now: Self.ms))
        XCTAssertEqual(policy.directivesIssued, 1)
    }

    func testExactTightenRetunesTheMaterialWithinBandFall() {
        let policy = exactPolicy()
        _ = policy.note(frameByteCeiling: 12_500, now: 0) // 4.0 Mbps
        // 10,937 B ⇒ 3,499,840 b/s: −12.5%, materially below the
        // applied max but INSIDE the covering half-rung's band — the
        // ladder absorbs this shape (control pin below); exact mode
        // retunes onto the fallen rate.
        let fall = policy.note(frameByteCeiling: 10_937, now: 2 * Self.ms)
        XCTAssertEqual(fall?.kind, .tighten)
        XCTAssertEqual(fall?.maxBitsPerSecond, 3_499_840)
        XCTAssertEqual(policy.directivesIssued, 2)
    }

    func testLadderModeStillAbsorbsTheWithinBandFall() {
        // The control: same fall shape, exactTighten off — the HS-27
        // parking contract stands verbatim for the distro-lib posture.
        let policy = EncoderVbvPolicy(config: EncoderVbvConfig(
            fps: 60,
            baselineAverageBitsPerSecond: 10_000_000,
            baselineMaxBitsPerSecond: 10_000_000,
            baselineVbvBits: 10_000_000 / 60,
            rungsPerOctave: 2
        ))
        _ = policy.note(frameByteCeiling: 12_500, now: 0)
        XCTAssertNil(policy.note(frameByteCeiling: 10_937, now: 2 * Self.ms),
                     "the ladder parks within the band")
        XCTAssertEqual(policy.directivesIssued, 1)
        XCTAssertEqual(policy.rateMovesAbsorbed, 1)
    }

    func testExactTightenLeavesTheSustainedRestoreUntouched() {
        // The loosening half is deliberately NOT exact: sustain-gated,
        // held-minimum, restore-to-baseline — the 10 s climb-lag is
        // load-bearing (2026-07-29 A/B). A clean ceiling after an
        // exact tighten restores the opening recipe bit-for-bit, and
        // only after the sustain.
        let policy = exactPolicy()
        _ = policy.note(frameByteCeiling: 10_937, now: 0)
        XCTAssertNil(policy.note(frameByteCeiling: 31_250, now: Self.sec),
                     "clean want must still wait out the sustain")
        XCTAssertNil(policy.note(frameByteCeiling: 31_250, now: 9 * Self.sec))
        let restore = policy.note(
            frameByteCeiling: 31_250, now: 11 * Self.sec
        )
        XCTAssertEqual(restore?.kind, .restore)
        XCTAssertEqual(restore?.maxBitsPerSecond, 10_000_000)
        XCTAssertEqual(restore?.averageBitsPerSecond, 10_000_000)
        XCTAssertEqual(restore?.vbvBits, 10_000_000 / 60)
        XCTAssertFalse(policy.squeezeEngaged)
    }
}
