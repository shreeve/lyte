// Input injection (HS-13 → E2): wire events → the host's desktop.
//
// PRIMARY — the uinput C leaf (CInputUinput), E2 of the direct-eye
// plan: three virtual evdev devices (keyboard, relative mouse,
// absolute tablet) under the seat-user ACL the 60-lyte-uinput.rules
// udev rule grants (uaccess tag; setup-host.sh installs it). Kernel
// injection is compositor-agnostic — it works under GNOME today and
// under whatever compositor (or no compositor) Lyte OS runs
// tomorrow — and it costs one write(2) per event where the retired
// leaf paid a blocking D-Bus round-trip on the wire-drain thread.
//
// RETIRED (E2, 2026-08-03) — the Mutter RemoteDesktop injector
// (org.gnome.Mutter.RemoteDesktop Notify* calls; the CP-5 verdict's
// primary). Recover it from git history if archaeology calls. The
// clipboard's OWN RemoteDesktop session (ClipboardLeaf.swift) is
// deliberately untouched — it was always an independent session on
// its own bus connection, and its Wayland-helper replacement is a
// separate filed follow-up.
//
// The sanctioned xdg-desktop-portal RemoteDesktop path was never
// here: its combined Start auto-denies headless on this GNOME
// (CP-5 Q1) — a dead end, deliberately not retried.

import Foundation
import HostWire
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
    func stop()
}

/// The uinput injector (E2 primary). Pixel scroll deltas convert to
/// the kernel's v120 hi-res units at 15 px per detent (the libinput
/// convention for smooth sources).
final class UinputInjector: InputInjector {
    let name = "uinput"

    private let handle: OpaquePointer
    private static let pixelsPerDetent = 15.0
    /// Every key/button currently held down, by evdev code. E2's
    /// release-all law: the retired Mutter session released latched
    /// keys when it closed; a kernel device has no such janitor, so
    /// the injector is its own — stop() releases everything still
    /// held (the ⌘Tab latch, a click mid-teardown) before the
    /// devices are destroyed. inject() and stop() both run on the
    /// wire-drain thread; no lock needed.
    private var heldCodes: Set<UInt32> = []
    private var stopped = false

    init() throws {
        var err = [CChar](repeating: 0, count: 256)
        guard let handle = lyte_uinput_open(&err, err.count) else {
            throw HostError("uinput open failed: \(errString(err))")
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
        var err = [CChar](repeating: 0, count: 256)
        let rc: Int32
        switch event.body {
        case .keyKeycode(let code, let pressed),
             .pointerButton(let code, let pressed):
            rc = lyte_uinput_key(
                handle, code, pressed ? 1 : 0, &err, err.count)
            if rc == 0 {
                if pressed { heldCodes.insert(code) }
                else { heldCodes.remove(code) }
            }
        case .pointerMotionAbsolute(let x, let y):
            rc = lyte_uinput_move_abs(handle, x, y, &err, err.count)
        case .pointerMotionRelative(let dx, let dy):
            rc = lyte_uinput_move_rel(
                handle, Int32(dx.rounded()), Int32(dy.rounded()),
                &err, err.count)
        case .pointerAxis(let dx, let dy, _):
            rc = lyte_uinput_scroll(
                handle,
                Int32((dx / Self.pixelsPerDetent * 120).rounded()),
                Int32((dy / Self.pixelsPerDetent * 120).rounded()),
                &err, err.count)
        }
        guard rc == 0 else {
            throw HostError("uinput inject failed: \(errString(err))")
        }
    }

    func noteMonitorExtent(width: UInt32, height: UInt32) {
        var err = [CChar](repeating: 0, count: 256)
        if lyte_uinput_set_extent(handle, width, height,
                                  &err, err.count) != 0 {
            print("input: uinput extent refused: \(errString(err))")
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        guard !heldCodes.isEmpty else { return }
        var err = [CChar](repeating: 0, count: 256)
        for code in heldCodes {
            _ = lyte_uinput_key(handle, code, 0, &err, err.count)
        }
        print("input: released \(heldCodes.count) held key(s) at stop")
        heldCodes.removeAll()
    }
}

/// The `--input` policy (E2): uinput is primary and sole; a refused
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
            print("input: uinput unavailable (\(error)) — injection "
                + "OFF (install the udev rule: setup-host.sh)")
            return nil
        }
    }
}
#endif

enum InputBackendChoice: String {
    case auto
    case uinput
    case off
}
