import XCTest
import Foundation
@testable import LyteUI

// THE GATE (CL-18, the strip's ergonomics policy). Pinned behaviors,
// all in virtual time:
//
//   • TRANSIT NEVER REVEALS: a pointer crossing the edge zone on its
//     way somewhere else (the Dock) shows nothing — reveal is earned
//     by ~200 ms of continuous zone presence;
//   • DWELL REVEALS: presence in the zone for the dwell interval
//     reveals, including the stationary case (zone entry, then no
//     further events — the deadline tick completes it);
//   • the fullscreen SYSTEM-EDGE SLIVER is macOS's: presence in the
//     last few points at a real screen edge never arms the dwell, and
//     a push into it takes a visible strip DOWN (the push is the
//     Dock/menu-bar summon); windowed, the same distances arm
//     normally;
//   • leaving the WINDOW BOUNDS hides instantly and cancels any
//     pending dwell — the strip never squats where the Dock appears;
//   • the CL-16 FADE DISCIPLINE holds: visible fades ~2 s after the
//     last activity IN THE ZONE (activity out in the video no longer
//     pins it), never while hovered, hover exit restamps;
//   • HIDDEN MODE is inert: nothing reveals, every deadline is nil,
//     and flipping it on takes a visible strip down;
//   • the PREFERENCES round-trip: edge + hidden persist through
//     UserDefaults under the pinned keys, and unknown raw values fall
//     back to the defaults.

final class ControlStripPolicyGateTests: XCTestCase {

    // Virtual-time helpers: the policy speaks nanoseconds.
    private static let ms: UInt64 = 1_000_000
    private var config = StripRevealPolicy.Config()

    /// A fresh policy with the default feel numbers (200 ms dwell,
    /// 2 s fade, 90 pt zone, 6 pt sliver) — the numbers themselves are
    /// pinned here so a feel retune is a deliberate test edit.
    private func makePolicy() -> StripRevealPolicy {
        XCTAssertEqual(config.dwellNanoseconds, 200 * Self.ms,
                       "the dwell sits in the owner's 150–250 ms band")
        XCTAssertEqual(config.idleFadeNanoseconds, 2_000 * Self.ms)
        XCTAssertEqual(config.zoneThicknessPoints, 90)
        XCTAssertEqual(config.systemEdgeSliverPoints, 6)
        return StripRevealPolicy(config: config)
    }

    // MARK: Transit vs dwell

    func testTransitThroughZoneNeverReveals() {
        var policy = makePolicy()
        // A flick toward the Dock: samples cross the zone in ~80 ms
        // and leave the window — never visible at any point.
        var t: UInt64 = 1_000 * Self.ms
        for distance in stride(from: 85.0, through: 5.0, by: -20.0) {
            policy.pointerMoved(edgeDistance: distance,
                                atSystemEdge: false, now: t)
            XCTAssertFalse(policy.isVisible)
            t += 20 * Self.ms
        }
        policy.pointerExitedWindow(now: t)
        XCTAssertFalse(policy.isVisible)
        // And the exit killed the pending dwell: nothing left to wake.
        XCTAssertNil(policy.nextDeadline,
                     "a window exit cancels the pending dwell")
    }

