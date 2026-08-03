// The control strip's ergonomics brain (CL-18): which edge it lives
// on, whether it exists at all, and WHEN it reveals — extracted here as
// sans-IO policy so the feel is virtual-time testable and the app view
// is just a driver.
//
// The owner's hand-test found CL-13's video-player rule ("reveal on
// any mouse movement") hostile in fullscreen: heading for the macOS
// Dock crosses the strip's home stretch, the strip pops, and the click
// meant for the Dock lands on a strip button. The CL-18 ruling:
//
// - Reveal is earned by DWELL, not transit: the pointer must stay in a
//   zone hugging the strip's edge for ~200 ms (the 150–250 ms band the
//   owner's feedback named; 200 is the middle — long enough that a
//   flick toward the Dock never trips it, short enough that aiming at
//   the strip never feels gated). A pointer passing THROUGH the zone
//   on its way off-window reveals nothing.
// - In fullscreen the last few points at the actual screen edge are
//   the SYSTEM'S: that sliver is where macOS reads Dock (bottom) and
//   menu-bar (top) summons, so it never arms the dwell — and a pointer
//   pushing into it while the strip is up hides the strip immediately
//   (the push IS the summon gesture; the strip yields). Windowed, the
//   sliver is off: the window's bottom edge isn't the screen's, and
//   leaving the window is the signal that matters.
// - Leaving the window bounds hides the strip instantly: a pointer
//   headed below the window (the windowed-mode Dock aim) or anywhere
//   else off-window isn't using the strip, and the strip must not sit
//   where the Dock is about to appear. (When the Dock IS summoned over
//   a fullscreen window, macOS routes events to it regardless — this
//   rule keeps the strip from visually squatting there.)
// - Once revealed, the CL-16 fade discipline holds: fades ~2 s after
//   the last activity IN THE ZONE, never while hovered, hover exit
//   restamps. Activity out in the video no longer pins it — the strip
//   gets out of the way while you work.
// - Hidden mode (the "Hide Control Strip" preference) makes the policy
//   inert: nothing reveals, every deadline is nil. The Actions menu +
//   shortcuts remain the full surface.

import Foundation

/// Which window edge the strip (and its reveal zone) hugs — the
/// CL-18 per-app preference. Bottom is CL-13's original home; top is
/// the out-of-the-Dock's-way alternative.
public enum StripEdge: String, CaseIterable, Sendable {
    case bottom
    case top
}

/// The strip preferences' storage shape (CL-18): app-wide, in
/// UserDefaults. The app's views bind these same keys via @AppStorage;
/// these helpers are the load/save seam the persistence tests pin
/// (unknown raw values fall back to the defaults, so a downgrade or a
/// hand-edited plist never wedges the strip).
public enum StripPreferences {
    public static let edgeKey = "controlStripEdge"
    public static let hiddenKey = "controlStripHidden"

    public static func edge(from defaults: UserDefaults = .standard) -> StripEdge {
        defaults.string(forKey: edgeKey).flatMap(StripEdge.init(rawValue:))
            ?? .bottom
    }

    public static func setEdge(
        _ edge: StripEdge, in defaults: UserDefaults = .standard
    ) {
        defaults.set(edge.rawValue, forKey: edgeKey)
    }

    public static func hidden(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: hiddenKey)
    }

    public static func setHidden(
        _ hidden: Bool, in defaults: UserDefaults = .standard
    ) {
        defaults.set(hidden, forKey: hiddenKey)
    }
}

/// The reveal/fade state machine. Sans-IO: time is nanoseconds handed
/// in by the caller, geometry is a distance-from-edge the view layer
/// computes against the CONFIGURED edge. The driver feeds pointer
/// events, asks `nextDeadline` for when to wake, and calls `tick` on
/// waking; `isVisible` is the one output.
public struct StripRevealPolicy: Sendable {
    public struct Config: Sendable {
        /// Continuous zone presence required before the strip reveals.
        public var dwellNanoseconds: UInt64 = 200_000_000
        /// Idle time after the last zone activity before the fade
        /// (the CL-13/CL-16 figure, kept).
        public var idleFadeNanoseconds: UInt64 = 2_000_000_000
        /// The reveal zone's depth from the configured edge — covers
        /// the strip itself plus a comfortable approach.
        public var zoneThicknessPoints: Double = 90
        /// The system's sliver at a SCREEN edge (fullscreen only):
        /// pointer presence here is a Dock/menu-bar summon, never a
        /// strip dwell.
        public var systemEdgeSliverPoints: Double = 6
        public init() {}
    }

