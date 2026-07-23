// Input injection (HS-13): wire events → the host's desktop session.
//
// PRIMARY — Mutter's internal org.gnome.Mutter.RemoteDesktop (the CP-5
// verdict): headless over ssh, no consent dialog, no token, absolute
// pointer coordinates in monitor space. The session shape is the spike's,
// productionized: CreateSession → a ScreenCast session linked by
// remote-desktop-session-id → RecordMonitor (its stream object is the
// coordinate anchor NotifyPointerMotionAbsolute addresses; the PipeWire
// node is never consumed — video stays on the portal capture path) →
// ONE RemoteDesktop.Session.Start brings up both legs → Notify* calls.
//
// SECONDARY — the uinput C leaf (CInputUinput): three virtual evdev
// devices under the seat-user ACL Sunshine's udev rule grants (CP-5 Q5,
// proven unprivileged). Selected automatically when the Mutter session
// cannot be established, or explicitly via --input uinput.
//
// The sanctioned xdg-desktop-portal RemoteDesktop path is NOT here: its
// combined Start auto-denies headless on this GNOME (CP-5 Q1) — a dead
// end, deliberately not retried.

import Foundation
import HostWire
import LyteWire

#if os(Linux)
import CDBus
import CInputUinput

private let dTypeDouble: Int32 = 100 // 'd'
private let dTypeInt32: Int32 = 105  // 'i'

/// One injected event sink. `inject` throws loudly — the caller counts
/// and reports; a failed injection never unwinds the session.
protocol InputInjector: AnyObject {
    var name: String { get }
    func inject(_ event: InputEvent) throws
    /// The recorded monitor's pixel size, once capture negotiates it
    /// (the uinput tablet scales absolute moves against it; Mutter
    /// takes monitor-space pixels directly and ignores this).
    func noteMonitorExtent(width: UInt32, height: UInt32)
    func stop()
}

/// The Mutter-internal RemoteDesktop injector (HS-13 primary).
final class MutterInputInjector: InputInjector {
    let name = "mutter"

    private let bus: SessionBus
    private var rdSession = ""
    private var scSession = ""
    private var streamPath = ""

    private static let rdService = "org.gnome.Mutter.RemoteDesktop"
    private static let scService = "org.gnome.Mutter.ScreenCast"

    init() throws {
        // A dedicated connection: the injection session's lifetime is
        // this object's, independent of the portal capture's bus.
        bus = try SessionBus()

        let createReply = try bus.call(
            dest: Self.rdService, path: "/org/gnome/Mutter/RemoteDesktop",
            interface: Self.rdService, method: "CreateSession")
        rdSession = try SessionBus.objectPathReply(createReply)
        dbus_message_unref(createReply)

        let sessionId = try sessionIdProperty()

        let scReply = try bus.call(
            dest: Self.scService, path: "/org/gnome/Mutter/ScreenCast",
            interface: Self.scService, method: "CreateSession",
            appendArgs: { iter in
                try self.bus.appendOptions(&iter,
                    [("remote-desktop-session-id", .string(sessionId))])
            })
        scSession = try SessionBus.objectPathReply(scReply)
        dbus_message_unref(scReply)

        // cursor-mode 1 (EMBEDDED) matches the spike's proven call; the
        // stream is the pointer's coordinate space, not a video source.
        let recReply = try bus.call(
            dest: Self.scService, path: scSession,
            interface: "org.gnome.Mutter.ScreenCast.Session",
            method: "RecordMonitor",
            appendArgs: { iter in
                try self.bus.appendString(&iter, "") // primary monitor
                try self.bus.appendOptions(&iter, [("cursor-mode", .u32(1))])
            })
        streamPath = try SessionBus.objectPathReply(recReply)
        dbus_message_unref(recReply)

        // RD.Start brings up the linked SC leg too (SC.Start alone
        // errors "Must be started from remote desktop session").
        let startReply = try bus.call(
            dest: Self.rdService, path: rdSession,
            interface: "org.gnome.Mutter.RemoteDesktop.Session",
            method: "Start")
        dbus_message_unref(startReply)
    }

    deinit { stop() }

    func inject(_ event: InputEvent) throws {
        switch event.body {
        case .keyKeycode(let keycode, let pressed):
            try notify("NotifyKeyboardKeycode") { iter in
                var code = keycode
                dbus_message_iter_append_basic(&iter, DType.uint32, &code)
                var state: dbus_bool_t = pressed ? 1 : 0
                dbus_message_iter_append_basic(&iter, DType.boolean, &state)
            }
        case .pointerMotionAbsolute(let x, let y):
            try notify("NotifyPointerMotionAbsolute") { iter in
                try self.bus.appendString(&iter, self.streamPath)
                var xx = x
                dbus_message_iter_append_basic(&iter, dTypeDouble, &xx)
                var yy = y
                dbus_message_iter_append_basic(&iter, dTypeDouble, &yy)
            }
        case .pointerMotionRelative(let dx, let dy):
            try notify("NotifyPointerMotionRelative") { iter in
                var xx = dx
                dbus_message_iter_append_basic(&iter, dTypeDouble, &xx)
                var yy = dy
                dbus_message_iter_append_basic(&iter, dTypeDouble, &yy)
            }
        case .pointerButton(let button, let pressed):
            try notify("NotifyPointerButton") { iter in
                var code = Int32(bitPattern: button)
                dbus_message_iter_append_basic(&iter, dTypeInt32, &code)
                var state: dbus_bool_t = pressed ? 1 : 0
                dbus_message_iter_append_basic(&iter, DType.boolean, &state)
            }
        case .pointerAxis(let dx, let dy, let finish):
            try notify("NotifyPointerAxis") { iter in
                var xx = dx
                dbus_message_iter_append_basic(&iter, dTypeDouble, &xx)
                var yy = dy
                dbus_message_iter_append_basic(&iter, dTypeDouble, &yy)
                var flags: UInt32 = finish ? 1 : 0
                dbus_message_iter_append_basic(&iter, DType.uint32, &flags)
            }
        }
    }