    func testDwellRevealsAtThresholdMovingOrStationary() {
        // Moving inside the zone: presence accumulates across events.
        var moving = makePolicy()
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
        var still = makePolicy()
        t = 5_000 * Self.ms
        still.pointerMoved(edgeDistance: 30, atSystemEdge: false, now: t)
        XCTAssertEqual(still.nextDeadline, t + 200 * Self.ms)
        still.tick(now: t + 199 * Self.ms)
        XCTAssertFalse(still.isVisible)
        still.tick(now: t + 200 * Self.ms)
        XCTAssertTrue(still.isVisible)

        // Leaving the zone mid-dwell resets it: re-entry starts over.
        var restarted = makePolicy()
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
        var policy = makePolicy()
        var t: UInt64 = 1_000 * Self.ms
        policy.pointerMoved(edgeDistance: 3, atSystemEdge: true, now: t)
        XCTAssertNil(policy.nextDeadline,
                     "the sliver is the system's — no dwell")
        policy.tick(now: t + 500 * Self.ms)
        XCTAssertFalse(policy.isVisible)

        // The SAME distance windowed arms normally (the window's
        // bottom edge is not the screen's).
        var windowed = makePolicy()
        windowed.pointerMoved(edgeDistance: 3, atSystemEdge: false, now: t)
        windowed.tick(now: t + 200 * Self.ms)
        XCTAssertTrue(windowed.isVisible)

        // A visible strip yields to the summon gesture: dwell-reveal
        // in the zone proper, then a push into the sliver hides NOW.
        var yielding = makePolicy()
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
        var policy = makePolicy()
        var t: UInt64 = 1_000 * Self.ms
        policy.pointerMoved(edgeDistance: 40, atSystemEdge: false, now: t)
        t += 200 * Self.ms
        policy.tick(now: t)
        XCTAssertTrue(policy.isVisible)

        // The pointer leaves the window (the windowed-mode Dock aim,
        // below the window): the strip is gone before the Dock lands.
        policy.pointerExitedWindow(now: t + 50 * Self.ms)
        XCTAssertFalse(policy.isVisible)
        XCTAssertNil(policy.nextDeadline)
    }

    // MARK: The fade discipline

    func testFadeAnchorsToZoneActivityAndHoverPins() {
        var policy = makePolicy()
        var t: UInt64 = 1_000 * Self.ms
        policy.pointerMoved(edgeDistance: 40, atSystemEdge: false, now: t)
        t += 200 * Self.ms
        policy.tick(now: t)
        XCTAssertTrue(policy.isVisible)
        let revealedAt = t

        // Activity OUT IN THE VIDEO does not pin the strip anymore
        // (the CL-18 change: the strip gets out of the way while you
        // work) — the fade still lands 2 s after the last ZONE
        // activity.
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
        // restamps so the fade lands a full interval later (CL-16's
        // behavior, kept).
        var hovered = makePolicy()
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
        var policy = makePolicy()
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
        var live = makePolicy()
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

    // MARK: The preferences' persistence

    func testEdgeAndHiddenPreferencesPersistAndTolerateGarbage() throws {
        let suite = "cl18-strip-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Fresh domain: the shipped defaults — bottom edge, not hidden.
        XCTAssertEqual(StripPreferences.edge(from: defaults), .bottom)
        XCTAssertFalse(StripPreferences.hidden(from: defaults))

        // Round-trip both edges + the hidden flag under the pinned
        // keys (the app's @AppStorage binds these same strings).
        StripPreferences.setEdge(.top, in: defaults)
        XCTAssertEqual(StripPreferences.edge(from: defaults), .top)
        XCTAssertEqual(defaults.string(forKey: StripPreferences.edgeKey),
                       "top")
        StripPreferences.setEdge(.bottom, in: defaults)
        XCTAssertEqual(StripPreferences.edge(from: defaults), .bottom)
        StripPreferences.setHidden(true, in: defaults)
        XCTAssertTrue(StripPreferences.hidden(from: defaults))
        XCTAssertTrue(defaults.bool(forKey: StripPreferences.hiddenKey))
        StripPreferences.setHidden(false, in: defaults)
        XCTAssertFalse(StripPreferences.hidden(from: defaults))

        // Garbage in the plist (a downgrade, a hand edit) falls back
        // to the default rather than wedging the strip.
        defaults.set("sideways", forKey: StripPreferences.edgeKey)
        XCTAssertEqual(StripPreferences.edge(from: defaults), .bottom)

        print("CL-18 gate (prefs): edge + hidden round-trip under "
            + "\(StripPreferences.edgeKey)/\(StripPreferences.hiddenKey)")
    }
}
