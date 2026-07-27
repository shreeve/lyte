import XCTest
import HostCore
import HostWire
import LyteWire

// THE GATE (H3 plan Wave 0, D-1 — HS-20): the encoder finally consumes
// frameByteCeiling. Pinned behaviors, each a leg below:
//
//   • MAPPING — the ceiling C derives the encoder posture exactly:
//     vbv = 8×C bits (one frame may cost at most the ceiling) and
//     rate = 8×C/B (the VBV refills one ceiling per HS-6 budget
//     window), both CAPS against the opening posture, never pushes
//     above it;
//   • a CBR encoder already stricter than the wire stays untouched at
//     the session ceiling (zero directives — no thrash at steady
//     state), while capped-CQ mode (no VBV at open) gets the ceiling
//     imposed from the very first look;
//   • HYSTERESIS — a 10% deadband holds small moves; a tightening past
//     it applies immediately (the oversized-frame harm this rung
//     exists to stop); a loosening additionally waits out the 500 ms
//     rise hold;
//   • recovery returns exactly to the baseline posture and then goes
//     silent — the policy can never leave the encoder tighter (or
//     looser) than its opening recipe once the squeeze lifts.

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

    // MARK: - Steady state

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

    func testCappedCqGetsTheCeilingImposedAtFirstLook() {
        // No VBV at open means even the first IDR is unbounded today —
        // the first look must impose the ceiling: vbv = 8×C, and the
        // cap stays the baseline's (the ceiling-derived rate 19.18 Mbps
        // sits ABOVE the 10 Mbps cap; caps never loosen).
        let policy = cappedCqPolicy()
        let directive = policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: 0
        )
        XCTAssertEqual(directive, EncoderRateDirective(
            averageBitsPerSecond: nil,
            maxBitsPerSecond: 10_000_000,
            vbvBits: Self.ceilingAt20M * 8,
            frameByteCeiling: Self.ceilingAt20M
        ))
        // And the imposition is once, not per frame.
        XCTAssertNil(policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: 16 * Self.ms
        ))
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

    // MARK: - Hysteresis

    func testDeadbandHoldsSmallMoves() {
        // Applied at C = 50,000 B; an 8% wiggle sits inside the 10%
        // deadband (nothing pushed), a 12% move fires.
        let policy = cappedCqPolicy()
        XCTAssertNotNil(policy.note(frameByteCeiling: 50_000, now: 0))
        XCTAssertNil(policy.note(
            frameByteCeiling: 46_000, now: 16 * Self.ms
        ))
        XCTAssertNotNil(policy.note(
            frameByteCeiling: 44_000, now: 32 * Self.ms
        ))
        XCTAssertEqual(policy.directivesIssued, 2)
    }

    func testFallsApplyImmediatelyRisesWaitTheHold() {
        let policy = cappedCqPolicy()
        XCTAssertNotNil(policy.note(frameByteCeiling: 50_000, now: 0))

        // A material fall 10 ms after the last apply: no interval gate
        // may hold it — an oversized frame at a squeezed pacer is the
        // exact harm (the estimator's own limiter bounds the cadence).
        XCTAssertNotNil(policy.note(
            frameByteCeiling: 25_000, now: 10 * Self.ms
        ))

        // A material rise 20 ms later: inside the 500 ms hold — held.
        XCTAssertNil(policy.note(
            frameByteCeiling: 50_000, now: 30 * Self.ms
        ))
        // Still held at 400 ms after the fall's apply…
        XCTAssertNil(policy.note(
            frameByteCeiling: 50_000, now: 410 * Self.ms
        ))
        // …and released once the hold elapses.
        let released = policy.note(
            frameByteCeiling: 50_000, now: 510 * Self.ms
        )
        XCTAssertEqual(released?.vbvBits, 50_000 * 8)
        XCTAssertEqual(policy.directivesIssued, 3)
    }

    func testRecoveryReturnsExactlyToTheBaseline() {
        // Squeeze then release: the release directive must restore the
        // opening posture bit-for-bit (caps never leave the encoder
        // looser than its recipe), and steady state goes silent again.
        let policy = cbrPolicy()
        XCTAssertNotNil(policy.note(
            frameByteCeiling: Self.ceilingAt5M, now: 0
        ))
        let release = policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: 600 * Self.ms
        )
        XCTAssertEqual(release, EncoderRateDirective(
            averageBitsPerSecond: 10_000_000,
            maxBitsPerSecond: 10_000_000,
            vbvBits: 10_000_000 / 60,
            frameByteCeiling: Self.ceilingAt20M
        ))
        XCTAssertNil(policy.note(
            frameByteCeiling: Self.ceilingAt20M, now: 700 * Self.ms
        ))
    }
}
