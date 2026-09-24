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
