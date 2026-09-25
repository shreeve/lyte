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
/// - ⌘ with a letter is the Mac's Control chord: the host gets Ctrl with
///   the letter and whatever else is held (⌘⇧Z is Ctrl+Shift+Z), never
///   Super. The Ctrl it adds is released with the last such letter.
/// - Local shortcuts stay local; auto-repeats never cross (the wire has
///   no repeat value — a down without its up wedges a key), and a key the
///   host holds never becomes a local shortcut by repeating under ⌘.
/// - A key or click's own modifier flags are the truth about every
///   modifier: menu tracking and title-bar drags can swallow a release,
///   and focus loss releases what is still physically held. A stale ⌘
///   must neither ride the next key out as Super nor stay down, and
///   Shift, Control and Option are pressed or released to match before
///   the key or click goes out.
/// - A key's release goes out as the evdev code its press went out as,
///   whatever the key map says at release time.
/// - The host's Caps Lock follows the Mac's: the host starts with it off,
///   and any key or lock event whose flags disagree taps it once.
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
    /// Left and right Shift, Control and Option — the modifiers that ride
    /// to the host as themselves.
    static let plainModifierKeycodes: Set<UInt32> = [42, 54, 29, 97, 56, 100]
    /// KEY_LEFTCTRL and KEY_RIGHTCTRL.
    static let controlKeycodes: Set<UInt32> = [29, 97]
    /// The evdev positions of the letters A–Z.
    static let letterKeycodes = Set<UInt32>(16...25).union(30...38).union(44...50)

    /// evdev key codes the host believes are down.
    private(set) var heldKeys: Set<UInt32> = []
    /// evdev button codes the host believes are down.
    private(set) var heldButtons: Set<UInt32> = []
    /// ⌘ keys physically down but not yet forwarded.
    private(set) var pendingCommandKeys: Set<UInt32> = []
    /// The evdev code each forwarded press went out as, by Mac key code.
    private(set) var pressedAs: [UInt16: UInt32] = [:]
    /// Letters held in a ⌘ chord that pressed KEY_LEFTCTRL on the host
    /// for them; that Ctrl is down exactly while this is non-empty.
    private(set) var controlChordKeys: Set<UInt32> = []
    /// The host's Caps Lock as this capture has driven it.
    private(set) var hostCapsLock = false

    /// KEY_CAPSLOCK.
    static let capsLockKeycode: UInt32 = 58

    /// A key press. `mapped` is nil for keys with no evdev mapping;
    /// `macKeyCode` names the physical key, so its release can reuse this
    /// press's code; `isLocalShortcut` says an app shortcut owns this ⌘
    /// chord; `modifiersDown` is the event's own record of which plain
    /// modifier keys are physically down and `capsLockOn` its Caps Lock
    /// state (nil when unknown).
    mutating func keyDown(
        _ mapped: UInt32?, macKeyCode: UInt16? = nil, isRepeat: Bool,
        commandHeld: Bool, isLocalShortcut: Bool,
        modifiersDown: Set<UInt32>? = nil, capsLockOn: Bool? = nil
    ) -> Verdict {
        let code = macKeyCode.flatMap { pressedAs[$0] } ?? mapped
        // A key the host holds is the host's to repeat, whatever modifier
        // joined since: its repeats never fire a local shortcut.
        if isRepeat, let code, heldKeys.contains(code) { return .swallow }
        if commandHeld, isLocalShortcut { return .passThrough }
        if isRepeat { return .swallow }
        guard let code else { return .passThrough }
        var sends: [InputEvent.Body] = []
        if let capsLockOn { sends += syncCapsLock(capsLockOn) }
        sends += resyncModifiers(modifiersDown)
        if commandHeld, Self.letterKeycodes.contains(code) {
            sends += holdBackCommand()
            // A physically held Ctrl already makes the chord.
            if !controlChordKeys.isEmpty
                || heldKeys.isDisjoint(with: Self.controlKeycodes) {
                if controlChordKeys.isEmpty {
                    sends.append(.keyKeycode(keycode: 29, pressed: true))
                }
                controlChordKeys.insert(code)
            }
        } else {
            sends += resyncCommand(held: commandHeld)
        }
        sends.append(.keyKeycode(keycode: code, pressed: true))
        heldKeys.insert(code)
        if let macKeyCode { pressedAs[macKeyCode] = code }
        return Verdict(sends: sends, consumed: true)
    }

    mutating func keyUp(
        _ mapped: UInt32?, macKeyCode: UInt16? = nil, commandHeld: Bool
    ) -> Verdict {
        let pressed = macKeyCode.flatMap { pressedAs.removeValue(forKey: $0) }
        guard let code = pressed ?? mapped else { return .passThrough }
        if heldKeys.remove(code) != nil {
            var sends: [InputEvent.Body] = [.keyKeycode(keycode: code, pressed: false)]
            if controlChordKeys.remove(code) != nil, controlChordKeys.isEmpty {
                sends.append(.keyKeycode(keycode: 29, pressed: false))
            }
            return Verdict(sends: sends, consumed: true)
        }
        // Never forwarded: a local chord's release belongs to AppKit;
        // anything else has no host state to balance.
        return commandHeld ? .passThrough : .swallow
    }

    /// A modifier edge (flagsChanged), already mapped to evdev.
    mutating func modifier(_ code: UInt32, pressed: Bool) -> Verdict {
        if pressed {
            if Self.commandKeycodes.contains(code) {
                // Already forwarded (its release went missing): keep it
                // held so this press's release reaches the host.
                if !heldKeys.contains(code) { pendingCommandKeys.insert(code) }
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

    /// Caps Lock's new state (macOS reports a flip, never a press or
    /// release). A disagreement with the host is one full tap there —
    /// never held, so the host has nothing to repeat or strand.
    mutating func capsLockChanged(on: Bool) -> Verdict {
        Verdict(sends: syncCapsLock(on), consumed: true)
    }

    /// A mouse button edge. `onVideo` is the hit test: true when the
    /// point belongs to the video surface rather than an overlay.
    mutating func button(
        _ code: UInt32?, pressed: Bool, onVideo: Bool, commandHeld: Bool,
        modifiersDown: Set<UInt32>? = nil
    ) -> Verdict {
        guard let code else { return .passThrough }
        if pressed {
            guard onVideo else { return .passThrough }
            var sends = resyncModifiers(modifiersDown)
            sends += resyncCommand(held: commandHeld)
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
        let keys = heldKeys.sorted() + (controlChordKeys.isEmpty ? [] : [29])
        let sends = keys.map {
            InputEvent.Body.keyKeycode(keycode: $0, pressed: false)
        } + heldButtons.sorted().map {
            InputEvent.Body.pointerButton(button: $0, pressed: false)
        }
        heldKeys.removeAll()
        controlChordKeys.removeAll()
        heldButtons.removeAll()
        pendingCommandKeys.removeAll()
        pressedAs.removeAll()
        return sends
    }

    /// The Caps Lock tap that brings the host to the Mac's state `on`.
    private mutating func syncCapsLock(_ on: Bool) -> [InputEvent.Body] {
        guard on != hostCapsLock else { return [] }
        hostCapsLock = on
        return [
            .keyKeycode(keycode: Self.capsLockKeycode, pressed: true),
            .keyKeycode(keycode: Self.capsLockKeycode, pressed: false),
        ]
    }

    /// The Shift/Control/Option edges that make the host's view match the
    /// physical keys ahead of a forwarded press: stale ones released, ones
    /// held since before focus returned pressed.
    private mutating func resyncModifiers(
        _ down: Set<UInt32>?
    ) -> [InputEvent.Body] {
        guard let down = down?.intersection(Self.plainModifierKeycodes)
        else { return [] }
        let held = heldKeys.intersection(Self.plainModifierKeycodes)
        let stale = held.subtracting(down).sorted()
        let missing = down.subtracting(held).sorted()
        heldKeys.subtract(stale)
        heldKeys.formUnion(missing)
        return stale.map { .keyKeycode(keycode: $0, pressed: false) }
            + missing.map { .keyKeycode(keycode: $0, pressed: true) }
    }

    /// Ahead of a Control chord: a ⌘ already forwarded as Super is
    /// released on the host and held back again, as if never sent.
    private mutating func holdBackCommand() -> [InputEvent.Body] {
        let forwarded = heldKeys.intersection(Self.commandKeycodes).sorted()
        heldKeys.subtract(forwarded)
        pendingCommandKeys.formUnion(forwarded)
        return forwarded.map { .keyKeycode(keycode: $0, pressed: false) }
    }

    /// The ⌘ edges to send ahead of a forwarded press: with ⌘ down, the
    /// held-back ⌘ joins the chord; with ⌘ up, a held-back ⌘ is dropped
    /// and a forwarded one is released.
    private mutating func resyncCommand(held: Bool) -> [InputEvent.Body] {
        let pending = pendingCommandKeys.sorted()
        pendingCommandKeys.removeAll()
        if held {
            heldKeys.formUnion(pending)
            return pending.map { .keyKeycode(keycode: $0, pressed: true) }
        }
        let stale = heldKeys.intersection(Self.commandKeycodes).sorted()
        heldKeys.subtract(stale)
        return stale.map { .keyKeycode(keycode: $0, pressed: false) }
    }
}
