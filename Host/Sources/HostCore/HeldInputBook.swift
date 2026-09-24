/// The keys and pointer buttons the host pressed for the client and has not
/// yet released, by evdev code. A kernel input device never releases a
/// latched key itself, and a client whose path is dark cannot send the
/// release, so the host releases on the client's behalf in two scopes:
///
/// - `.autorepeatingKeys` — every held key except the modifiers: what a
///   compositor autorepeats while it believes the key is down. Released
///   after a long silence (Session.inputSilenceReleaseNS), so a runaway
///   repeat is bounded while an ordinary Wi-Fi hitch leaves a held key held
///   (the client swallows repeats for keys it believes are down, so a key
///   released mid-hold would stay dead until pressed again).
/// - `.everything` — the modifiers and pointer buttons too, which do not
///   repeat: released only when the session ends, so a held Shift or a drag
///   survives any gap the session itself survives.
public struct HeldInputBook: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        case autorepeatingKeys
        case everything
    }

    /// Shift, Control, Alt and Meta on both sides, Caps Lock and Fn: keys
    /// a compositor reads as state, never autorepeats.
    public static let modifierKeyCodes: Set<UInt32> = [
        29, 97,   // KEY_LEFTCTRL, KEY_RIGHTCTRL
        42, 54,   // KEY_LEFTSHIFT, KEY_RIGHTSHIFT
        56, 100,  // KEY_LEFTALT, KEY_RIGHTALT
        125, 126, // KEY_LEFTMETA, KEY_RIGHTMETA
        58,       // KEY_CAPSLOCK
        464,      // KEY_FN
    ]

    public private(set) var keys: Set<UInt32> = []
    public private(set) var buttons: Set<UInt32> = []

    public init() {}

    public var isEmpty: Bool { keys.isEmpty && buttons.isEmpty }

    public mutating func noteKey(_ code: UInt32, pressed: Bool) {
        if pressed { keys.insert(code) } else { keys.remove(code) }
    }

    public mutating func noteButton(_ code: UInt32, pressed: Bool) {
        if pressed { buttons.insert(code) } else { buttons.remove(code) }
    }

    /// Forgets and returns, ascending, the codes `scope` releases.
    public mutating func takeReleases(_ scope: Scope) -> [UInt32] {
        switch scope {
        case .autorepeatingKeys:
            let released = keys.subtracting(Self.modifierKeyCodes)
            keys.subtract(released)
            return released.sorted()
        case .everything:
            defer {
                keys.removeAll()
                buttons.removeAll()
            }
            return keys.union(buttons).sorted()
        }
    }
}
