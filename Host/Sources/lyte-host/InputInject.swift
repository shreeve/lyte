// Input injection: wire events → the host's desktop through the uinput C
// leaf (CInputUinput) — three virtual evdev devices (keyboard, relative
// mouse, absolute tablet) under the seat-user ACL that the
// 60-lyte-uinput.rules udev rule grants (setup-host.sh installs it).
// Kernel injection is compositor-agnostic and costs one write(2) per
// event.

import Foundation
import HostCore
import HostWire
import LyteIO
import LyteWire

#if os(Linux)
import CInputUinput

/// One injected event sink. `inject` throws loudly — the caller counts
/// and reports; a failed injection never unwinds the session.
protocol InputInjector: AnyObject {
    var name: String { get }
    func inject(_ event: InputEvent) throws
    /// The recorded monitor's pixel size, once capture reads it (the
    /// uinput tablet scales absolute moves against it).
    func noteMonitorExtent(width: UInt32, height: UInt32)
    /// Releases what `scope` covers of the keys and buttons still held
    /// (see HeldInputBook) and returns how many: the client cannot send
    /// their releases (its path went silent, or the session ended). The
    /// devices stay up.
    @discardableResult
    func releaseHeld(_ scope: HeldInputBook.Scope) -> Int
    func stop()
}

/// The uinput injector. Pixel scroll deltas convert to
/// the kernel's v120 hi-res units at 15 px per detent (the libinput
/// convention for smooth sources).
final class UinputInjector: InputInjector {
    let name = "uinput"

    private let handle: OpaquePointer
    static let pixelsPerDetent = 15.0
    /// Every key/button currently held down. inject() and a session's
    /// releaseHeld() (input silence, session close) run under
    /// SessionWire's session lock; the end-of-session releaseHeld() and
    /// stop() run on main after the session's threads have stopped —
    /// never concurrently.
    private var held = HeldInputBook()
    private var stopped = false

    init() throws {
        var err = [CChar](repeating: 0, count: 256)
        guard let handle = lyte_uinput_open(&err, err.count) else {
            throw HostError("uinput open failed: \(String(cBuffer: err))")
        }
        self.handle = handle
        // Freshly created evdev devices need a moment before
        // libinput/Mutter picks them up; events written earlier are
        // silently dropped. One settle at open, never per event.
        usleep(150_000)
    }

    deinit {
        stop()
        lyte_uinput_free(handle)
    }

    func inject(_ event: InputEvent) throws {
        guard let call = Self.leafCall(for: event.body) else {
            throw HostError("""
                uinput inject refused: a non-finite coordinate or an \
                undeclared key code
                """)
        }
        var err = [CChar](repeating: 0, count: 256)
        let rc: Int32
        switch call {
        case .key(let code, let pressed):
            rc = lyte_uinput_key(
                handle, code, pressed ? 1 : 0, &err, err.count)
            if rc == 0 {
                if case .pointerButton = event.body {
                    held.noteButton(code, pressed: pressed)
                } else {
                    held.noteKey(code, pressed: pressed)
                }
            }
        case .moveAbsolute(let x, let y):
            rc = lyte_uinput_move_abs(handle, x, y, &err, err.count)
        case .moveRelative(let dx, let dy):
            rc = lyte_uinput_move_rel(handle, dx, dy, &err, err.count)
        case .scroll(let v120X, let v120Y):
            rc = lyte_uinput_scroll(handle, v120X, v120Y, &err, err.count)
        }
        guard rc == 0 else {
            throw HostError("uinput inject failed: \(String(cBuffer: err))")
        }
    }

    /// The key and button codes the virtual devices declare (uinput.c):
    /// only these reach the leaf, so the held-input book stays bounded.
    static let keyboardCodes: ClosedRange<UInt32> = 1...255
    static let buttonCodes: ClosedRange<UInt32> = 0x110...0x117

