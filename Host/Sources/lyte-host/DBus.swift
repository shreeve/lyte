// Thin Swift layer over libdbus: session-bus connection, method calls with
// a{sv} options, and portal Request/Response signal waiting.

import CDBus
import Foundation

struct HostError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    init(_ message: String) { self.message = message }
}

// D-Bus wire type codes (libdbus exposes these only as C macros).
enum DType {
    static let invalid: Int32 = 0
    static let string: Int32 = 115 // 's'
    static let objectPath: Int32 = 111 // 'o'
    static let uint32: Int32 = 117 // 'u'
    static let boolean: Int32 = 98 // 'b'
    static let array: Int32 = 97 // 'a'
    static let variant: Int32 = 118 // 'v'
    static let dictEntry: Int32 = 101 // 'e'
    static let structType: Int32 = 114 // 'r'
    static let unixFd: Int32 = 104 // 'h'
}

/// Values we place into portal option dictionaries (a{sv}).
enum DBusVariant {
    case u32(UInt32)
    case string(String)
    case bool(Bool)
}

final class SessionBus {
    let conn: OpaquePointer

    init() throws {
        var err = DBusError()
        dbus_error_init(&err)
        guard let c = dbus_bus_get_private(DBUS_BUS_SESSION, &err) else {
            let msg = err.message.map { String(cString: $0) } ?? "unknown"
            dbus_error_free(&err)
            throw HostError("cannot connect to the D-Bus session bus: \(msg) "
                + "(is DBUS_SESSION_BUS_ADDRESS set? portal needs the user session bus)")
        }
        dbus_connection_set_exit_on_disconnect(c, 0)
        conn = c
    }

    deinit {
        dbus_connection_close(conn)
        dbus_connection_unref(conn)
    }

    var uniqueName: String {
        String(cString: dbus_bus_get_unique_name(conn))
    }

    /// The token part of the sender name used in portal request object paths:
    /// ":1.42" → "1_42".
    var senderToken: String {
        uniqueName.dropFirst().replacingOccurrences(of: ".", with: "_")
    }

    func addMatch(_ rule: String) throws {
        var err = DBusError()
        dbus_error_init(&err)
        dbus_bus_add_match(conn, rule, &err)
        if dbus_error_is_set(&err) != 0 {
            let msg = err.message.map { String(cString: $0) } ?? "unknown"
            dbus_error_free(&err)
            throw HostError("dbus add_match failed: \(msg)")
        }
    }

    /// Calls a method on the desktop portal. `objectPathArgs` are prepended
    /// as OBJECT_PATH arguments, `stringArgs` as STRING arguments, then one
    /// a{sv} options dict is appended.
    func callPortal(interface: String, method: String,
                    objectPathArgs: [String] = [],
                    stringArgs: [String] = [],
                    options: [(String, DBusVariant)],
                    timeoutMs: Int32 = 30_000) throws -> OpaquePointer {
        guard let msg = dbus_message_new_method_call(
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            interface, method)
        else { throw HostError("cannot allocate D-Bus message") }
        defer { dbus_message_unref(msg) }

        var iter = DBusMessageIter()
        dbus_message_iter_init_append(msg, &iter)
        for path in objectPathArgs {
            try appendBasicString(&iter, type: DType.objectPath, value: path)
        }
        for s in stringArgs {
            try appendBasicString(&iter, type: DType.string, value: s)
        }
        try appendOptionsDict(&iter, options)

        var err = DBusError()
        dbus_error_init(&err)
        guard let reply = dbus_connection_send_with_reply_and_block(
            conn, msg, timeoutMs, &err)
        else {
            let name = err.name.map { String(cString: $0) } ?? "?"
            let m = err.message.map { String(cString: $0) } ?? "?"
            dbus_error_free(&err)
            throw HostError("\(interface).\(method) failed: \(name): \(m)")
        }
        return reply // caller unrefs
    }

    private func appendBasicString(_ iter: inout DBusMessageIter,
                                   type: Int32, value: String) throws {
        let ok = value.withCString { cstr -> dbus_bool_t in
            var ptr: UnsafePointer<CChar>? = cstr
            return dbus_message_iter_append_basic(&iter, type, &ptr)
        }
        if ok == 0 { throw HostError("dbus append failed (out of memory)") }
    }

