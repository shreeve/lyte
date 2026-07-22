// MacEvdevKeyMap (CL-9): macOS virtual key code (Carbon kVK_*) → Linux
// evdev keycode (input-event-codes.h) for the Lyte-UDP input path. The
// wire carries evdev POSITION codes on purpose (HS-13's ruling, the
// plan's risk table): the host session's XKB map owns layout; the
// client never guesses keysyms. ANSI layout, the MacKeyMap precedent —
// unmapped keys (media keys, Fn, JIS/ISO extras) are dropped, and the
// key-repeat/modifier POLICY stays deferred per the HS-13 row (this is
// the position-code table only).
//
// Pure data, no AppKit: LyteTransport owns it so the codec tests can
// pin the table and both the app's NSEvent capture and any scripted
// surface read the same rows.

public enum MacEvdevKeyMap {
    /// evdev keycode for one macOS virtual key code; nil = deliberately
    /// unmapped (never forwarded).
    public static func evdevKeycode(forMacKeyCode keyCode: UInt16) -> UInt32? {
        table[keyCode]
    }

    /// evdev codes for left/right modifier keys plus the NX device
    /// mask that says whether that PHYSICAL key is down in a
    /// flagsChanged event (the MacKeyMap shape, retargeted at evdev).
    public static let modifierKeys: [UInt16: (evdev: UInt32, deviceMask: UInt)] = [
        0x38: (42, 0x0000_0002),    // kVK_Shift        → KEY_LEFTSHIFT
        0x3C: (54, 0x0000_0004),    // kVK_RightShift   → KEY_RIGHTSHIFT
        0x3B: (29, 0x0000_0001),    // kVK_Control      → KEY_LEFTCTRL
        0x3E: (97, 0x0000_2000),    // kVK_RightControl → KEY_RIGHTCTRL
        0x3A: (56, 0x0000_0020),    // kVK_Option       → KEY_LEFTALT
        0x3D: (100, 0x0000_0040),   // kVK_RightOption  → KEY_RIGHTALT
        0x37: (125, 0x0000_0008),   // kVK_Command      → KEY_LEFTMETA
        0x36: (126, 0x0000_0010),   // kVK_RightCommand → KEY_RIGHTMETA
    ]

    /// evdev BTN_* codes for NSEvent button numbers (0 = left …).
    public static func evdevButton(forMacButtonNumber number: Int) -> UInt32? {
        switch number {
        case 0: return 0x110    // BTN_LEFT
        case 1: return 0x111    // BTN_RIGHT
        case 2: return 0x112    // BTN_MIDDLE
        case 3: return 0x113    // BTN_SIDE
        case 4: return 0x114    // BTN_EXTRA
        default: return nil
        }
    }

