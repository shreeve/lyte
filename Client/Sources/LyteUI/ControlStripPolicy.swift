// The control strip's reveal policy: which edge it lives on, whether it
// exists at all, and when it reveals — sans-IO so the feel is
// virtual-time testable and the app view is just a driver.
//
// - Reveal is earned by dwell, not transit: the pointer must stay in a
//   zone hugging the strip's edge for ~200 ms, so a flick toward the
//   Dock never trips it. A pointer passing through reveals nothing.
// - In fullscreen the last few points at the screen edge belong to the
//   system (Dock and menu-bar summons): they never arm the dwell, and a
//   push into them hides a visible strip. Windowed, the sliver is off.
// - Leaving the window hides the strip instantly.
// - Once revealed, the strip fades ~2 s after the last activity in the
//   zone, never while hovered; hover exit restamps.
// - Hidden mode makes the policy inert: nothing reveals, every deadline
//   is nil.

import Foundation

/// Which window edge the strip (and its reveal zone) hugs.
public enum StripEdge: String, CaseIterable, Sendable {
    case bottom
    case top
}

/// The strip preferences' app-wide UserDefaults keys, bound by the views'
/// @AppStorage (which falls back to its default on an unknown raw value).
public enum StripPreferences {
    public static let edgeKey = "controlStripEdge"
    public static let hiddenKey = "controlStripHidden"
}

/// The reveal/fade state machine. Sans-IO: time is nanoseconds handed
/// in by the caller, geometry is a distance-from-edge the view layer
/// computes against the CONFIGURED edge. The driver feeds pointer
/// events, asks `nextDeadline` for when to wake, and calls `tick` on
/// waking; `isVisible` is the one output.
public struct StripRevealPolicy: Sendable {
    /// Continuous zone presence required before the strip reveals.
    static let dwellNanoseconds: UInt64 = 200_000_000
    /// Idle time after the last zone activity before the fade.
    static let idleFadeNanoseconds: UInt64 = 2_000_000_000
    /// The reveal zone's depth from the configured edge — covers the
    /// strip itself plus a comfortable approach.
    static let zoneThicknessPoints = 90.0
    /// The system's sliver at a SCREEN edge (fullscreen only): pointer
    /// presence here is a Dock/menu-bar summon, never a strip dwell.
    static let systemEdgeSliverPoints = 6.0

    /// The one output: whether the strip is on screen.
    public private(set) var isVisible = false
    /// Hidden mode (the preference): the policy goes inert — nothing
    /// reveals, and flipping it on takes a visible strip down.
    public var hiddenMode = false {
        didSet { if hiddenMode { forceHide() } }
    }

    /// When the pointer's current uninterrupted zone visit began; nil
    /// when the pointer is not known to be in the zone.
    private var dwellStart: UInt64?
    /// The fade anchor: last pointer activity in the zone (or hover
    /// exit) while visible.
    private var lastZoneActivity: UInt64 = 0
    private var hovered = false

    public init() {}

    /// A pointer event inside the window. `edgeDistance` is measured
    /// from the CONFIGURED edge; `atSystemEdge` says that edge is a
    /// real screen edge right now (fullscreen), arming the sliver rule.
    public mutating func pointerMoved(
        edgeDistance: Double, atSystemEdge: Bool, now: UInt64
    ) {
        guard !hiddenMode else { return }
        if atSystemEdge, edgeDistance < Self.systemEdgeSliverPoints {
            // The system's pixels: a push here summons the Dock or the
            // menu bar. Never a dwell — and the strip yields the spot.
            dwellStart = nil
            forceHide()
            return
        }
        guard edgeDistance < Self.zoneThicknessPoints else {
            dwellStart = nil    // transit ended outside — dwell over
            return
        }
        if isVisible {
            lastZoneActivity = now
            return
        }
        let started = dwellStart ?? now
        dwellStart = started
        if now &- started >= Self.dwellNanoseconds {
            reveal(now: now)
        }
    }

    /// The pointer left the window bounds: the strip hides now.
    public mutating func pointerExitedWindow() {
        dwellStart = nil
        hovered = false
        forceHide()
    }

    /// Hover on the strip itself pins visibility; exit restamps so the
    /// fade lands a full idle interval later.
    public mutating func hoverChanged(_ hovering: Bool, now: UInt64) {
        guard !hiddenMode else { return }
        hovered = hovering
        if !hovering, isVisible { lastZoneActivity = now }
    }

    /// Keeps a visible strip up after its own buttons act (the edge
    /// toggle teleports it away from the pointer).
    public mutating func keepAlive(now: UInt64) {
        guard isVisible else { return }
        lastZoneActivity = now
    }

    /// Deadline work: completes a dwell whose pointer went stationary
    /// in the zone, and runs the idle fade.
    public mutating func tick(now: UInt64) {
        guard !hiddenMode else { return }
        if !isVisible, let started = dwellStart,
           now &- started >= Self.dwellNanoseconds {
            reveal(now: now)
            return
        }
        if isVisible, !hovered,
           now &- lastZoneActivity >= Self.idleFadeNanoseconds {
            forceHide()
        }
    }

    /// When the driver should call `tick` next; nil means nothing is
    /// pending (hover pins, hidden mode, or simply nothing to do —
    /// the next pointer event re-arms).
    public var nextDeadline: UInt64? {
        guard !hiddenMode else { return nil }
        if !isVisible {
            return dwellStart.map { $0 &+ Self.dwellNanoseconds }
        }
        guard !hovered else { return nil }
        return lastZoneActivity &+ Self.idleFadeNanoseconds
    }

    private mutating func reveal(now: UInt64) {
        isVisible = true
        lastZoneActivity = now
        dwellStart = nil
    }

    private mutating func forceHide() {
        isVisible = false
        dwellStart = nil
    }
}
