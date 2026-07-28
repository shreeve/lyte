import XCTest
import HostCore
import HostWire
import LyteWire

// THE GATE (H3 plan Wave 0, D-1 — HS-20; clean-path rule + multi-window
// VBV — HS-22). Pinned behaviors, each a leg below:
//
//   • THE CLEAN PATH (HS-22) — while the ceiling-derived rate (8×C/B)
//     sits at or above (1 − deadband) × the opening recipe's cap, the
//     policy is SILENT: zero directives, no first-look imposition, the
//     opening recipe rides. (Every directive is a known encoder reset +
//     forced IDR through the FFmpeg wrapper — a withheld directive is
//     an avoided quality pulse.) The threshold is the policy's own
//     deadband: an engage is a ≥10% move by construction;
//   • MAPPING under a squeeze — the ceiling C derives the encoder
//     posture exactly: rate = 8×C/B (the VBV refills one ceiling per
//     HS-6 budget window) and vbv = k × 8×C bits, where k walks the
//     HS-22 ladder toward the squeeze (≥80% of the recipe rate ⇒ 4
//     windows, ≥65% ⇒ 3, ≥50% ⇒ 2, deeper ⇒ 1 — HS-20's single-frame
//     tool, byte-identical where B2 was retired), all CAPS against the
//     opening posture, never pushes above it;
//   • a CBR encoder already stricter than the wire stays untouched at
//     the session ceiling (zero directives — no thrash at steady
//     state);
//   • HYSTERESIS — a 10% deadband holds small moves; a tightening past
//     it applies immediately (the oversized-frame harm this rung
//     exists to stop); a loosening additionally waits out the 500 ms
//     rise hold;
//   • recovery returns exactly to the baseline posture and then goes
//     silent — the policy can never leave the encoder tighter (or
//     looser) than its opening recipe once the squeeze lifts. For
//     capped-CQ (whose "no VBV" is inexpressible on the way back —
//     the wrapper only reads rc_buffer_size > 0) the restore carries
//     one second at the baseline cap, effectively the recipe.

final class EncoderVbvGateTests: XCTestCase {

    private static let ms: UInt64 = 1_000_000

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
        // THE HS-22 HEADLINE. HS-20 imposed vbv = 8×C on capped-CQ at
        // the very first look, clean path or not — a squeeze tool as
        // steady-state posture, quantizing every IDR down to the
        // ceiling on a wire with headroom (the owner's "moderate
        // quality" regression). Now: the wire outruns the recipe ⇒
        // ZERO directives, ever — the opening recipe (no VBV, CQ
        // quality) rides the whole session.
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
        // the line: clean, silent. One byte below: a genuine squeeze —
        // the first look imposes the mapping immediately (a WAKE-arm
        // tightening never waits).
        let atLine = cappedCqPolicy()
        XCTAssertEqual(atLine.cleanPathRateBitsPerSecond, 9_000_000)
        XCTAssertNil(atLine.note(frameByteCeiling: 28_125, now: 0))
        XCTAssertFalse(atLine.squeezeEngaged)

