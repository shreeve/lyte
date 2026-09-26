import AppKit
import LyteWire
import XCTest
@testable import Lyte

/// The capture's forwarding decisions: the host's held-key books stay
/// balanced whatever gates a release crosses, and ⌘ reaches the host only
/// as part of a host chord.
final class InputForwardingPolicyTests: XCTestCase {
    private let keyS: UInt32 = 31
    private let keyRight: UInt32 = 106
    private let leftMeta: UInt32 = 125
    private let leftShift: UInt32 = 42
    private let buttonLeft: UInt32 = 0x110

    private func down(_ code: UInt32) -> InputEvent.Body {
        .keyKeycode(keycode: code, pressed: true)
    }

    private func up(_ code: UInt32) -> InputEvent.Body {
        .keyKeycode(keycode: code, pressed: false)
    }

    // MARK: - Releases cross every gate

    func testRollingTypingIntoALocalChordReleasesTheKeyOnTheHost() {
        var policy = InputForwardingPolicy()
        // s↓ forwarded, then ⌘↓, then s↑ arrives with ⌘ held.
        XCTAssertEqual(policy.keyDown(keyS, isRepeat: false, commandHeld: false,
                                      isLocalShortcut: false).sends, [down(keyS)])
        XCTAssertEqual(policy.modifier(leftMeta, pressed: true), .swallow)
        let release = policy.keyUp(keyS, commandHeld: true)
        XCTAssertEqual(release.sends, [up(keyS)],
                       "a key the host holds must be released even under ⌘")
        XCTAssertTrue(release.consumed)
        // ⌘S itself is a local shortcut: AppKit's, and ⌘ never crosses.
        XCTAssertEqual(policy.keyDown(keyS, isRepeat: false, commandHeld: true,
                                      isLocalShortcut: true), .passThrough)
        XCTAssertEqual(policy.keyUp(keyS, commandHeld: true), .passThrough)
        XCTAssertEqual(policy.modifier(leftMeta, pressed: false), .swallow)
        XCTAssertTrue(policy.heldKeys.isEmpty)
    }

    func testButtonReleasedOverAnOverlayStillReleasesOnTheHost() {
        var policy = InputForwardingPolicy()
        XCTAssertEqual(policy.button(buttonLeft, pressed: true, onVideo: true, commandHeld: false).sends,
                       [.pointerButton(button: buttonLeft, pressed: true)])
        // The drag ends over the control strip (it reveals at the edge).
        let release = policy.button(buttonLeft, pressed: false, onVideo: false, commandHeld: false)
        XCTAssertEqual(release.sends,
                       [.pointerButton(button: buttonLeft, pressed: false)])
        XCTAssertTrue(release.consumed)
        XCTAssertTrue(policy.heldButtons.isEmpty)
    }

    func testOverlayClicksStayWithAppKitInBothDirections() {
        var policy = InputForwardingPolicy()
        XCTAssertEqual(policy.button(buttonLeft, pressed: true, onVideo: false, commandHeld: false),
                       .passThrough)
        // Pressed on the strip, released over the video: AppKit saw the
        // press, so it owns the release.
        XCTAssertEqual(policy.button(buttonLeft, pressed: false, onVideo: true, commandHeld: false),
                       .passThrough)
    }

    /// Holding D on the host (auto-repeating) and touching ⌘: the next
    /// repeat carries ⌘ and ⌘D is Disconnect. It must stay the host's.
    func testHostHeldKeysRepeatNeverFiresALocalShortcut() {
        var policy = InputForwardingPolicy()
        let keyD: UInt32 = 32
        XCTAssertEqual(policy.keyDown(keyD, isRepeat: false, commandHeld: false,
                                      isLocalShortcut: false).sends, [down(keyD)])
        XCTAssertEqual(policy.modifier(leftMeta, pressed: true), .swallow)
        XCTAssertEqual(policy.keyDown(keyD, isRepeat: true, commandHeld: true,
                                      isLocalShortcut: true), .swallow)
        XCTAssertEqual(policy.keyUp(keyD, commandHeld: true).sends, [up(keyD)])
        // A fresh ⌘D press is the human's local chord again.
        XCTAssertEqual(policy.keyDown(keyD, isRepeat: false, commandHeld: true,
                                      isLocalShortcut: true), .passThrough)
    }

