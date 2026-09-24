import LyteWire

/// The input capture's forwarding decisions, pure: which wire events one
/// key, modifier, or button event produces, and whether AppKit still sees
/// it. `LyteInputCapture` measures the facts (evdev code, ⌘ state, local
/// shortcut, hit test) and executes the verdict.
///
/// Invariants:
/// - The host's view of held keys and buttons stays balanced: every
///   release of something the host holds is forwarded, ahead of the ⌘
///   and hit-test gates, so a release that happens under ⌘ or over the
///   control strip never strands a key or drag down on the host.
/// - ⌘ reaches the host only as part of a host chord. Its press is held
///   back until a forwarded key or button joins it, then sent first; a ⌘
///   used only for local (AppKit) shortcuts is never seen by the host, so
///   no lone Super tap (GNOME's Activities toggle) leaks out.
/// - Local shortcuts stay local; auto-repeats never cross (the wire has
///   no repeat value — a down without its up wedges a key).
struct InputForwardingPolicy {
    struct Verdict: Equatable {
        /// Wire events to send, in order.
        var sends: [InputEvent.Body]
        /// True when the capture swallows the event; false returns it to
        /// AppKit.
        var consumed: Bool

        static let passThrough = Verdict(sends: [], consumed: false)
        static let swallow = Verdict(sends: [], consumed: true)
    }

    /// KEY_LEFTMETA and KEY_RIGHTMETA — the evdev face of ⌘.
    static let commandKeycodes: Set<UInt32> = [125, 126]

    /// evdev key codes the host believes are down.
    private(set) var heldKeys: Set<UInt32> = []
    /// evdev button codes the host believes are down.
    private(set) var heldButtons: Set<UInt32> = []
    /// ⌘ keys physically down but not yet forwarded.
    private(set) var pendingCommandKeys: Set<UInt32> = []

    /// A key press. `code` is nil for keys with no evdev mapping;
    /// `isLocalShortcut` says an app shortcut owns this ⌘ chord.
    mutating func keyDown(
        _ code: UInt32?, isRepeat: Bool, commandHeld: Bool,
        isLocalShortcut: Bool
    ) -> Verdict {
        if commandHeld, isLocalShortcut { return .passThrough }
        if isRepeat { return .swallow }
        guard let code else { return .passThrough }
        var sends = flushPendingCommand()
        sends.append(.keyKeycode(keycode: code, pressed: true))
        heldKeys.insert(code)
        return Verdict(sends: sends, consumed: true)
    }

    mutating func keyUp(_ code: UInt32?, commandHeld: Bool) -> Verdict {
        guard let code else { return .passThrough }
        if heldKeys.remove(code) != nil {
            return Verdict(
                sends: [.keyKeycode(keycode: code, pressed: false)],
                consumed: true)
        }
        // Never forwarded: a local chord's release belongs to AppKit;
        // anything else has no host state to balance.
        return commandHeld ? .passThrough : .swallow
    }

    /// A modifier edge (flagsChanged), already mapped to evdev.
    mutating func modifier(_ code: UInt32, pressed: Bool) -> Verdict {
        if pressed {
            if Self.commandKeycodes.contains(code) {
                pendingCommandKeys.insert(code)
                return .swallow
            }
            heldKeys.insert(code)
            return Verdict(
                sends: [.keyKeycode(keycode: code, pressed: true)],
                consumed: true)
        }
        if pendingCommandKeys.remove(code) != nil { return .swallow }
        if heldKeys.remove(code) != nil {
            return Verdict(
                sends: [.keyKeycode(keycode: code, pressed: false)],
                consumed: true)
        }
        return .swallow
    }

    /// A mouse button edge. `onVideo` is the hit test: true when the
    /// point belongs to the video surface rather than an overlay.
    mutating func button(
        _ code: UInt32?, pressed: Bool, onVideo: Bool
    ) -> Verdict {
        guard let code else { return .passThrough }
        if pressed {
            guard onVideo else { return .passThrough }
            var sends = flushPendingCommand()
            sends.append(.pointerButton(button: code, pressed: true))
            heldButtons.insert(code)
            return Verdict(sends: sends, consumed: true)
        }
        if heldButtons.remove(code) != nil {
            return Verdict(
                sends: [.pointerButton(button: code, pressed: false)],
                consumed: true)
        }
        // A press AppKit saw must reach AppKit's release too.
        return .passThrough
    }

    /// Focus loss or teardown: release everything the host holds. A ⌘
    /// that was never forwarded is simply forgotten.
    mutating func releaseAll() -> [InputEvent.Body] {
        let sends = heldKeys.sorted().map {
            InputEvent.Body.keyKeycode(keycode: $0, pressed: false)
        } + heldButtons.sorted().map {
            InputEvent.Body.pointerButton(button: $0, pressed: false)
        }
        heldKeys.removeAll()
        heldButtons.removeAll()
        pendingCommandKeys.removeAll()
        return sends
    }

    private mutating func flushPendingCommand() -> [InputEvent.Body] {
        let flushed = pendingCommandKeys.sorted()
        pendingCommandKeys.removeAll()
        heldKeys.formUnion(flushed)
        return flushed.map { .keyKeycode(keycode: $0, pressed: true) }
    }
}
