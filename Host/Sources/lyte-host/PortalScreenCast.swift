// xdg-desktop-portal ScreenCast session: CreateSession → SelectSources →
// Start → OpenPipeWireRemote. Requests persist_mode UNTIL_REVOKED and reuses
// a saved restore token so approval is one-time.

import CDBus
import Foundation

struct ScreenCastStream {
    let pipewireFd: Int32
    let nodeId: UInt32
}

final class PortalScreenCast {
    private let bus: SessionBus
    private var tokenCounter = 0

    /// Where the portal restore token persists between runs.
    static let tokenPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyte-host/portal_token")

    init() throws {
        bus = try SessionBus()
    }

    func openDesktopStream() throws -> ScreenCastStream {
        let session = try createSession()
        try selectSources(session: session)
        let (nodeId, restoreToken) = try start(session: session)
        if let restoreToken {
            saveRestoreToken(restoreToken)
        }
        let fd = try openPipeWireRemote(session: session)
        return ScreenCastStream(pipewireFd: fd, nodeId: nodeId)
    }

    // MARK: - Portal calls

    private func createSession() throws -> String {
        let (handleToken, requestPath) = try prepareRequest()
        let reply = try bus.callPortal(
            interface: "org.freedesktop.portal.ScreenCast",
            method: "CreateSession",
            options: [
                ("handle_token", .string(handleToken)),
                ("session_handle_token", .string("lyte_host_session")),
            ])
        dbus_message_unref(reply)

        let (code, results) = try bus.waitForResponse(requestPath: requestPath, timeout: 30)
        try rejectIfDenied(code, phase: "CreateSession")
        guard let session = results.sessionHandle else {
            throw HostError("portal CreateSession succeeded but returned no session_handle")
        }
        return session
    }

    private func selectSources(session: String) throws {
        let (handleToken, requestPath) = try prepareRequest()
        var options: [(String, DBusVariant)] = [
            ("handle_token", .string(handleToken)),
            ("types", .u32(1)),        // MONITOR
            ("multiple", .bool(false)),
            ("cursor_mode", .u32(2)),  // EMBEDDED
            ("persist_mode", .u32(2)), // UNTIL_REVOKED
        ]
        if let token = loadRestoreToken() {
            options.append(("restore_token", .string(token)))
            print("portal: using saved restore token (\(Self.tokenPath.path))")
        }
        let reply = try bus.callPortal(
            interface: "org.freedesktop.portal.ScreenCast",
            method: "SelectSources",
            objectPathArgs: [session],
            options: options)
        dbus_message_unref(reply)

        let (code, _) = try bus.waitForResponse(requestPath: requestPath, timeout: 30)
        try rejectIfDenied(code, phase: "SelectSources")
    }

    private func start(session: String) throws -> (nodeId: UInt32, restoreToken: String?) {
        let (handleToken, requestPath) = try prepareRequest()
        let reply = try bus.callPortal(
            interface: "org.freedesktop.portal.ScreenCast",
            method: "Start",
            objectPathArgs: [session],
            stringArgs: [""], // parent_window: none
            options: [("handle_token", .string(handleToken))])
        dbus_message_unref(reply)

        // First run without a restore token requires a one-time approval
        // dialog on the host's physical screen; give it time.
        let (code, results) = try bus.waitForResponse(
            requestPath: requestPath, timeout: 120,
            onWaiting: {
                print("portal: waiting for Start response — if this is the first "
                    + "run, an on-screen consent dialog on the host must be approved")
            })
        try rejectIfDenied(code, phase: "Start")

        guard let nodeId = results.streamNodeIds.first else {
            throw HostError("portal Start succeeded but returned no PipeWire streams")
        }
        return (nodeId, results.restoreToken)
    }

    private func openPipeWireRemote(session: String) throws -> Int32 {
        let reply = try bus.callPortal(
            interface: "org.freedesktop.portal.ScreenCast",
            method: "OpenPipeWireRemote",
            objectPathArgs: [session],
            options: [])
        defer { dbus_message_unref(reply) }
        return try SessionBus.unixFd(fromReply: reply)
    }

    // MARK: - Request plumbing

    /// Allocates a handle token, computes the request object path the portal
    /// will use for it, and subscribes to its Response signal ahead of the
    /// call so the response cannot be missed.
    private func prepareRequest() throws -> (handleToken: String, requestPath: String) {
        tokenCounter += 1
        let handleToken = "lyte_host_\(tokenCounter)"
        let requestPath = "/org/freedesktop/portal/desktop/request/"
            + bus.senderToken + "/" + handleToken
        try bus.addMatch("type='signal',interface='org.freedesktop.portal.Request',"
            + "member='Response',path='\(requestPath)'")
        return (handleToken, requestPath)
    }

    /// Response code 0 = success, 1 = user cancelled, 2 = other failure.
    /// A locked GNOME session inhibits capture and surfaces as code 2 — name
    /// that cause precisely instead of failing opaquely.
    private func rejectIfDenied(_ code: UInt32, phase: String) throws {
        switch code {
        case 0:
            return
        case 1:
            throw HostError("portal \(phase) was cancelled by the user on the host's screen")
        default:
            if sessionLooksLocked() {
                throw HostError("portal \(phase) failed (response \(code)): the GNOME "
                    + "session is LOCKED, which inhibits screen capture "
                    + "(\"Session creation inhibited\"). Unlock the session on the host "
                    + "(loginctl unlock-session 1) and retry.")
            }
            throw HostError("portal \(phase) failed (response \(code)): the portal "
                + "refused the request. The session is not locked; possible causes: "
                + "capture inhibited by another component, or the saved restore "
                + "token was revoked (delete \(Self.tokenPath.path) and retry).")
        }
    }

    /// Asks GNOME's screensaver whether the session is locked, to make the
    /// rejection message precise. Any query failure reads as "not locked".
    private func sessionLooksLocked() -> Bool {
        guard let msg = dbus_message_new_method_call(
            "org.gnome.ScreenSaver", "/org/gnome/ScreenSaver",
            "org.gnome.ScreenSaver", "GetActive")
        else { return false }
        defer { dbus_message_unref(msg) }

        var err = DBusError()
        dbus_error_init(&err)
        guard let reply = dbus_connection_send_with_reply_and_block(bus.conn, msg, 2000, &err)
        else {
            dbus_error_free(&err)
            return false
        }
        defer { dbus_message_unref(reply) }

        var iter = DBusMessageIter()
        guard dbus_message_iter_init(reply, &iter) != 0,
              dbus_message_iter_get_arg_type(&iter) == DType.boolean
        else { return false }
        var active: dbus_bool_t = 0
        dbus_message_iter_get_basic(&iter, &active)
        return active != 0
    }

    // MARK: - Restore token persistence

    private func loadRestoreToken() -> String? {
        guard let token = try? String(contentsOf: Self.tokenPath, encoding: .utf8) else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func saveRestoreToken(_ token: String) {
        do {
            try FileManager.default.createDirectory(
                at: Self.tokenPath.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try token.write(to: Self.tokenPath, atomically: true, encoding: .utf8)
            print("portal: restore token saved to \(Self.tokenPath.path)")
        } catch {
            print("warning: could not persist the portal restore token: \(error)")
        }
    }
}
