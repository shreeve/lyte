import AppKit
import XCTest
@testable import Lyte

/// Secure event input is held exactly while the preference is on and the
/// stream window is key, and every enable is paired with one disable.
@MainActor
final class SecureKeyboardEntryTests: XCTestCase {
    func testSecureInputFollowsKeyFocusAndThePreferenceInBalance() throws {
        let suite = "lyte.tests.secure-input.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.titled], backing: .buffered, defer: true)
        var calls: [Bool] = []
        let capture = LyteInputCapture(
            view: NSView(), window: window, videoSize: { .zero },
            send: { _ in }, defaults: defaults,
            setSecureInput: { calls.append($0) })
        let center = NotificationCenter.default
        func focus(_ key: Bool) {
            center.post(
                name: key ? NSWindow.didBecomeKeyNotification
                    : NSWindow.didResignKeyNotification,
                object: window)
        }
        func prefer(_ on: Bool) {
            defaults.set(on, forKey: LyteInputCapture.secureKeyboardEntryKey)
        }

        capture.start()
        focus(true)
        XCTAssertEqual(calls, [], "off by default")
        prefer(true)
        focus(false)
        focus(true)
        focus(true)
        prefer(false)
        prefer(true)
        capture.stop()
        focus(true)
        prefer(false)
        XCTAssertEqual(calls, [true, false, true, false, true, false])
    }
}
