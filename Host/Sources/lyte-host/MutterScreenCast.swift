// Mutter's internal ScreenCast API (org.gnome.Mutter.ScreenCast). Unlike the
// portal it shows no consent dialog, so it proves the capture→encode path in
// isolation when the portal's one-time approval has not yet been granted. The
// portal remains the mandated primary path (HOST-PLAN §2); this is a spike
// fallback, selected explicitly with --backend mutter.
//
// The ScreenCast session is owned by this D-Bus connection and lives only as
// long as it stays open, so the same SessionBus drives capture.

import CDBus
import Foundation

final class MutterScreenCast {
    private let bus: SessionBus
    private var sessionPath: String?

    init() throws {
        bus = try SessionBus()
    }

    /// Records the given connector (e.g. "DP-1"); empty records the primary.
    /// Returns the PipeWire node id published on the default remote; the
    /// capture leaf connects with fd < 0 to reach it.
    func openMonitorStream(connector: String) throws -> ScreenCastStream {
        let createReply = try bus.call(
            dest: "org.gnome.Mutter.ScreenCast",
            path: "/org/gnome/Mutter/ScreenCast",
            interface: "org.gnome.Mutter.ScreenCast",
            method: "CreateSession",
            appendArgs: { iter in try self.bus.appendOptions(&iter, []) })
        let session = try SessionBus.objectPathReply(createReply)
        dbus_message_unref(createReply)
        sessionPath = session

        let recordReply = try bus.call(
            dest: "org.gnome.Mutter.ScreenCast",
            path: session,
            interface: "org.gnome.Mutter.ScreenCast.Session",
            method: "RecordMonitor",
            appendArgs: { iter in
                try self.bus.appendString(&iter, connector)
                // cursor-mode 1 = EMBEDDED
                try self.bus.appendOptions(&iter, [("cursor-mode", .u32(1))])
            })
        let streamPath = try SessionBus.objectPathReply(recordReply)
        dbus_message_unref(recordReply)

        try bus.addMatch("type='signal',interface='org.gnome.Mutter.ScreenCast.Stream',"
            + "member='PipeWireStreamAdded',path='\(streamPath)'")

        let startReply = try bus.call(
            dest: "org.gnome.Mutter.ScreenCast",
            path: session,
            interface: "org.gnome.Mutter.ScreenCast.Session",
            method: "Start")
        dbus_message_unref(startReply)

        let nodeId = try bus.waitForUInt32Signal(
            interface: "org.gnome.Mutter.ScreenCast.Stream",
            member: "PipeWireStreamAdded",
            path: streamPath, timeout: 15)

        return ScreenCastStream(pipewireFd: -1, nodeId: nodeId)
    }

    func stop() {
        guard let session = sessionPath else { return }
        if let reply = try? bus.call(
            dest: "org.gnome.Mutter.ScreenCast",
            path: session,
            interface: "org.gnome.Mutter.ScreenCast.Session",
            method: "Stop") {
            dbus_message_unref(reply)
        }
        sessionPath = nil
    }
}