    private func appendOptionsDict(_ iter: inout DBusMessageIter,
                                   _ options: [(String, DBusVariant)]) throws {
        var arrayIter = DBusMessageIter()
        guard dbus_message_iter_open_container(&iter, DType.array, "{sv}", &arrayIter) != 0
        else { throw HostError("dbus open_container(array) failed") }

        for (key, value) in options {
            var entryIter = DBusMessageIter()
            dbus_message_iter_open_container(&arrayIter, DType.dictEntry, nil, &entryIter)
            try appendBasicString(&entryIter, type: DType.string, value: key)

            var variantIter = DBusMessageIter()
            switch value {
            case .u32(let v):
                dbus_message_iter_open_container(&entryIter, DType.variant, "u", &variantIter)
                var raw = v
                dbus_message_iter_append_basic(&variantIter, DType.uint32, &raw)
            case .string(let s):
                dbus_message_iter_open_container(&entryIter, DType.variant, "s", &variantIter)
                try appendBasicString(&variantIter, type: DType.string, value: s)
            case .bool(let b):
                dbus_message_iter_open_container(&entryIter, DType.variant, "b", &variantIter)
                var raw: dbus_bool_t = b ? 1 : 0
                dbus_message_iter_append_basic(&variantIter, DType.boolean, &raw)
            }
            dbus_message_iter_close_container(&entryIter, &variantIter)
            dbus_message_iter_close_container(&arrayIter, &entryIter)
        }
        dbus_message_iter_close_container(&iter, &arrayIter)
    }

    // MARK: - Portal Request/Response

    /// Blocks until the portal emits Response on `requestPath` (the match
    /// rule must already be added). Returns the response code and results.
    func waitForResponse(requestPath: String, timeout: TimeInterval,
                         onWaiting: (() -> Void)? = nil) throws
        -> (code: UInt32, results: PortalResults)
    {
        let deadline = Date().addingTimeInterval(timeout)
        var announced = false
        while Date() < deadline {
            if dbus_connection_read_write(conn, 200) == 0 {
                throw HostError("D-Bus connection closed while waiting for portal response")
            }
            while let msg = dbus_connection_pop_message(conn) {
                defer { dbus_message_unref(msg) }
                guard dbus_message_is_signal(msg, "org.freedesktop.portal.Request", "Response") != 0,
                      let p = dbus_message_get_path(msg),
                      String(cString: p) == requestPath
                else { continue }
                return try parseResponse(msg)
            }
            if !announced, let onWaiting {
                announced = true
                onWaiting()
            }
        }
        throw HostError("timed out after \(Int(timeout))s waiting for the portal "
            + "response on \(requestPath)")
    }

    private func parseResponse(_ msg: OpaquePointer) throws
        -> (code: UInt32, results: PortalResults)
    {
        var iter = DBusMessageIter()
        guard dbus_message_iter_init(msg, &iter) != 0 else {
            throw HostError("portal Response signal carried no arguments")
        }
        guard dbus_message_iter_get_arg_type(&iter) == DType.uint32 else {
            throw HostError("portal Response: first argument is not u32")
        }
        var code: UInt32 = 0
        dbus_message_iter_get_basic(&iter, &code)

        var results = PortalResults()
        if dbus_message_iter_next(&iter) != 0,
           dbus_message_iter_get_arg_type(&iter) == DType.array
        {
            var entryIter = DBusMessageIter()
            dbus_message_iter_recurse(&iter, &entryIter)
            while dbus_message_iter_get_arg_type(&entryIter) == DType.dictEntry {
                var kvIter = DBusMessageIter()
                dbus_message_iter_recurse(&entryIter, &kvIter)

                var keyPtr: UnsafePointer<CChar>?
                dbus_message_iter_get_basic(&kvIter, &keyPtr)
                let key = keyPtr.map { String(cString: $0) } ?? ""
                _ = dbus_message_iter_next(&kvIter)

                var valueIter = DBusMessageIter()
                dbus_message_iter_recurse(&kvIter, &valueIter) // into variant
                readResult(key: key, iter: &valueIter, into: &results)

                _ = dbus_message_iter_next(&entryIter)
            }
        }
        return (code, results)
    }

