// Thin Swift layer over libdbus: a private session- or system-bus
// connection, blocking method calls, a{sv} option dictionaries, and reply
// readers. Mutter's clipboard (RemoteDesktop) and Avahi ride it.

import CDBus

// D-Bus wire type codes (libdbus exposes these only as C macros).
enum DType {
    static let invalid: Int32 = 0
    static let string: Int32 = 115 // 's'
    static let objectPath: Int32 = 111 // 'o'
    static let uint32: Int32 = 117 // 'u'
    static let int32: Int32 = 105 // 'i'
    static let uint16: Int32 = 113 // 'q'
    static let byte: Int32 = 121 // 'y'
    static let boolean: Int32 = 98 // 'b'
    static let array: Int32 = 97 // 'a'
    static let variant: Int32 = 118 // 'v'
    static let dictEntry: Int32 = 101 // 'e'
    static let structType: Int32 = 114 // 'r'
    static let unixFd: Int32 = 104 // 'h'
}

/// Values we place into a{sv} option dictionaries.
enum DBusVariant {
    case u32(UInt32)
    case string(String)
    case bool(Bool)
}

final class SessionBus {
    let conn: OpaquePointer

    /// Which bus a private connection binds. Mutter lives on the user
    /// session bus; Avahi is a system daemon on the system bus — same
    /// libdbus plumbing either way.
    enum Kind {
        case session
        case system
    }

    init(kind: Kind = .session) throws {
        var err = DBusError()
        dbus_error_init(&err)
        let busType = kind == .session ? DBUS_BUS_SESSION : DBUS_BUS_SYSTEM
        guard let c = dbus_bus_get_private(busType, &err) else {
            let msg = err.message.map { String(cString: $0) } ?? "unknown"
            dbus_error_free(&err)
            switch kind {
            case .session:
                throw HostError("""
                    cannot connect to the D-Bus session bus: \(msg) \
                    (is DBUS_SESSION_BUS_ADDRESS set? Mutter needs the user session bus)
                    """)
            case .system:
                throw HostError("cannot connect to the D-Bus system bus: \(msg)")
            }
        }
        dbus_connection_set_exit_on_disconnect(c, 0)
        conn = c
    }

    deinit {
        dbus_connection_close(conn)
        dbus_connection_unref(conn)
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

    // MARK: - Generic calls

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

    static func stringReply(_ reply: OpaquePointer) throws -> String {
        var iter = DBusMessageIter()
        guard dbus_message_iter_init(reply, &iter) != 0,
              dbus_message_iter_get_arg_type(&iter) == DType.string
        else { throw HostError("reply does not carry a string") }
        var ptr: UnsafePointer<CChar>?
        dbus_message_iter_get_basic(&iter, &ptr)
        return ptr.map { String(cString: $0) } ?? ""
    }

    /// Reads the unix fd out of a method reply whose first argument is 'h'.
    static func unixFd(fromReply reply: OpaquePointer) throws -> Int32 {
        var iter = DBusMessageIter()
        guard dbus_message_iter_init(reply, &iter) != 0,
              dbus_message_iter_get_arg_type(&iter) == DType.unixFd
        else { throw HostError("reply does not carry a unix fd") }
        var fd: Int32 = -1
        dbus_message_iter_get_basic(&iter, &fd)
        guard fd >= 0 else { throw HostError("reply carried an invalid unix fd") }
        return fd
    }
}
