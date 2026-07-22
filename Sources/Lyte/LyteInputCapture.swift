// LyteInputCapture (CL-9): NSEvent capture for the Lyte-UDP stream
// window — the input half of the app's Lyte path. The frozen GameStream
// capture (LyteUI.InputCapture) keeps its Windows-VK world untouched;
// this one speaks HS-13's wire: evdev position codes (the host's XKB
// map owns layout), absolute pointer pixels in the HOST's
// recorded-monitor space, smooth-scroll pixel deltas.
//
// Coordinate mapping: the display layer draws with resizeAspect, so the
// video occupies the aspect-fit rect inside the view — absolute
// positions map through that rect (letterbox bars excluded) and scale
// to the host's stream dimensions, learned from the first delivered
// sample's format description. Until the size is known, absolute moves
// are DROPPED rather than guessed: a wrongly-scaled click is worse
// than a swallowed one.
//
// Kept local: ⌘-chorded keys (window management must not leak to the
// host) and key auto-repeats (repeat policy is host-side-deferred per
// the HS-13 row — a repeat without its release would wedge a key).

import AppKit
import LyteTransport

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
    private var monitors: [Any] = []

    init(
        view: NSView,
        window: NSWindow,
        videoSize: @escaping @MainActor () -> CGSize,
        send: @escaping @MainActor (InputEvent.Body) -> Void
    ) {
        self.view = view
        self.window = window
        self.videoSize = videoSize
        self.send = send
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
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    // MARK: - Mouse

    /// The aspect-fit rect the video actually occupies (resizeAspect
    /// math — the InputCapture precedent); nil until the stream size
    /// is known.
    private func videoRect(in bounds: CGRect) -> CGRect? {
        let size = videoSize()
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    private func handleMouse(_ event: NSEvent) -> NSEvent? {
        guard let view, let window, event.window === window, window.isKeyWindow else { return event }

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

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            guard let button = MacEvdevKeyMap.evdevButton(
                forMacButtonNumber: event.buttonNumber) else { return event }
            let pressed = [
                NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown,
            ].contains(event.type)
            send(.pointerButton(button: button, pressed: pressed))
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

        // ⌘-chorded keys stay local (⌘W close, ⌘Q quit, ⌘Tab is system-level).
        if event.type != .flagsChanged, event.modifierFlags.contains(.command) {
            return event
        }

        switch event.type {
        case .keyDown, .keyUp:
            // Auto-repeats stay local: the wire has no repeat value and
            // a stream of downs without ups is a wedged key host-side
            // (repeat policy is the HS-13 row's deferred item).
            if event.type == .keyDown, event.isARepeat { return nil }
            guard let keycode = MacEvdevKeyMap.evdevKeycode(
                forMacKeyCode: event.keyCode) else { return event }
            send(.keyKeycode(keycode: keycode, pressed: event.type == .keyDown))
            return nil

        case .flagsChanged:
            guard let (keycode, deviceMask) =
                MacEvdevKeyMap.modifierKeys[event.keyCode] else { return event }
            let pressed = event.modifierFlags.rawValue & UInt(deviceMask) != 0
            send(.keyKeycode(keycode: keycode, pressed: pressed))
            return nil

        default:
            return event
        }
    }
}