    /// One leaf call per wire event: every client f64 is finite by the
    /// time it leaves here, every integer is saturated, and every code is
    /// one a device declares. Nil refuses the event.
    static func leafCall(for body: InputEvent.Body) -> UinputCall? {
        switch body {
        case .keyKeycode(let code, let pressed):
            guard keyboardCodes.contains(code) else { return nil }
            return .key(code, pressed: pressed)
        case .pointerButton(let code, let pressed):
            guard buttonCodes.contains(code) else { return nil }
            return .key(code, pressed: pressed)
        case .pointerMotionAbsolute(let x, let y):
            guard x.isFinite, y.isFinite else { return nil }
            return .moveAbsolute(x, y)
        case .pointerMotionRelative(let dx, let dy):
            guard let x = InputCoordinate.saturated(
                      dx, limit: InputCoordinate.relativeLimit),
                  let y = InputCoordinate.saturated(
                      dy, limit: InputCoordinate.relativeLimit)
            else { return nil }
            return .moveRelative(x, y)
        case .pointerAxis(let dx, let dy, _):
            let v120PerPixel = 120 / pixelsPerDetent
            guard let x = InputCoordinate.saturated(
                      dx * v120PerPixel, limit: InputCoordinate.scrollLimit),
                  let y = InputCoordinate.saturated(
                      dy * v120PerPixel, limit: InputCoordinate.scrollLimit)
            else { return nil }
            return .scroll(x, y)
        }
    }

    func noteMonitorExtent(width: UInt32, height: UInt32) {
        var err = [CChar](repeating: 0, count: 256)
        if lyte_uinput_set_extent(handle, width, height,
                                  &err, err.count) != 0 {
            print("input: uinput extent refused: \(String(cBuffer: err))")
        }
    }

    @discardableResult
    func releaseHeld(_ scope: HeldInputBook.Scope) -> Int {
        guard !stopped else { return 0 }
        let released = held.takeReleases(scope)
        var err = [CChar](repeating: 0, count: 256)
        for code in released {
            _ = lyte_uinput_key(handle, code, 0, &err, err.count)
        }
        return released.count
    }

    func stop() {
        let released = releaseHeld(.everything)
        if released > 0 { print("input: released \(released) held key(s)") }
        stopped = true
    }
}

/// The `--input` policy: uinput is the only injector; a refused
/// /dev/uinput is a LOUD off (the udev rule in setup-host.sh is the
/// fix), never a silent one.
func makeInputInjector(_ choice: InputBackendChoice) -> InputInjector? {
    switch choice {
    case .off:
        return nil
    case .auto, .uinput:
        do {
            return try UinputInjector()
        } catch {
            print("""
                input: uinput unavailable (\(error)) — injection \
                OFF (install the udev rule: setup-host.sh)
                """)
            return nil
        }
    }
}
#endif

/// What one wire event asks of the uinput leaf, in the leaf's units.
enum UinputCall: Equatable {
    case key(UInt32, pressed: Bool)
    /// Monitor pixels; the leaf scales and clamps against the extent.
    case moveAbsolute(Double, Double)
    case moveRelative(Int32, Int32)
    /// v120 units (120 = one detent).
    case scroll(Int32, Int32)
}

/// Client pointer and axis values are untrusted f64s: the codec decodes
/// any bit pattern. Every integer conversion of one goes through
/// `saturated`, so no client value reaches a trapping conversion or an
/// undefined C cast.
enum InputCoordinate {
    /// Relative motion per event, pixels.
    static let relativeLimit: Int32 = 32_767
    /// Scroll per event, v120 units: 256 detents.
    static let scrollLimit: Int32 = 120 * 256
    /// A screen position, pixels — beyond any monitor.
    static let pixelLimit: Int32 = 32_767

    /// `value` rounded to the nearest integer and clamped to ±`limit`;
    /// nil when it is NaN or infinite.
    static func saturated(_ value: Double, limit: Int32) -> Int32? {
        guard value.isFinite else { return nil }
        let bound = Double(limit)
        return Int32(min(max(value.rounded(), -bound), bound))
    }

    /// A pointer position in whole pixels, for the cursor-hotspot
    /// derivation; nil for a non-finite coordinate.
    static func pixel(x: Double, y: Double) -> CursorHotspot.Point? {
        guard let px = saturated(x, limit: pixelLimit),
              let py = saturated(y, limit: pixelLimit) else { return nil }
        return CursorHotspot.Point(x: Int(px), y: Int(py))
    }
}

enum InputBackendChoice: String {
    case auto
    case uinput
    case off
}
