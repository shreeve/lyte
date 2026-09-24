import LyteClientCore
import XCTest

/// The keys beyond ANSI speak the same evdev positions the browser client
/// sends for them (Browser/Page/interaction.js), so a host's XKB layout
/// sees one keyboard whichever client types.
final class MacEvdevKeyMapTests: XCTestCase {
    private func evdev(_ keyCode: UInt16, iso: Bool = false) -> UInt32? {
        MacEvdevKeyMap.evdevKeycode(forMacKeyCode: keyCode, isoKeyboard: iso)
    }

    func testIsoAndJisExtrasReachTheHost() {
        XCTAssertEqual(evdev(0x0A), 86)    // kVK_ISO_Section → KEY_102ND (IntlBackslash)
        XCTAssertEqual(evdev(0x5D), 124)   // kVK_JIS_Yen → KEY_YEN (IntlYen)
        XCTAssertEqual(evdev(0x5E), 89)    // kVK_JIS_Underscore → KEY_RO (IntlRo)
        XCTAssertEqual(evdev(0x5F), 121)   // kVK_JIS_KeypadComma → KEY_KPCOMMA (NumpadComma)
        XCTAssertEqual(evdev(0x66), 94)    // kVK_JIS_Eisu → KEY_MUHENKAN (left of space)
        XCTAssertEqual(evdev(0x68), 92)    // kVK_JIS_Kana → KEY_HENKAN (right of space)
        XCTAssertEqual(evdev(0x6E), 127)   // context menu → KEY_COMPOSE (ContextMenu)
    }

    /// Apple ISO keyboards report the key left of 1 and the key beside
    /// left Shift with each other's codes; positions win.
    func testIsoKeyboardsSwapSectionAndGrave() {
        XCTAssertEqual(evdev(0x32), 41)            // ANSI: ` left of 1 → KEY_GRAVE
        XCTAssertEqual(evdev(0x0A, iso: true), 41) // ISO: § left of 1 → KEY_GRAVE
        XCTAssertEqual(evdev(0x32, iso: true), 86) // ISO: beside left Shift → KEY_102ND
        XCTAssertEqual(evdev(0x00, iso: true), 30, "other keys never move")
        XCTAssertEqual(
            MacEvdevKeyMap.evdevKeycode(forMacKeyCode: 0x32), evdev(0x32),
            "the unqualified lookup is the ANSI one")
    }

    func testCapsLockHasItsEvdevCode() {
        XCTAssertEqual(evdev(MacEvdevKeyMap.capsLockKeyCode), 58)
        XCTAssertNil(MacEvdevKeyMap.modifierKeys[MacEvdevKeyMap.capsLockKeyCode],
                     "a lock toggles; it is never a held modifier")
    }
}