        let below = cappedCqPolicy()
        let directive = below.note(frameByteCeiling: 28_124, now: 0)
        XCTAssertEqual(directive, EncoderRateDirective(
            averageBitsPerSecond: nil,
            maxBitsPerSecond: 8_999_680,
            vbvBits: 4 * 28_124 * 8,
            frameByteCeiling: 28_124
        ))
        XCTAssertTrue(below.squeezeEngaged)
    }

    // MARK: - The mapping under a squeeze

    func testRateDropMapsExactlyOntoTheEncoder() {
        // The estimator falls to 5 Mbps (ceiling 13,062 B). The
        // directive must carry the exact HS-6 inversion: rate =
        // 8×13,062 / 25 ms = 4,180 kbps (avg AND max in CBR — the
        // mode's min = avg = max contract), vbv = 8×13,062 bits.
        let policy = cbrPolicy()
        let directive = policy.note(
            frameByteCeiling: Self.ceilingAt5M, now: 1_000 * Self.ms
        )
        XCTAssertEqual(directive, EncoderRateDirective(
            averageBitsPerSecond: 4_179_840,
            maxBitsPerSecond: 4_179_840,
            vbvBits: Self.ceilingAt5M * 8,
            frameByteCeiling: Self.ceilingAt5M
        ))
    }

    func testFloorCeilingNeverGoesDegenerate() {
        // The estimator clamps its ceiling at one shard (1,152 B even
        // at the 500 kbps floor) — the mapped posture must stay
        // strictly positive, never zero or negative.
        let policy = cbrPolicy()
        let directive = policy.note(frameByteCeiling: 1_152, now: 0)
        XCTAssertEqual(directive?.maxBitsPerSecond, 368_640)
        XCTAssertEqual(directive?.vbvBits, 9_216)
        XCTAssertEqual(directive?.averageBitsPerSecond, 368_640)
    }

    func testVbvWindowLadderScalesTowardTheSqueeze() {
        // HS-22: a mild squeeze holds the AVERAGE and lets a frame
        // borrow adjacent budget windows; the deep tool stays k = 1.
        // Fresh policy per depth — each leg pins one rung exactly.
        // ~85% of the recipe rate (ceiling 26,563 B → 8.50 Mbps): k=4.
        XCTAssertEqual(
            cappedCqPolicy().note(frameByteCeiling: 26_563, now: 0),
            EncoderRateDirective(
                averageBitsPerSecond: nil,
                maxBitsPerSecond: 8_500_160,
                vbvBits: 4 * 26_563 * 8,
                frameByteCeiling: 26_563
            )
        )
        // ~70% (ceiling 22,000 B → 7.04 Mbps): k=3.
        XCTAssertEqual(
            cappedCqPolicy().note(frameByteCeiling: 22_000, now: 0),
            EncoderRateDirective(
                averageBitsPerSecond: nil,
                maxBitsPerSecond: 7_040_000,
                vbvBits: 3 * 22_000 * 8,
                frameByteCeiling: 22_000
            )
        )
        // ~54% (ceiling 17,000 B → 5.44 Mbps): k=2.
        XCTAssertEqual(
            cappedCqPolicy().note(frameByteCeiling: 17_000, now: 0),
            EncoderRateDirective(
                averageBitsPerSecond: nil,
                maxBitsPerSecond: 5_440_000,
                vbvBits: 2 * 17_000 * 8,
                frameByteCeiling: 17_000
            )
        )
        // Below 50% (the HS-6 5 Mbps ceiling → 4.18 Mbps, 41.8%): k=1
        // — HS-20's single-frame conformance tool, byte-identical to
        // the posture that retired B2.
        XCTAssertEqual(
            cappedCqPolicy().note(
                frameByteCeiling: Self.ceilingAt5M, now: 0
            ),
            EncoderRateDirective(
                averageBitsPerSecond: nil,
                maxBitsPerSecond: 4_179_840,
                vbvBits: Self.ceilingAt5M * 8,
                frameByteCeiling: Self.ceilingAt5M
            )
        )
    }

    // MARK: - Hysteresis (inside the squeeze band)

    func testDeadbandHoldsSmallMoves() {
        // Applied at C = 15,000 B (4.8 Mbps, k = 1 territory); a ~7%
        // wiggle sits inside the 10% deadband (nothing pushed), a ~13%
        // move fires.
        let policy = cappedCqPolicy()
        XCTAssertNotNil(policy.note(frameByteCeiling: 15_000, now: 0))
        XCTAssertNil(policy.note(
            frameByteCeiling: 13_900, now: 16 * Self.ms
        ))
        XCTAssertNotNil(policy.note(
            frameByteCeiling: 13_000, now: 32 * Self.ms
        ))
        XCTAssertEqual(policy.directivesIssued, 2)
    }

    func testFallsApplyImmediatelyRisesWaitTheHold() {
        let policy = cappedCqPolicy()
        XCTAssertNotNil(policy.note(frameByteCeiling: 15_000, now: 0))

        // A material fall 10 ms after the last apply: no interval gate
        // may hold it — an oversized frame at a squeezed pacer is the
        // exact harm (the estimator's own limiter bounds the cadence).
        XCTAssertNotNil(policy.note(
            frameByteCeiling: 7_500, now: 10 * Self.ms
        ))

        // A material rise 20 ms later: inside the 500 ms hold — held.
        XCTAssertNil(policy.note(
            frameByteCeiling: 15_000, now: 30 * Self.ms
        ))
        // Still held at 400 ms after the fall's apply…
        XCTAssertNil(policy.note(
            frameByteCeiling: 15_000, now: 410 * Self.ms
        ))
        // …and released once the hold elapses.
        let released = policy.note(
            frameByteCeiling: 15_000, now: 510 * Self.ms
        )
        XCTAssertEqual(released?.vbvBits, 15_000 * 8)
        XCTAssertEqual(policy.directivesIssued, 3)
    }

    // MARK: - Recovery

    func testRecoveryReturnsExactlyToTheBaseline() {
        // Squeeze then release: the release directive must restore the
        // opening posture bit-for-bit (caps never leave the encoder
        // looser than its recipe), and steady state goes silent again.
        let policy = cbrPolicy()
        XCTAssertNotNil(policy.note(
            frameByteCeiling: Self.ceilingAt5M, now: 0
        ))
        XCTAssertTrue(policy.squeezeEngaged)
        let release = policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: 600 * Self.ms
        )
        XCTAssertEqual(release, EncoderRateDirective(
            averageBitsPerSecond: 10_000_000,
            maxBitsPerSecond: 10_000_000,
            vbvBits: 10_000_000 / 60,
            frameByteCeiling: Self.ceilingAt20M
        ))
        XCTAssertFalse(policy.squeezeEngaged)
        XCTAssertNil(policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: 700 * Self.ms
        ))
    }

    func testCappedCqRestoreCarriesTheExpressibleRecipe() {
        // Capped-CQ opened with NO VBV; the wrapper cannot remove one
        // once set (rc_buffer_size > 0 only). The restore therefore
        // carries one second at the baseline cap — far above any real
        // frame, effectively the recipe — waits out the rise hold like
        // any loosening, and then the policy goes silent again.
        let policy = cappedCqPolicy()
        XCTAssertNotNil(policy.note(
            frameByteCeiling: Self.ceilingAt5M, now: 0
        ))
        // Clean again, but inside the 500 ms hold: held.
        XCTAssertNil(policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: 300 * Self.ms
        ))
        XCTAssertTrue(policy.squeezeEngaged)
        // Past the hold: the one restore.
        let restore = policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: 600 * Self.ms
        )
        XCTAssertEqual(restore, EncoderRateDirective(
            averageBitsPerSecond: nil,
            maxBitsPerSecond: 10_000_000,
            vbvBits: 10_000_000,
            frameByteCeiling: Self.ceilingAt20M
        ))
        XCTAssertFalse(policy.squeezeEngaged)
        XCTAssertNil(policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: 700 * Self.ms
        ))
        XCTAssertEqual(policy.directivesIssued, 2)
    }
}
