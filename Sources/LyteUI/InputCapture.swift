import AppKit
import LyteKit

/// Free-mouse ("Work" mode) input capture for the stream window: absolute
/// mouse position, buttons, hi-res scroll, and keyboard via local NSEvent
/// monitors. ⌘-chorded keys stay local (window management shortcuts must not
/// leak to the host); everything else is consumed and forwarded.
@MainActor
public final class InputCapture {
    private weak var view: NSView?
    private weak var window: NSWindow?
    private let send: (Data, UInt8) -> Void
    private var monitors: [Any] = []

    /// Host stream dimensions. Absolute coordinates must be relative to the
    /// video area (the aspect-fit rect), not the whole view — the layer draws
    /// with resizeAspect, so any letterbox/pillarbox bars would otherwise
    /// scale-and-shift the mapping and the host cursor lands pixels off.
    public var videoSize: CGSize = .zero

    /// Play-mode mouse lock: relative deltas, hidden + frozen local cursor.
    /// Toggled with the ⌃⌥ chord (PLAN §4.3 release recipe).
    public private(set) var locked = false
    private var chordArmed = true   // rearm after both chord keys release
    private var baseTitle = ""

    public init(view: NSView, window: NSWindow, send: @escaping (Data, UInt8) -> Void) {
        self.view = view
        self.window = window
        self.send = send
        window.acceptsMouseMovedEvents = true
        baseTitle = window.title
    }

    public func start() {
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

    public func stop() {
        if locked { setLocked(false) }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    public func toggleLock() {
        setLocked(!locked)
    }

    private func setLocked(_ lock: Bool) {
        locked = lock
        if lock {
            CGAssociateMouseAndMouseCursorPosition(0)   // freeze the local cursor
            NSCursor.hide()
            window?.title = baseTitle + "  🎮 mouse locked — ⌃⌥ releases"
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
            window?.title = baseTitle
            // Release-all-modifiers on uncapture so nothing sticks host-side
            for (vk, _) in MacKeyMap.modifierVKs.values {
                send(InputPacket.keyEvent(down: false, windowsVK: vk, modifiers: []),
                     InputPacket.channelKeyboard)
            }
        }
    }

    // MARK: - Mouse

    /// The aspect-fit rect the video actually occupies (resizeAspect math);
    /// falls back to the full bounds until the stream size is known.
    private func videoRect(in bounds: CGRect) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func handleMouse(_ event: NSEvent) -> NSEvent? {
        guard let view, let window, event.window === window, window.isKeyWindow else { return event }

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if locked {
                let dx = Int(event.deltaX), dy = Int(event.deltaY)
                if dx != 0 || dy != 0 {
                    send(InputPacket.mouseMoveRelative(dx: Int16(clamping: dx),
                                                       dy: Int16(clamping: dy)),
                         InputPacket.channelMouse)
                }
                return nil
            }
            let p = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(p) || event.type != .mouseMoved else { return event }
            let r = videoRect(in: view.bounds)
            guard r.width > 1, r.height > 1 else { return event }
            let x = Int16(min(max(p.x - r.minX, 0), r.width).rounded())
            let y = Int16(min(max(r.maxY - p.y, 0), r.height).rounded())   // flip to top-left origin
            send(InputPacket.mouseMoveAbsolute(x: x, y: y,
                                               width: Int16(r.width.rounded()),
                                               height: Int16(r.height.rounded())),
                 InputPacket.channelMouse)
            return nil

        case .leftMouseDown, .leftMouseUp:
            send(InputPacket.mouseButton(down: event.type == .leftMouseDown, button: .left),
                 InputPacket.channelMouse)
            return nil

        case .rightMouseDown, .rightMouseUp:
            send(InputPacket.mouseButton(down: event.type == .rightMouseDown, button: .right),
                 InputPacket.channelMouse)
            return nil

        case .otherMouseDown, .otherMouseUp:
            let button: InputPacket.MouseButton
            switch event.buttonNumber {
            case 2: button = .middle
            case 3: button = .x1
            case 4: button = .x2
            default: return event
            }
            send(InputPacket.mouseButton(down: event.type == .otherMouseDown, button: button),
                 InputPacket.channelMouse)
            return nil

        case .scrollWheel:
            // Precise deltas (trackpad) arrive in points; line deltas per notch.
            // 120 hi-res units = one wheel click.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 4 : 40
            let dy = Int(event.scrollingDeltaY * scale)
            let dx = Int(event.scrollingDeltaX * scale)
            if dy != 0 {
                send(InputPacket.scroll(amount: Int16(clamping: dy)), InputPacket.channelMouse)
            }
            if dx != 0 {
                send(InputPacket.hscroll(amount: Int16(clamping: dx)), InputPacket.channelMouse)
            }
            return nil

        default:
            return event
        }
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let window, window.isKeyWindow else { return event }

        // ⌘-chorded keys stay local (⌘W close, ⌘Q quit, ⌘Tab is system-level).
        if event.type != .flagsChanged, event.modifierFlags.contains(.command) {
            return event
        }

        switch event.type {
        case .keyDown, .keyUp:
            guard let vk = MacKeyMap.windowsVK(forMacKeyCode: event.keyCode) else { return event }
            send(InputPacket.keyEvent(down: event.type == .keyDown, windowsVK: vk,
                                      modifiers: modifiers(from: event.modifierFlags)),
                 InputPacket.channelKeyboard)
            return nil

        case .flagsChanged:
            // ⌃⌥ chord toggles Play-mode mouse lock (rearms when released)
            let chordDown = event.modifierFlags.contains(.control) && event.modifierFlags.contains(.option)
            if chordDown && chordArmed {
                chordArmed = false
                setLocked(!locked)
            } else if !event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.option) {
                chordArmed = true
            }
            guard let (vk, deviceMask) = MacKeyMap.modifierVKs[event.keyCode] else { return event }
            let down = event.modifierFlags.rawValue & UInt(deviceMask) != 0
            // Per InputStream.c: left-side modifiers must carry their own flag;
            // right-side (extended) modifiers must NOT, or GFE/Sunshine
            // synthesizes a stuck non-extended key.
            var mods = modifiers(from: event.modifierFlags)
            switch vk {
            case 0xA0: mods.insert(.shift)
            case 0xA1: mods.remove(.shift)
            case 0xA2: mods.insert(.ctrl)
            case 0xA3: mods.remove(.ctrl)
            case 0xA4: mods.insert(.alt)
            case 0xA5: mods.remove(.alt)
            default: break
            }
            send(InputPacket.keyEvent(down: down, windowsVK: vk, modifiers: mods),
                 InputPacket.channelKeyboard)
            return nil

        default:
            return event
        }
    }

    private func modifiers(from flags: NSEvent.ModifierFlags) -> InputPacket.Modifiers {
        var m: InputPacket.Modifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.ctrl) }
        if flags.contains(.option) { m.insert(.alt) }
        if flags.contains(.command) { m.insert(.meta) }
        return m
    }
}
