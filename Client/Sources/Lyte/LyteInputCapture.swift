// LyteInputCapture: NSEvent capture for the stream window. Speaks the
// host's input wire: evdev position codes (the host's XKB map owns
// layout), absolute pointer pixels in the host's recorded-monitor space,
// smooth-scroll pixel deltas.
//
// Coordinate mapping: the display layer draws with resizeAspect, so
// absolute positions map through the aspect-fit rect (letterbox bars
// excluded) and scale to the host's stream dimensions from the first
// delivered sample. Until the size is known, absolute moves are dropped
// — a wrongly-scaled click is worse than a swallowed one.
//
// Forwarding decisions (what stays local, what the host holds, ⌘ as
// Super) live in the pure InputForwardingPolicy; this shell measures the
// facts and executes the verdicts.
//
// Mouse events hit-test first so overlaid SwiftUI controls stay
// clickable: an event lands on the video iff the hit view is the video
// layer view or a descendant. Every mouse move also feeds `onActivity`
// with the pointer's edge geometry for the strip's reveal policy.

import AppKit
import Carbon.HIToolbox
import LyteClientCore
import LyteTransport
import LyteWire

/// One mouse event's edge geometry for the strip's reveal policy:
/// distances from both horizontal window edges and whether they are
/// real screen edges right now (fullscreen).
struct PointerActivity {
    var distanceFromBottom: CGFloat
    var distanceFromTop: CGFloat
    var isFullscreen: Bool
}

@MainActor
final class LyteInputCapture {
    private weak var view: NSView?
    private weak var window: NSWindow?
    /// The session's input leg. Refusals (teardown races) are counted,
    /// never thrown into the event monitor.
    private let send: @MainActor (InputEvent.Body) -> Void
    /// The host's stream dimensions in pixels, read live from the
    /// owning model (updated when the first sample arrives).
    private let videoSize: @MainActor () -> CGSize
    /// Fed on every mouse event in the window — the control strip's
    /// reveal/idle-fade clock. Never fed for keys: typing must not
    /// resurface the strip.
    private let onActivity: @MainActor (PointerActivity) -> Void
    private var monitors: [Any] = []
    private var forwarding = InputForwardingPolicy()
    private var resignObserver: NSObjectProtocol?

    init(
        view: NSView,
        window: NSWindow,
        videoSize: @escaping @MainActor () -> CGSize,
        send: @escaping @MainActor (InputEvent.Body) -> Void,
        onActivity: @escaping @MainActor (PointerActivity) -> Void = { _ in }
    ) {
        self.view = view
        self.window = window
        self.videoSize = videoSize
        self.send = send
        self.onActivity = onActivity
        window.acceptsMouseMovedEvents = true
    }