    func noteMonitorExtent(width: UInt32, height: UInt32) {
        // Mutter's absolute coordinates are already monitor pixels.
    }

    func stop() {
        guard !rdSession.isEmpty else { return }
        if let reply = try? bus.call(
            dest: Self.rdService, path: rdSession,
            interface: "org.gnome.Mutter.RemoteDesktop.Session",
            method: "Stop") {
            dbus_message_unref(reply)
        }
        rdSession = ""
    }

    private func sessionIdProperty() throws -> String {
        guard let msg = dbus_message_new_method_call(
            Self.rdService, rdSession,
            "org.freedesktop.DBus.Properties", "Get")
        else { throw HostError("cannot alloc Properties.Get") }
        defer { dbus_message_unref(msg) }
        var iter = DBusMessageIter()
        dbus_message_iter_init_append(msg, &iter)
        try bus.appendString(&iter, "org.gnome.Mutter.RemoteDesktop.Session")
        try bus.appendString(&iter, "SessionId")
        var err = DBusError()
        dbus_error_init(&err)
        guard let reply = dbus_connection_send_with_reply_and_block(
            bus.conn, msg, 5000, &err)
        else {
            dbus_error_free(&err)
            throw HostError("SessionId Get failed")
        }
        defer { dbus_message_unref(reply) }
        var rit = DBusMessageIter()
        guard dbus_message_iter_init(reply, &rit) != 0,
              dbus_message_iter_get_arg_type(&rit) == DType.variant else {
            throw HostError("SessionId reply not a variant")
        }
        var vit = DBusMessageIter()
        dbus_message_iter_recurse(&rit, &vit)
        var ptr: UnsafePointer<CChar>?
        dbus_message_iter_get_basic(&vit, &ptr)
        return ptr.map { String(cString: $0) } ?? ""
    }

    private func notify(
        _ method: String,
        _ append: (inout DBusMessageIter) throws -> Void
    ) throws {
        guard let msg = dbus_message_new_method_call(
            Self.rdService, rdSession,
            "org.gnome.Mutter.RemoteDesktop.Session", method)
        else { throw HostError("cannot alloc \(method)") }
        defer { dbus_message_unref(msg) }
        var iter = DBusMessageIter()
        dbus_message_iter_init_append(msg, &iter)
        try append(&iter)
        var err = DBusError()
        dbus_error_init(&err)
        guard let reply = dbus_connection_send_with_reply_and_block(
            bus.conn, msg, 5000, &err)
        else {
            let name = err.name.map { String(cString: $0) } ?? "?"
            let message = err.message.map { String(cString: $0) } ?? "?"
            dbus_error_free(&err)
            throw HostError("\(method) failed: \(name): \(message)")
        }
        dbus_message_unref(reply)
    }
}

/// The uinput fallback (CP-5 Q5). Pixel scroll deltas convert to the
/// kernel's v120 hi-res units at 15 px per detent (the libinput
/// convention for smooth sources).
final class UinputInjector: InputInjector {
    let name = "uinput"

    private let handle: OpaquePointer
    private static let pixelsPerDetent = 15.0

    init() throws {
        var err = [CChar](repeating: 0, count: 256)
        guard let handle = lyte_uinput_open(&err, err.count) else {
            throw HostError("uinput open failed: \(errString(err))")
        }
        self.handle = handle
    }

    deinit { lyte_uinput_free(handle) }

    func inject(_ event: InputEvent) throws {
        var err = [CChar](repeating: 0, count: 256)
        let rc: Int32
        switch event.body {
        case .keyKeycode(let code, let pressed),
             .pointerButton(let code, let pressed):
            rc = lyte_uinput_key(
                handle, code, pressed ? 1 : 0, &err, err.count)
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

    func stop() {}
}

/// The `--input` policy: mutter first, uinput second, loud otherwise.
func makeInputInjector(_ choice: InputBackendChoice) -> InputInjector? {
    switch choice {
    case .off:
        return nil
    case .mutter:
        do {
            return try MutterInputInjector()
        } catch {
            print("input: mutter RemoteDesktop unavailable (\(error)) — "
                + "injection OFF (try --input uinput)")
            return nil
        }
    case .uinput:
        do {
            return try UinputInjector()
        } catch {
            print("input: uinput unavailable (\(error)) — injection OFF")
            return nil
        }
    case .auto:
        do {
            return try MutterInputInjector()
        } catch {
            print("input: mutter RemoteDesktop unavailable (\(error)) — "
                + "falling back to uinput")
        }
        do {
            return try UinputInjector()
        } catch {
            print("input: uinput unavailable too (\(error)) — injection OFF")
            return nil
        }
    }
}
#endif

enum InputBackendChoice: String {
    case auto
    case mutter
    case uinput
    case off
}