    public let config: Config

    /// The one output: whether the strip is on screen.
    public private(set) var isVisible = false
    /// Hidden mode (the preference): the policy goes inert — nothing
    /// reveals, and flipping it on takes a visible strip down.
    public var hiddenMode: Bool {
        didSet { if hiddenMode { forceHide() } }
    }

    /// When the pointer's current uninterrupted zone visit began; nil
    /// when the pointer is not known to be in the zone.
    private var dwellStart: UInt64?
    /// The fade anchor: last pointer activity in the zone (or hover
    /// exit) while visible.
    private var lastZoneActivity: UInt64 = 0
    private var hovered = false

    public init(config: Config = Config(), hiddenMode: Bool = false) {
        self.config = config
        self.hiddenMode = hiddenMode
    }

    /// A pointer event inside the window. `edgeDistance` is measured
    /// from the CONFIGURED edge; `atSystemEdge` says that edge is a
    /// real screen edge right now (fullscreen), arming the sliver rule.
    public mutating func pointerMoved(
        edgeDistance: Double, atSystemEdge: Bool, now: UInt64
    ) {
        guard !hiddenMode else { return }
        if atSystemEdge, edgeDistance < config.systemEdgeSliverPoints {
            // The system's pixels: a push here summons the Dock or the
            // menu bar. Never a dwell — and the strip yields the spot.
            dwellStart = nil
            forceHide()
            return
        }
        guard edgeDistance < config.zoneThicknessPoints else {
            dwellStart = nil    // transit ended outside — dwell over
            return
        }
        if isVisible {
            lastZoneActivity = now
            return
        }
        let started = dwellStart ?? now
        dwellStart = started
        if now &- started >= config.dwellNanoseconds {
            reveal(now: now)
        }
    }

    /// The pointer left the window bounds (hover tracking's exit): the
    /// strip hides NOW — whatever the pointer is headed for (the Dock,
    /// another window), it isn't the strip, and the strip must not sit
    /// where the Dock lands.
    public mutating func pointerExitedWindow(now: UInt64) {
        dwellStart = nil
        hovered = false
        forceHide()
    }

    /// Hover on the strip itself: pins visibility (never fade under
    /// the pointer); exit restamps so the fade lands a full idle
    /// interval later — the CL-16 behavior, kept.
    public mutating func hoverChanged(_ hovering: Bool, now: UInt64) {
        guard !hiddenMode else { return }
        hovered = hovering
        if !hovering, isVisible { lastZoneActivity = now }
    }

    /// A user gesture that should keep a visible strip up (the strip's
    /// own buttons — e.g. the edge toggle teleporting it away from the
    /// pointer must not strand it mid-fade).
    public mutating func keepAlive(now: UInt64) {
        guard isVisible else { return }
        lastZoneActivity = now
    }

    /// Deadline work: completes a dwell whose pointer went stationary
    /// inside the zone (no more move events — that is exactly what
    /// dwelling looks like), and runs the idle fade.
    public mutating func tick(now: UInt64) {
        guard !hiddenMode else { return }
        if !isVisible, let started = dwellStart,
           now &- started >= config.dwellNanoseconds {
            reveal(now: now)
            return
        }
        if isVisible, !hovered,
           now &- lastZoneActivity >= config.idleFadeNanoseconds {
            forceHide()
        }
    }

    /// When the driver should call `tick` next; nil means nothing is
    /// pending (hover pins, hidden mode, or simply nothing to do —
    /// the next pointer event re-arms).
    public var nextDeadline: UInt64? {
        guard !hiddenMode else { return nil }
        if !isVisible {
            return dwellStart.map { $0 &+ config.dwellNanoseconds }
        }
        guard !hovered else { return nil }
        return lastZoneActivity &+ config.idleFadeNanoseconds
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