    func start() {
        let mouseEvents: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
        ]
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            self?.handleMouse(event) ?? event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleKey(event) ?? event
        } as Any)
        // ⌘Tab away mid-stream swallows the matching keyUps exactly the
        // way teardown does: whatever the host holds would stay down and
        // auto-repeat. Focus loss releases everything; keys still
        // physically held re-press on return.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAllHeld() }
        }
    }

    /// Sends up-events for every key/button the host believes is down.
    private func releaseAllHeld() {
        forwarding.releaseAll().forEach(send)
    }

    private func execute(_ verdict: InputForwardingPolicy.Verdict,
                         _ event: NSEvent) -> NSEvent? {
        verdict.sends.forEach(send)
        return verdict.consumed ? nil : event
    }

    func stop() {
        // A window/session teardown can swallow AppKit's matching keyUp.
        // Release every state we told the host was down before detaching.
        releaseAllHeld()
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    // MARK: - Mouse

    /// The aspect-fit rect the video actually occupies; nil until the
    /// stream size is known.
    private func videoRect(in bounds: CGRect) -> CGRect? {
        let size = videoSize()
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// True when the hit view is the video layer view or a descendant.
    /// Anything else — nil, a sibling, or an ancestor (NSHostingView
    /// answering for its own SwiftUI content) — means an overlay
    /// claimed the point.
    private func landsOnVideoSurface(_ event: NSEvent) -> Bool {
        guard let view, let content = event.window?.contentView else {
            return false
        }
        let point = content.superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
        guard let hit = content.hitTest(point) else { return false }
        var walk: NSView? = hit
        while let candidate = walk {
            if candidate === view { return true }
            walk = candidate.superview
        }
        return false
    }

    private func handleMouse(_ event: NSEvent) -> NSEvent? {
        guard let view, let window, event.window === window, window.isKeyWindow else { return event }
        // The window frame's bottom-left is also the content view's
        // bottom-left — good enough for the reveal zone.
        let contentHeight = window.contentView?.frame.height ?? 0
        onActivity(PointerActivity(
            distanceFromBottom: event.locationInWindow.y,
            distanceFromTop: contentHeight - event.locationInWindow.y,
            isFullscreen: window.styleMask.contains(.fullScreen)))
        let onVideo = landsOnVideoSurface(event)

        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            let pressed = [
                NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown,
            ].contains(event.type)
            return execute(forwarding.button(
                MacEvdevKeyMap.evdevButton(
                    forMacButtonNumber: event.buttonNumber),
                pressed: pressed, onVideo: onVideo,
                commandHeld: event.modifierFlags.contains(.command)), event)
        default:
            break
        }
        // Only the video surface feeds the host motion and scroll;
        // overlays keep their own events.
        guard onVideo else { return event }

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let p = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(p) || event.type != .mouseMoved else { return event }
            guard let r = videoRect(in: view.bounds), r.width > 1, r.height > 1 else {
                return event    // stream size unknown: drop, never guess
            }
            let size = videoSize()
            // Clamp into the video rect, normalize, scale to host
            // pixels; flip to the host's top-left origin.
            let x = min(max(p.x - r.minX, 0), r.width) / r.width * size.width
            let y = min(max(r.maxY - p.y, 0), r.height) / r.height * size.height
            send(.pointerMotionAbsolute(x: x, y: y))
            return nil

        case .scrollWheel:
            // Precise deltas (trackpad) are already pixels; line deltas
            // (wheel notches) scale at libinput's ~15 px per detent —
            // the same constant the host's uinput leaf divides by. Sign
            // flip: AppKit's positive-up vs evdev's positive-down.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 15
            let dx = -event.scrollingDeltaX * scale
            let dy = -event.scrollingDeltaY * scale
            let ended = event.phase == .ended || event.phase == .cancelled
                || event.momentumPhase == .ended
            if dx != 0 || dy != 0 {
                send(.pointerAxis(dx: dx, dy: dy, finish: ended))
            } else if ended {
                send(.pointerAxis(dx: 0, dy: 0, finish: true))
            }
            return nil

        default:
            return event
        }
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, window.isKeyWindow else { return event }
        let commandHeld = event.modifierFlags.contains(.command)
        let iso = KBGetLayoutType(Int16(LMGetKbdType()))
            == PhysicalKeyboardLayoutType(kKeyboardISO)

        switch event.type {
        case .keyDown:
            let code = MacEvdevKeyMap.evdevKeycode(
                forMacKeyCode: event.keyCode, isoKeyboard: iso)
            return execute(forwarding.keyDown(
                code, isRepeat: event.isARepeat, commandHeld: commandHeld,
                isLocalShortcut: commandHeld
                    && Self.isLocalShortcut(event)), event)

        case .keyUp:
            let code = MacEvdevKeyMap.evdevKeycode(
                forMacKeyCode: event.keyCode, isoKeyboard: iso)
            return execute(
                forwarding.keyUp(code, commandHeld: commandHeld), event)

        case .flagsChanged where event.keyCode == MacEvdevKeyMap.capsLockKeyCode:
            guard let code = MacEvdevKeyMap.evdevKeycode(
                forMacKeyCode: event.keyCode) else { return event }
            return execute(forwarding.lockToggled(code), event)

        case .flagsChanged:
            guard let (keycode, deviceMask) =
                MacEvdevKeyMap.modifierKeys[event.keyCode] else { return event }
            let pressed = event.modifierFlags.rawValue & UInt(deviceMask) != 0
            return execute(forwarding.modifier(keycode, pressed: pressed), event)

        default:
            return event
        }
    }

    /// True when a menu item (the app's own commands, which own every
    /// window-management chord: ⌘W, ⌘Q, ⌘H, ⌘M, the Actions menu)
    /// answers this ⌘ key equivalent. System chords (⌘Tab, ⌘Space)
    /// never reach the app at all.
    private static func isLocalShortcut(_ event: NSEvent) -> Bool {
        guard let menu = NSApp.mainMenu,
              let characters = event.charactersIgnoringModifiers?.lowercased(),
              !characters.isEmpty
        else { return false }
        let chordMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let modifiers = event.modifierFlags.intersection(chordMask)
        return menuAnswers(menu, characters: characters, modifiers: modifiers)
    }

    private static func menuAnswers(
        _ menu: NSMenu, characters: String, modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        for item in menu.items {
            if let submenu = item.submenu,
               menuAnswers(submenu, characters: characters, modifiers: modifiers) {
                return true
            }
            let equivalent = item.keyEquivalent
            guard !equivalent.isEmpty else { continue }
            var mask = item.keyEquivalentModifierMask
            // An uppercase equivalent implies ⇧ (AppKit's convention).
            if equivalent != equivalent.lowercased() { mask.insert(.shift) }
            if equivalent.lowercased() == characters,
               mask.intersection([.command, .shift, .option, .control]) == modifiers {
                return true
            }
        }
        return false
    }
}
