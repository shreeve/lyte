import XCTest
import Foundation
@testable import LyteUI

/// The strip's reveal policy in virtual time: transit never reveals, a
/// ~200 ms dwell does (stationary too), the fullscreen system-edge sliver
/// is macOS's, leaving the window hides at once, the ~2 s fade counts
/// only zone activity and never runs while hovered, and hidden mode is
/// inert.
final class ControlStripPolicyGateTests: XCTestCase {

    // Virtual time: the policy speaks nanoseconds.
    private static let ms: UInt64 = 1_000_000

    // MARK: Transit vs dwell

    func testTransitThroughZoneNeverReveals() {
        var policy = StripRevealPolicy()
        // A flick toward the Dock: samples cross the zone in ~80 ms
        // and leave the window — never visible at any point.
        var t: UInt64 = 1_000 * Self.ms
        for distance in stride(from: 85.0, through: 5.0, by: -20.0) {
            policy.pointerMoved(edgeDistance: distance,
                                atSystemEdge: false, now: t)
            XCTAssertFalse(policy.isVisible)
            t += 20 * Self.ms
        }
        policy.pointerExitedWindow()
        XCTAssertFalse(policy.isVisible)
        // And the exit killed the pending dwell: nothing left to wake.
        XCTAssertNil(policy.nextDeadline,
                     "a window exit cancels the pending dwell")
    }

    func testDwellRevealsAtThresholdMovingOrStationary() {
        // Moving inside the zone: presence accumulates across events.
        var moving = StripRevealPolicy()
        var t: UInt64 = 1_000 * Self.ms
        moving.pointerMoved(edgeDistance: 60, atSystemEdge: false, now: t)
        XCTAssertFalse(moving.isVisible)
        moving.pointerMoved(edgeDistance: 40, atSystemEdge: false,
                            now: t + 199 * Self.ms)
        XCTAssertFalse(moving.isVisible, "one ms shy of the dwell")
        moving.pointerMoved(edgeDistance: 45, atSystemEdge: false,
                            now: t + 200 * Self.ms)
        XCTAssertTrue(moving.isVisible, "the dwell earns the reveal")

        // Stationary: zone entry, then silence — the deadline tick
        // completes the dwell (that is exactly what dwelling looks
        // like: no more move events).
        var still = StripRevealPolicy()
        t = 5_000 * Self.ms
        still.pointerMoved(edgeDistance: 30, atSystemEdge: false, now: t)
        XCTAssertEqual(still.nextDeadline, t + 200 * Self.ms)
        still.tick(now: t + 199 * Self.ms)
        XCTAssertFalse(still.isVisible)
        still.tick(now: t + 200 * Self.ms)
        XCTAssertTrue(still.isVisible)

        // Leaving the zone mid-dwell resets it: re-entry starts over.
        var restarted = StripRevealPolicy()
        t = 9_000 * Self.ms
        restarted.pointerMoved(edgeDistance: 30, atSystemEdge: false, now: t)
        restarted.pointerMoved(edgeDistance: 200, atSystemEdge: false,
                               now: t + 100 * Self.ms)
        XCTAssertNil(restarted.nextDeadline, "zone exit clears the dwell")
        restarted.pointerMoved(edgeDistance: 30, atSystemEdge: false,
                               now: t + 150 * Self.ms)
        restarted.tick(now: t + 300 * Self.ms)
        XCTAssertFalse(restarted.isVisible,
                       "only 150 ms since RE-entry — the visit restarts")
        restarted.tick(now: t + 350 * Self.ms)
        XCTAssertTrue(restarted.isVisible)
    }

    // MARK: The system's edge sliver (fullscreen)

    func testSystemEdgeSliverNeverArmsAndYieldsTheSpot() {
        // Fullscreen, pointer pinned into the last points at the
        // screen edge — the Dock summon: no dwell ever arms.
        var policy = StripRevealPolicy()
        var t: UInt64 = 1_000 * Self.ms
        policy.pointerMoved(edgeDistance: 3, atSystemEdge: true, now: t)
        XCTAssertNil(policy.nextDeadline,
                     "the sliver is the system's — no dwell")
        policy.tick(now: t + 500 * Self.ms)
        XCTAssertFalse(policy.isVisible)

        // The SAME distance windowed arms normally (the window's
        // bottom edge is not the screen's).
        var windowed = StripRevealPolicy()
        windowed.pointerMoved(edgeDistance: 3, atSystemEdge: false, now: t)
        windowed.tick(now: t + 200 * Self.ms)
        XCTAssertTrue(windowed.isVisible)

        // A visible strip yields to the summon gesture: dwell-reveal
        // in the zone proper, then a push into the sliver hides NOW.
        var yielding = StripRevealPolicy()
        t = 5_000 * Self.ms
        yielding.pointerMoved(edgeDistance: 40, atSystemEdge: true, now: t)
        yielding.tick(now: t + 200 * Self.ms)
        XCTAssertTrue(yielding.isVisible)
        yielding.pointerMoved(edgeDistance: 2, atSystemEdge: true,
                              now: t + 300 * Self.ms)
        XCTAssertFalse(yielding.isVisible,
                       "an edge push is the summon — the strip yields")
    }