    private func readResult(key: String, iter: inout DBusMessageIter,
                            into results: inout PortalResults) {
        let type = dbus_message_iter_get_arg_type(&iter)
        switch key {
        case "session_handle" where type == DType.string || type == DType.objectPath:
            var ptr: UnsafePointer<CChar>?
            dbus_message_iter_get_basic(&iter, &ptr)
            results.sessionHandle = ptr.map { String(cString: $0) }
        case "restore_token" where type == DType.string:
            var ptr: UnsafePointer<CChar>?
            dbus_message_iter_get_basic(&iter, &ptr)
            results.restoreToken = ptr.map { String(cString: $0) }
        case "streams" where type == DType.array:
            // Signature a(ua{sv}): array of (node id, properties) structs.
            var structIter = DBusMessageIter()
            dbus_message_iter_recurse(&iter, &structIter)
            while dbus_message_iter_get_arg_type(&structIter) == DType.structType {
                var fieldIter = DBusMessageIter()
                dbus_message_iter_recurse(&structIter, &fieldIter)
                if dbus_message_iter_get_arg_type(&fieldIter) == DType.uint32 {
                    var node: UInt32 = 0
                    dbus_message_iter_get_basic(&fieldIter, &node)
                    results.streamNodeIds.append(node)
                }
                _ = dbus_message_iter_next(&structIter)
            }
        default:
            break
        }
    }

    // MARK: - Generic calls (Mutter ScreenCast internal API)

    /// Issues a blocking method call; the closure appends arguments.
    func call(dest: String, path: String, interface: String, method: String,
              timeoutMs: Int32 = 30_000,
              appendArgs: (inout DBusMessageIter) throws -> Void = { _ in }) throws
        -> OpaquePointer
    {
        guard let msg = dbus_message_new_method_call(dest, path, interface, method)
        else { throw HostError("cannot allocate D-Bus message for \(interface).\(method)") }
        defer { dbus_message_unref(msg) }

        var iter = DBusMessageIter()
        dbus_message_iter_init_append(msg, &iter)
        try appendArgs(&iter)

        var err = DBusError()
        dbus_error_init(&err)
        guard let reply = dbus_connection_send_with_reply_and_block(conn, msg, timeoutMs, &err)
        else {
            let name = err.name.map { String(cString: $0) } ?? "?"
            let m = err.message.map { String(cString: $0) } ?? "?"
            dbus_error_free(&err)
            throw HostError("\(interface).\(method) failed: \(name): \(m)")
        }
        return reply
    }

    func appendString(_ iter: inout DBusMessageIter, _ value: String,
                      type: Int32 = DType.string) throws {
        try appendBasicString(&iter, type: type, value: value)
    }

    func appendOptions(_ iter: inout DBusMessageIter,
                       _ options: [(String, DBusVariant)]) throws {
        try appendOptionsDict(&iter, options)
    }

    static func objectPathReply(_ reply: OpaquePointer) throws -> String {
        var iter = DBusMessageIter()
        guard dbus_message_iter_init(reply, &iter) != 0,
              dbus_message_iter_get_arg_type(&iter) == DType.objectPath
        else { throw HostError("reply does not carry an object path") }
        var ptr: UnsafePointer<CChar>?
        dbus_message_iter_get_basic(&iter, &ptr)
        return ptr.map { String(cString: $0) } ?? ""
    }

    /// Waits for a signal carrying a single u32 (e.g. Mutter's
    /// PipeWireStreamAdded). The match rule must already be added.
    func waitForUInt32Signal(interface: String, member: String, path: String,
                             timeout: TimeInterval) throws -> UInt32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if dbus_connection_read_write(conn, 200) == 0 {
                throw HostError("D-Bus connection closed while waiting for \(member)")
            }
            while let msg = dbus_connection_pop_message(conn) {
                defer { dbus_message_unref(msg) }
                guard dbus_message_is_signal(msg, interface, member) != 0,
                      let p = dbus_message_get_path(msg),
                      String(cString: p) == path
                else { continue }
                var iter = DBusMessageIter()
                guard dbus_message_iter_init(msg, &iter) != 0,
                      dbus_message_iter_get_arg_type(&iter) == DType.uint32
                else { throw HostError("\(member) signal missing its u32 node id") }
                var node: UInt32 = 0
                dbus_message_iter_get_basic(&iter, &node)
                return node
            }
        }
        throw HostError("timed out after \(Int(timeout))s waiting for \(member) on \(path)")
    }

    /// Reads the unix fd out of a method reply whose first argument is 'h'.
    static func unixFd(fromReply reply: OpaquePointer) throws -> Int32 {
        var iter = DBusMessageIter()
        guard dbus_message_iter_init(reply, &iter) != 0,
              dbus_message_iter_get_arg_type(&iter) == DType.unixFd
        else { throw HostError("reply does not carry a unix fd") }
        var fd: Int32 = -1
        dbus_message_iter_get_basic(&iter, &fd)
        guard fd >= 0 else { throw HostError("portal returned an invalid pipewire fd") }
        return fd
    }
}

struct PortalResults {
    var sessionHandle: String?
    var restoreToken: String?
    var streamNodeIds: [UInt32] = []
}