    /// Shift held across a focus return: focus loss released it on the
    /// host, the next key's own flags say it is still down.
    func testModifierHeldAcrossFocusReturnIsPressedAgainFirst() {
        var policy = InputForwardingPolicy()
        XCTAssertEqual(policy.modifier(leftShift, pressed: true).sends,
                       [down(leftShift)])
        XCTAssertEqual(policy.releaseAll(), [up(leftShift)])
        XCTAssertEqual(
            policy.keyDown(keyS, isRepeat: false, commandHeld: false,
                           isLocalShortcut: false, modifiersDown: [leftShift]).sends,
            [down(leftShift), down(keyS)])
        XCTAssertEqual(policy.heldKeys, [leftShift, keyS])
    }

    /// A Shift release the app never saw (menu tracking) must not leave
    /// the host typing capitals.
    func testStaleModifierIsReleasedBeforeTheNextKeyOrClick() {
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftShift, pressed: true)
        XCTAssertEqual(
            policy.button(buttonLeft, pressed: true, onVideo: true,
                          commandHeld: false, modifiersDown: []).sends,
            [up(leftShift), .pointerButton(button: buttonLeft, pressed: true)])
        XCTAssertFalse(policy.heldKeys.contains(leftShift))
    }

    @MainActor
    func testEventFlagsNameTheModifierSides() {
        let rightShiftBit: UInt = 0x0000_0004
        let rightShift = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | rightShiftBit)
        XCTAssertEqual(LyteInputCapture.modifiersDown(rightShift), [54])
        XCTAssertEqual(LyteInputCapture.modifiersDown([.option]), [56],
                       "a flag without device bits counts as the left key")
        XCTAssertEqual(LyteInputCapture.modifiersDown([.command]), [],
                       "⌘ has its own resync")
    }

    /// macOS reports Caps Lock only as a lock-state flip; each flip is one
    /// full press on the host, never a held key the host could repeat.
    func testCapsLockFlipIsOneTapOnTheHost() {
        var policy = InputForwardingPolicy()
        let capsLock: UInt32 = 58
        for on in [true, false] {
            let verdict = policy.capsLockChanged(on: on)
            XCTAssertEqual(verdict.sends, [down(capsLock), up(capsLock)])
            XCTAssertTrue(verdict.consumed)
            XCTAssertTrue(policy.heldKeys.isEmpty)
        }
    }

    /// Caps Lock already on when the stream starts: the host's is off, and
    /// flipping on every lock event would keep the two inverted for good.
    /// The first key syncs the host; later lock events follow the state.
    func testCapsLockOnAtStreamStartIsSyncedBeforeTheFirstKey() {
        var policy = InputForwardingPolicy()
        let capsLock: UInt32 = 58
        XCTAssertEqual(
            policy.keyDown(keyS, isRepeat: false, commandHeld: false,
                           isLocalShortcut: false, capsLockOn: true).sends,
            [down(capsLock), up(capsLock), down(keyS)])
        XCTAssertEqual(policy.keyUp(keyS, commandHeld: false).sends, [up(keyS)])
        XCTAssertEqual(
            policy.keyDown(keyS, isRepeat: false, commandHeld: false,
                           isLocalShortcut: false, capsLockOn: true).sends,
            [down(keyS)], "an agreeing state taps nothing")
        XCTAssertEqual(policy.capsLockChanged(on: false).sends,
                       [down(capsLock), up(capsLock)])
        XCTAssertEqual(policy.capsLockChanged(on: false).sends, [],
                       "a lock event the host already matches taps nothing")
    }

    /// The ISO key-type read happens per event; if it changes between a
    /// key's press and release (a keyboard swap mid-hold), the release
    /// maps to another code and the pressed one would stay down.
    func testAReleaseGoesOutAsTheCodeItsPressDid() {
        var policy = InputForwardingPolicy()
        let grave: UInt32 = 41
        let key102nd: UInt32 = 86
        let section: UInt16 = 0x0A
        XCTAssertEqual(
            policy.keyDown(grave, macKeyCode: section, isRepeat: false,
                           commandHeld: false, isLocalShortcut: false).sends,
            [down(grave)])
        XCTAssertEqual(
            policy.keyDown(key102nd, macKeyCode: section, isRepeat: true,
                           commandHeld: false, isLocalShortcut: false),
            .swallow, "the held key's repeat stays the host's")
        XCTAssertEqual(
            policy.keyUp(key102nd, macKeyCode: section, commandHeld: false)
                .sends, [up(grave)])
        XCTAssertTrue(policy.heldKeys.isEmpty)
        XCTAssertTrue(policy.pressedAs.isEmpty)
    }

    // MARK: - ⌘ as Super, only for host chords

    func testLocalOnlyChordNeverTapsSuperOnTheHost() {
        var policy = InputForwardingPolicy()
        XCTAssertEqual(policy.modifier(leftMeta, pressed: true), .swallow)
        XCTAssertEqual(policy.keyDown(15, isRepeat: false, commandHeld: true,
                                      isLocalShortcut: true), .passThrough)
        XCTAssertEqual(policy.keyUp(15, commandHeld: true), .passThrough)
        XCTAssertEqual(policy.modifier(leftMeta, pressed: false), .swallow)
        XCTAssertTrue(policy.heldKeys.isEmpty)
        XCTAssertTrue(policy.pendingCommandKeys.isEmpty)
    }

    func testLoneCommandTapSendsNothing() {
        var policy = InputForwardingPolicy()
        XCTAssertEqual(policy.modifier(leftMeta, pressed: true).sends, [])
        XCTAssertEqual(policy.modifier(leftMeta, pressed: false).sends, [])
    }

    func testHostChordSendsSuperFirstThenTheKey() {
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftMeta, pressed: true)
        let chord = policy.keyDown(keyRight, isRepeat: false, commandHeld: true,
                                   isLocalShortcut: false)
        XCTAssertEqual(chord.sends, [down(leftMeta), down(keyRight)])
        XCTAssertTrue(chord.consumed)
        XCTAssertEqual(policy.keyUp(keyRight, commandHeld: true).sends, [up(keyRight)])
        XCTAssertEqual(policy.modifier(leftMeta, pressed: false).sends, [up(leftMeta)])
        XCTAssertTrue(policy.heldKeys.isEmpty)
    }

    func testCommandReleasedWhileTheChordKeyIsStillHeld() {
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftMeta, pressed: true)
        _ = policy.keyDown(keyRight, isRepeat: false, commandHeld: true,
                           isLocalShortcut: false)
        XCTAssertEqual(policy.modifier(leftMeta, pressed: false).sends, [up(leftMeta)])
        XCTAssertEqual(policy.heldKeys, [keyRight])
        XCTAssertEqual(policy.keyUp(keyRight, commandHeld: false).sends, [up(keyRight)])
        XCTAssertTrue(policy.heldKeys.isEmpty)
    }

    func testSuperClickFlushesCommandBeforeTheButton() {
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftMeta, pressed: true)
        XCTAssertEqual(policy.button(buttonLeft, pressed: true, onVideo: true, commandHeld: true).sends,
                       [down(leftMeta), .pointerButton(button: buttonLeft, pressed: true)])
    }

    func testOtherModifiersForwardImmediately() {
        var policy = InputForwardingPolicy()
        XCTAssertEqual(policy.modifier(leftShift, pressed: true).sends, [down(leftShift)])
        XCTAssertEqual(policy.modifier(leftShift, pressed: false).sends, [up(leftShift)])
    }

    // MARK: - ⌘ with a letter is Control

    private let keyC: UInt32 = 46
    private let keyZ: UInt32 = 44
    private let leftCtrl: UInt32 = 29

    func testCommandLetterReachesTheHostAsControlNeverSuper() {
        var policy = InputForwardingPolicy()
        XCTAssertEqual(policy.modifier(leftMeta, pressed: true), .swallow)
        let chord = policy.keyDown(keyC, isRepeat: false, commandHeld: true,
                                   isLocalShortcut: false, typesLetter: true, modifiersDown: [])
        XCTAssertEqual(chord.sends, [down(leftCtrl), down(keyC)])
        XCTAssertTrue(chord.consumed)
        XCTAssertEqual(policy.keyDown(keyC, isRepeat: true, commandHeld: true,
                                      isLocalShortcut: false), .swallow)
        XCTAssertEqual(policy.keyUp(keyC, commandHeld: true).sends,
                       [up(keyC), up(leftCtrl)])
        XCTAssertEqual(policy.modifier(leftMeta, pressed: false).sends, [])
        XCTAssertTrue(policy.heldKeys.isEmpty)
    }

    func testOtherModifiersRideTheControlChord() {
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftMeta, pressed: true)
        _ = policy.modifier(leftShift, pressed: true)
        XCTAssertEqual(
            policy.keyDown(keyZ, isRepeat: false, commandHeld: true,
                           isLocalShortcut: false, typesLetter: true, modifiersDown: [leftShift]).sends,
            [down(leftCtrl), down(keyZ)])
        XCTAssertEqual(policy.heldKeys, [leftShift, keyZ])
    }

    func testAHeldControlKeyNeedsNoSecondControl() {
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftMeta, pressed: true)
        XCTAssertEqual(
            policy.keyDown(keyC, isRepeat: false, commandHeld: true,
                           isLocalShortcut: false, typesLetter: true, modifiersDown: [leftCtrl]).sends,
            [down(leftCtrl), down(keyC)])
        XCTAssertEqual(policy.keyUp(keyC, commandHeld: true).sends, [up(keyC)])
        XCTAssertEqual(policy.heldKeys, [leftCtrl])
    }

    func testControlIsReleasedWithTheLastLetterWhateverCommandDid() {
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftMeta, pressed: true)
        _ = policy.keyDown(keyC, isRepeat: false, commandHeld: true,
                           isLocalShortcut: false, typesLetter: true)
        XCTAssertEqual(policy.keyDown(keyZ, isRepeat: false, commandHeld: true,
                                      isLocalShortcut: false, typesLetter: true).sends, [down(keyZ)])
        XCTAssertEqual(policy.modifier(leftMeta, pressed: false).sends, [])
        XCTAssertEqual(policy.keyUp(keyC, commandHeld: false).sends, [up(keyC)])
        XCTAssertEqual(policy.keyUp(keyZ, commandHeld: false).sends,
                       [up(keyZ), up(leftCtrl)])
        XCTAssertTrue(policy.heldKeys.isEmpty)
    }

    func testFocusLossMidControlChordReleasesControl() {
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftMeta, pressed: true)
        _ = policy.keyDown(keyC, isRepeat: false, commandHeld: true,
                           isLocalShortcut: false, typesLetter: true)
        XCTAssertEqual(policy.releaseAll(), [up(keyC), up(leftCtrl)])
        XCTAssertTrue(policy.controlChordKeys.isEmpty)
    }

    /// ⌘→ forwarded Super; ⌘C in the same hold takes it back first.
    func testASuperAlreadyForwardedIsTakenBackForAControlChord() {
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftMeta, pressed: true)
        _ = policy.keyDown(keyRight, isRepeat: false, commandHeld: true,
                           isLocalShortcut: false)
        _ = policy.keyUp(keyRight, commandHeld: true)
        XCTAssertEqual(
            policy.keyDown(keyC, isRepeat: false, commandHeld: true,
                           isLocalShortcut: false, typesLetter: true).sends,
            [up(leftMeta), down(leftCtrl), down(keyC)])
        XCTAssertEqual(policy.pendingCommandKeys, [leftMeta])
    }

    /// ⌘ comes up while S is still down (rollover): the Control the chord
    /// added must not ride the next key or click out.
    func testTheChordsControlNeverRidesALaterKeyOrClick() {
        let keyH: UInt32 = 35
        var typing = InputForwardingPolicy()
        _ = typing.modifier(leftMeta, pressed: true)
        _ = typing.keyDown(keyS, isRepeat: false, commandHeld: true,
                           isLocalShortcut: false, typesLetter: true)
        _ = typing.modifier(leftMeta, pressed: false)
        XCTAssertEqual(typing.keyDown(keyH, isRepeat: false, commandHeld: false,
                                      isLocalShortcut: false).sends,
                       [up(leftCtrl), down(keyH)])
        XCTAssertEqual(typing.keyUp(keyS, commandHeld: false).sends, [up(keyS)])
        XCTAssertEqual(typing.keyUp(keyH, commandHeld: false).sends, [up(keyH)])
        XCTAssertTrue(typing.heldKeys.isEmpty)

        var clicking = InputForwardingPolicy()
        _ = clicking.modifier(leftMeta, pressed: true)
        _ = clicking.keyDown(keyS, isRepeat: false, commandHeld: true,
                             isLocalShortcut: false, typesLetter: true)
        _ = clicking.modifier(leftMeta, pressed: false)
        XCTAssertEqual(
            clicking.button(buttonLeft, pressed: true, onVideo: true,
                            commandHeld: false).sends,
            [up(leftCtrl), .pointerButton(button: buttonLeft, pressed: true)])
    }

    /// A physical Ctrl pressed mid-chord takes over the Control the chord
    /// added: one press and one release on the host.
    func testAControlPressedMidChordTakesOverTheChordsControl() {
        var policy = InputForwardingPolicy()
        var sends: [InputEvent.Body] = []
        _ = policy.modifier(leftMeta, pressed: true)
        sends += policy.keyDown(keyC, isRepeat: false, commandHeld: true,
                                isLocalShortcut: false, typesLetter: true).sends
        sends += policy.modifier(leftCtrl, pressed: true).sends
        sends += policy.modifier(leftCtrl, pressed: false).sends
        sends += policy.keyUp(keyC, commandHeld: true).sends
        XCTAssertEqual(sends, [down(leftCtrl), down(keyC), up(leftCtrl), up(keyC)])
        XCTAssertTrue(policy.heldKeys.isEmpty)
        XCTAssertTrue(policy.controlChordKeys.isEmpty)
    }

    /// The typed letter, not the key's QWERTY position, makes the Control
    /// chord: Dvorak types S on the semicolon key and ' on Q's.
    func testTheTypedLetterNotTheKeyPositionMakesAControlChord() {
        let semicolon: UInt32 = 39
        let keyQ: UInt32 = 16
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftMeta, pressed: true)
        XCTAssertEqual(
            policy.keyDown(semicolon, isRepeat: false, commandHeld: true,
                           isLocalShortcut: false, typesLetter: true).sends,
            [down(leftCtrl), down(semicolon)])
        _ = policy.keyUp(semicolon, commandHeld: true)
        XCTAssertEqual(
            policy.keyDown(keyQ, isRepeat: false, commandHeld: true,
                           isLocalShortcut: false, typesLetter: false).sends,
            [down(leftMeta), down(keyQ)])
    }

    func testAnAppOwnedLetterChordStaysLocal() {
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftMeta, pressed: true)
        XCTAssertEqual(policy.keyDown(keyC, isRepeat: false, commandHeld: true,
                                      isLocalShortcut: true), .passThrough)
        XCTAssertTrue(policy.heldKeys.isEmpty)
    }

    /// Only enabled, visible, non-Edit menu items keep a ⌘ chord local.
    @MainActor
    func testOnlyLiveAppCommandsClaimAChord() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ key: String, _ action: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(
                title: key, action: action.map(NSSelectorFromString),
                keyEquivalent: key)
            menu.addItem(item)
            return item
        }
        _ = item("w")
        item("d").isEnabled = false
        item("r").isHidden = true
        _ = item("c", "copy:")
        _ = item("z", "undo:")
        func answers(_ key: String) -> Bool {
            LyteInputCapture.menuAnswers(menu, characters: key, modifiers: .command)
        }
        XCTAssertTrue(answers("w"))
        XCTAssertFalse(answers("d"), "a disabled item answers nothing")
        XCTAssertFalse(answers("r"), "a hidden item answers nothing")
        XCTAssertFalse(answers("c"), "Edit's copy is the host's in a stream")
        XCTAssertFalse(answers("z"))
    }

    /// The main menu enables its items lazily, by validation; a chord is
    /// judged by the item's state now, not at the last validation pass.
    @MainActor
    func testAChordIsJudgedByTheItemsCurrentValidation() {
        _ = NSApplication.shared    // menu validation runs through NSApp
        let menu = NSMenu()
        let validator = MenuValidator()
        let item = NSMenuItem(
            title: "Disconnect", action: #selector(MenuValidator.act(_:)),
            keyEquivalent: "d")
        item.target = validator
        menu.addItem(item)
        func answers() -> Bool {
            LyteInputCapture.menuAnswers(menu, characters: "d", modifiers: .command)
        }
        XCTAssertFalse(answers(), "a command that validates disabled answers nothing")
        validator.enabled = true
        XCTAssertTrue(answers())
        validator.enabled = false
        XCTAssertFalse(answers())
    }

    // MARK: - A ⌘ release AppKit never delivered

    // Menu tracking and title-bar drags consume events before the local
    // monitor, so a ⌘ release can go missing. Each event's own flags say
    // whether ⌘ is really down.

    func testSwallowedCommandReleaseNeverRidesTheNextKey() {
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftMeta, pressed: true)
        XCTAssertEqual(policy.keyDown(keyS, isRepeat: false, commandHeld: false,
                                      isLocalShortcut: false).sends, [down(keyS)])
        XCTAssertEqual(policy.keyUp(keyS, commandHeld: false).sends, [up(keyS)])
        XCTAssertTrue(policy.heldKeys.isEmpty)
        XCTAssertTrue(policy.pendingCommandKeys.isEmpty)
    }

    func testSwallowedCommandReleaseNeverRidesTheNextClick() {
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftMeta, pressed: true)
        XCTAssertEqual(
            policy.button(buttonLeft, pressed: true, onVideo: true,
                          commandHeld: false).sends,
            [.pointerButton(button: buttonLeft, pressed: true)])
        XCTAssertTrue(policy.pendingCommandKeys.isEmpty)
    }

    func testForwardedCommandWithASwallowedReleaseIsReleasedByTheNextKey() {
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftMeta, pressed: true)
        _ = policy.keyDown(keyRight, isRepeat: false, commandHeld: true,
                           isLocalShortcut: false)
        _ = policy.keyUp(keyRight, commandHeld: true)
        XCTAssertEqual(policy.keyDown(keyS, isRepeat: false, commandHeld: false,
                                      isLocalShortcut: false).sends,
                       [up(leftMeta), down(keyS)])
        XCTAssertEqual(policy.heldKeys, [keyS])
    }

    func testCommandTapReleasesAForwardedCommandWhoseReleaseWasSwallowed() {
        var policy = InputForwardingPolicy()
        _ = policy.modifier(leftMeta, pressed: true)
        _ = policy.keyDown(keyRight, isRepeat: false, commandHeld: true,
                           isLocalShortcut: false)
        _ = policy.keyUp(keyRight, commandHeld: true)
        // ⌘↑ lost; the user taps ⌘ again.
        XCTAssertEqual(policy.modifier(leftMeta, pressed: true), .swallow)
        XCTAssertEqual(policy.modifier(leftMeta, pressed: false).sends, [up(leftMeta)])
        XCTAssertTrue(policy.heldKeys.isEmpty)
        XCTAssertTrue(policy.pendingCommandKeys.isEmpty)
    }

    // MARK: - Repeats, unmapped keys, focus loss

    func testRepeatsNeverCrossAndUnmappedKeysStayLocal() {
        var policy = InputForwardingPolicy()
        _ = policy.keyDown(keyS, isRepeat: false, commandHeld: false,
                           isLocalShortcut: false)
        XCTAssertEqual(policy.keyDown(keyS, isRepeat: true, commandHeld: false,
                                      isLocalShortcut: false), .swallow)
        XCTAssertEqual(policy.keyDown(nil, isRepeat: false, commandHeld: false,
                                      isLocalShortcut: false), .passThrough)
        XCTAssertEqual(policy.keyUp(nil, commandHeld: false), .passThrough)
        // An unmatched release has no host state to balance.
        XCTAssertEqual(policy.keyUp(keyRight, commandHeld: false), .swallow)
    }

    func testFocusLossReleasesHeldStateAndForgetsPendingCommand() {
        var policy = InputForwardingPolicy()
        _ = policy.keyDown(keyS, isRepeat: false, commandHeld: false,
                           isLocalShortcut: false)
        _ = policy.button(buttonLeft, pressed: true, onVideo: true, commandHeld: false)
        _ = policy.modifier(leftMeta, pressed: true)
        XCTAssertEqual(policy.releaseAll(),
                       [up(keyS), .pointerButton(button: buttonLeft, pressed: false)])
        XCTAssertTrue(policy.heldKeys.isEmpty)
        XCTAssertTrue(policy.heldButtons.isEmpty)
        XCTAssertTrue(policy.pendingCommandKeys.isEmpty)
        // ⌘ comes back up after focus returns: nothing to say.
        XCTAssertEqual(policy.modifier(leftMeta, pressed: false).sends, [])
    }
}

@MainActor
private final class MenuValidator: NSObject, NSMenuItemValidation {
    var enabled = false

    @objc func act(_ sender: Any?) {}

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { enabled }
}