    func testWindowExitHidesImmediately() {
        var policy = StripRevealPolicy()
        var t: UInt64 = 1_000 * Self.ms
        policy.pointerMoved(edgeDistance: 40, atSystemEdge: false, now: t)
        t += 200 * Self.ms
        policy.tick(now: t)
        XCTAssertTrue(policy.isVisible)

        // The pointer leaves the window (the windowed-mode Dock aim,
        // below the window): the strip is gone before the Dock lands.
        policy.pointerExitedWindow()
        XCTAssertFalse(policy.isVisible)
        XCTAssertNil(policy.nextDeadline)
    }

    // MARK: The fade discipline

    func testFadeAnchorsToZoneActivityAndHoverPins() {
        var policy = StripRevealPolicy()
        var t: UInt64 = 1_000 * Self.ms
        policy.pointerMoved(edgeDistance: 40, atSystemEdge: false, now: t)
        t += 200 * Self.ms
        policy.tick(now: t)
        XCTAssertTrue(policy.isVisible)
        let revealedAt = t

        // Activity out in the video does not pin the strip: the fade
        // lands 2 s after the last zone activity.
        policy.pointerMoved(edgeDistance: 400, atSystemEdge: false,
                            now: t + 500 * Self.ms)
        policy.pointerMoved(edgeDistance: 300, atSystemEdge: false,
                            now: t + 1_500 * Self.ms)
        XCTAssertEqual(policy.nextDeadline,
                       revealedAt + 2_000 * Self.ms,
                       "video activity never restamps the fade")
        policy.tick(now: revealedAt + 2_000 * Self.ms)
        XCTAssertFalse(policy.isVisible)

        // Zone activity DOES restamp; hover pins outright; hover exit
        // restamps so the fade lands a full interval later.
        var hovered = StripRevealPolicy()
        t = 9_000 * Self.ms
        hovered.pointerMoved(edgeDistance: 40, atSystemEdge: false, now: t)
        t += 200 * Self.ms
        hovered.tick(now: t)
        XCTAssertTrue(hovered.isVisible)
        hovered.pointerMoved(edgeDistance: 50, atSystemEdge: false,
                             now: t + 1_000 * Self.ms)
        XCTAssertEqual(hovered.nextDeadline, t + 3_000 * Self.ms,
                       "zone activity restamps the fade")
        hovered.hoverChanged(true, now: t + 1_500 * Self.ms)
        XCTAssertNil(hovered.nextDeadline, "hover pins — no deadline")
        hovered.tick(now: t + 60_000 * Self.ms)
        XCTAssertTrue(hovered.isVisible, "never fades under the pointer")
        hovered.hoverChanged(false, now: t + 60_000 * Self.ms)
        XCTAssertEqual(hovered.nextDeadline, t + 62_000 * Self.ms)
        hovered.tick(now: t + 62_000 * Self.ms)
        XCTAssertFalse(hovered.isVisible)
    }

    // MARK: Hidden mode

    func testHiddenModeIsInert() {
        var policy = StripRevealPolicy()
        policy.hiddenMode = true
        var t: UInt64 = 1_000 * Self.ms

        // Dwell all day: nothing reveals, no deadline ever arms.
        policy.pointerMoved(edgeDistance: 30, atSystemEdge: false, now: t)
        XCTAssertNil(policy.nextDeadline)
        t += 10_000 * Self.ms
        policy.tick(now: t)
        policy.pointerMoved(edgeDistance: 30, atSystemEdge: false, now: t)
        XCTAssertFalse(policy.isVisible)
        policy.hoverChanged(true, now: t)
        XCTAssertNil(policy.nextDeadline)

        // Flipping hidden ON takes a visible strip down.
        var live = StripRevealPolicy()
        t = 20_000 * Self.ms
        live.pointerMoved(edgeDistance: 30, atSystemEdge: false, now: t)
        live.tick(now: t + 200 * Self.ms)
        XCTAssertTrue(live.isVisible)
        live.hiddenMode = true
        XCTAssertFalse(live.isVisible)
        XCTAssertNil(live.nextDeadline)

        // And back off: nothing auto-reveals — the next dwell earns it.
        live.hiddenMode = false
        XCTAssertFalse(live.isVisible)
        XCTAssertNil(live.nextDeadline)
        live.pointerMoved(edgeDistance: 30, atSystemEdge: false,
                          now: t + 1_000 * Self.ms)
        live.tick(now: t + 1_200 * Self.ms)
        XCTAssertTrue(live.isVisible)
    }
}