    private static let table: [UInt16: UInt32] = [
        // Letters (kVK_ANSI_*)
        0x00: 30,  // A
        0x0B: 48,  // B
        0x08: 46,  // C
        0x02: 32,  // D
        0x0E: 18,  // E
        0x03: 33,  // F
        0x05: 34,  // G
        0x04: 35,  // H
        0x22: 23,  // I
        0x26: 36,  // J
        0x28: 37,  // K
        0x25: 38,  // L
        0x2E: 50,  // M
        0x2D: 49,  // N
        0x1F: 24,  // O
        0x23: 25,  // P
        0x0C: 16,  // Q
        0x0F: 19,  // R
        0x01: 31,  // S
        0x11: 20,  // T
        0x20: 22,  // U
        0x09: 47,  // V
        0x0D: 17,  // W
        0x07: 45,  // X
        0x10: 21,  // Y
        0x06: 44,  // Z
        // Digits (top row)
        0x12: 2,   // 1
        0x13: 3,   // 2
        0x14: 4,   // 3
        0x15: 5,   // 4
        0x17: 6,   // 5
        0x16: 7,   // 6
        0x1A: 8,   // 7
        0x1C: 9,   // 8
        0x19: 10,  // 9
        0x1D: 11,  // 0
        // Punctuation
        0x1B: 12,  // -      → KEY_MINUS
        0x18: 13,  // =      → KEY_EQUAL
        0x21: 26,  // [      → KEY_LEFTBRACE
        0x1E: 27,  // ]      → KEY_RIGHTBRACE
        0x2A: 43,  // \      → KEY_BACKSLASH
        0x29: 39,  // ;      → KEY_SEMICOLON
        0x27: 40,  // '      → KEY_APOSTROPHE
        0x2B: 51,  // ,      → KEY_COMMA
        0x2F: 52,  // .      → KEY_DOT
        0x2C: 53,  // /      → KEY_SLASH
        0x32: 41,  // `      → KEY_GRAVE
        // Whitespace / editing
        0x24: 28,   // Return         → KEY_ENTER
        0x30: 15,   // Tab            → KEY_TAB
        0x31: 57,   // Space          → KEY_SPACE
        0x33: 14,   // Delete         → KEY_BACKSPACE
        0x35: 1,    // Escape         → KEY_ESC
        0x75: 111,  // Forward Delete → KEY_DELETE
        0x72: 110,  // Help           → KEY_INSERT
        // Modifiers (also handled via flagsChanged; listed so a plain
        // keyDown on one still maps)
        0x38: 42, 0x3C: 54, 0x3B: 29, 0x3E: 97,
        0x3A: 56, 0x3D: 100, 0x37: 125, 0x36: 126,
        0x39: 58,   // Caps Lock → KEY_CAPSLOCK
        // Navigation
        0x73: 102,  // Home      → KEY_HOME
        0x77: 107,  // End       → KEY_END
        0x74: 104,  // Page Up   → KEY_PAGEUP
        0x79: 109,  // Page Down → KEY_PAGEDOWN
        0x7B: 105,  // Left      → KEY_LEFT
        0x7C: 106,  // Right     → KEY_RIGHT
        0x7D: 108,  // Down      → KEY_DOWN
        0x7E: 103,  // Up        → KEY_UP
        // Function keys
        0x7A: 59,   // F1
        0x78: 60,   // F2
        0x63: 61,   // F3
        0x76: 62,   // F4
        0x60: 63,   // F5
        0x61: 64,   // F6
        0x62: 65,   // F7
        0x64: 66,   // F8
        0x65: 67,   // F9
        0x6D: 68,   // F10
        0x67: 87,   // F11
        0x6F: 88,   // F12
        0x69: 183,  // F13
        0x6B: 184,  // F14
        0x71: 185,  // F15
        0x6A: 186,  // F16
        0x40: 187,  // F17
        0x4F: 188,  // F18
        0x50: 189,  // F19
        0x5A: 190,  // F20
        // Keypad
        0x52: 82,   // 0 → KEY_KP0
        0x53: 79,   // 1 → KEY_KP1
        0x54: 80,   // 2 → KEY_KP2
        0x55: 81,   // 3 → KEY_KP3
        0x56: 75,   // 4 → KEY_KP4
        0x57: 76,   // 5 → KEY_KP5
        0x58: 77,   // 6 → KEY_KP6
        0x59: 71,   // 7 → KEY_KP7
        0x5B: 72,   // 8 → KEY_KP8
        0x5C: 73,   // 9 → KEY_KP9
        0x43: 55,   // *     → KEY_KPASTERISK
        0x45: 78,   // +     → KEY_KPPLUS
        0x4E: 74,   // -     → KEY_KPMINUS
        0x41: 83,   // .     → KEY_KPDOT
        0x4B: 98,   // /     → KEY_KPSLASH
        0x4C: 96,   // Enter → KEY_KPENTER
        0x51: 117,  // =     → KEY_KPEQUAL
        0x47: 69,   // Clear → KEY_NUMLOCK
    ]
}
