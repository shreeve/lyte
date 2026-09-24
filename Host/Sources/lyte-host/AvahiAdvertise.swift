// LAN discovery: the host advertises `_lyte._udp` through the Avahi
// daemon's D-Bus API on the system bus (DBus.swift); the daemon owns the
// mDNS socket, we only file a service registration.
//
// The port rides the SRV record, so TXT carries
//   v=<wire major>      checkable before any handshake is attempted
//   pkh=<sha256 hex>    hash of the 32-byte Noise static PUBLIC key —
//                       a paired client recognizes its pinned host (and
//                       detects a re-key) from the browse result alone;
//                       the key itself travels only through pairing or
//                       the printed banner.
//
// Lifetime: an entry group lives as long as its D-Bus connection and the
// daemon. `service()` (the between-session idle pass or a session's
// janitor — never both at once) watches the daemon's bus name and the
// group's StateChanged, and re-files with back-off (AdvertisementSchedule)
// when the record is gone. Dropping the object withdraws the record.
// Avahi being unreachable is never fatal: discovery degrades to manual
// host:port and keeps retrying.

import CDBus
import Foundation
import HostCore
import LyteCore
import LyteIO
import LyteWire

final class AvahiAdvertiser {
    static let serviceType = "_lyte._udp"

    let port: UInt16
    let txtRecords: [String]
    /// Empty = every interface.
    private let interfaceName: String
    /// The ifindex the standing record was filed on. A named interface
    /// is resolved again at every filing and watched between them: a
    /// re-plugged USB NIC comes back under the same name with a new
    /// index, and the old group stays pinned to the dead one.
    private var filedIfIndex: Int32?
    private(set) var serviceName: String
    private var bus: SessionBus?
    private var groupPath: String?
    private var schedule = AdvertisementSchedule()
    private var nextServiceNS: UInt64 = 0

    private static let dest = "org.freedesktop.Avahi"
    private static let serverInterface = "org.freedesktop.Avahi.Server"
    private static let groupInterface = "org.freedesktop.Avahi.EntryGroup"
    /// How often `service()` actually looks at the bus.
    private static let serviceIntervalNS: UInt64 = 100_000_000

    /// Files the service record now. Throws only for a configuration
    /// error (an unknown interface); an unreachable bus or daemon is
    /// printed and retried by `service()`.
    ///
    /// `interfaceName` pins the advertisement to ONE interface: a host
    /// on wired+wireless otherwise advertises on both and sessions may
    /// silently ride the radio. Empty = all interfaces.
    init(port: UInt16, staticPublicKey: [UInt8], name: String? = nil,
         interfaceName: String = "") throws {
        self.port = port
        guard Self.interfaceIndex(named: interfaceName) != nil else {
            throw HostError(
                "--advertise-interface \(interfaceName): no such interface")
        }
        self.interfaceName = interfaceName
        txtRecords = [
            "v=\(WireVersion.major)",
            "pkh=\(Hex.string(Sha256.digest(staticPublicKey)))",
        ]
        serviceName = name ?? Self.machineName()
        fileIfDue(nowNS: SystemMonotonicClock.nowNanoseconds)
    }

    /// Whether a filed record currently stands (it may still be
    /// registering on the LAN).
    var isFiled: Bool { groupPath != nil }

    /// The Avahi interface index for `name`: AVAHI_IF_UNSPEC (-1) for
    /// every interface, nil while the named one does not exist.
    static func interfaceIndex(
        named name: String,
        resolve: (String) -> UInt32 = { if_nametoindex($0) }
    ) -> Int32? {
        guard !name.isEmpty else { return -1 }
        let index = resolve(name)
        return index == 0 ? nil : Int32(index)
    }

    /// Why a standing record filed on `filed` must be filed again now
    /// that the interface resolves to `current`; nil while it is right.
    static func refileReason(
        interfaceName: String, filed: Int32, current: Int32?
    ) -> String? {
        guard current != filed else { return nil }
        return current == nil
            ? "\(interfaceName) went away"
            : "\(interfaceName) came back as a new interface"
    }

    /// Watches the daemon and the record; files it again when due.
    /// Non-blocking unless a filing is due (then a few method calls).
    func service() {
        let now = SystemMonotonicClock.nowNanoseconds
        guard now >= nextServiceNS else { return }
        nextServiceNS = now + Self.serviceIntervalNS
        if let bus {
            if dbus_connection_get_is_connected(bus.conn) == 0 {
                withdraw("the system bus connection closed", nowNS: now)
                self.bus = nil
            } else {
                _ = dbus_connection_read_write(bus.conn, 0)
                while let msg = dbus_connection_pop_message(bus.conn) {
                    defer { dbus_message_unref(msg) }
                    handle(msg, nowNS: now)
                }
            }
        }
        if groupPath != nil, let filed = filedIfIndex,
           let why = Self.refileReason(
               interfaceName: interfaceName, filed: filed,
               current: Self.interfaceIndex(named: interfaceName)) {
            withdraw(why, nowNS: now)
        }
        fileIfDue(nowNS: now)
    }

    private func handle(_ msg: OpaquePointer, nowNS: UInt64) {
        if dbus_message_is_signal(
            msg, "org.freedesktop.DBus", "NameOwnerChanged") != 0 {
            let names = Self.stringArguments(msg)
            guard names.first == Self.dest, groupPath != nil else { return }
            withdraw(names.count > 2 && !names[2].isEmpty
                ? "avahi-daemon restarted" : "avahi-daemon went away",
                nowNS: nowNS)
            return
        }
        guard dbus_message_is_signal(
                msg, Self.groupInterface, "StateChanged") != 0,
              let path = dbus_message_get_path(msg),
              String(cString: path) == groupPath
        else { return }
        var iter = DBusMessageIter()
        guard dbus_message_iter_init(msg, &iter) != 0,
              dbus_message_iter_get_arg_type(&iter) == DType.int32
        else { return }
        var raw: Int32 = 0
        dbus_message_iter_get_basic(&iter, &raw)
        guard let state = AvahiEntryGroupState(rawValue: raw) else { return }
        if state == .established { schedule.established() }
        switch state.reaction {
        case .keep:
            break
        case .refile:
            withdraw("the record's entry group was \(state)", nowNS: nowNS)
        case .refileRenamed:
            let taken = serviceName
            if let bus, let alternative = try? Self.alternativeName(
                bus: bus, for: taken) {
                serviceName = alternative
            }
            withdraw(
                "\"\(taken)\" is taken on the LAN, renaming to \"\(serviceName)\"",
                nowNS: nowNS)
        }
    }

    /// The filed record is gone: free what is left of its group and
    /// schedule the next filing.
    private func withdraw(_ why: String, nowNS: UInt64) {
        if let bus, let groupPath {
            if let reply = try? bus.call(
                dest: Self.dest, path: groupPath,
                interface: Self.groupInterface, method: "Free") {
                dbus_message_unref(reply)
            }
        }
        groupPath = nil
        filedIfIndex = nil
        schedule.retry(nowNS: nowNS)
        print("discovery: record withdrawn (\(why)) — filing it again")
    }

    private func fileIfDue(nowNS: UInt64) {
        guard groupPath == nil, schedule.isDue(nowNS: nowNS) else { return }
        do {
            let daemonVersion = try file()
            schedule.filed()
            print("""
                discovery: advertising \"\(serviceName)\" \(Self.serviceType) \
                port \(port) [\(txtRecords.joined(separator: " "))] \
                (\(daemonVersion))
                """)
        } catch {
            schedule.retry(nowNS: nowNS)
            print("""
                discovery: unavailable (\(error)) — manual host:port \
                still works; retrying
                """)
        }
    }

    /// Connects (once per bus connection, with its signal matches),
    /// creates an entry group, adds the service and commits it.
    private func file() throws -> String {
        if bus == nil {
            let fresh = try SessionBus(kind: .system)
            try fresh.addMatch("""
                type='signal',sender='org.freedesktop.DBus',\
                interface='org.freedesktop.DBus',member='NameOwnerChanged',\
                arg0='\(Self.dest)'
                """)
            try fresh.addMatch("""
                type='signal',interface='\(Self.groupInterface)',\
                member='StateChanged'
                """)
            bus = fresh
        }
        guard let bus else { throw HostError("no system bus") }

        let versionReply = try bus.call(
            dest: Self.dest, path: "/",
            interface: Self.serverInterface, method: "GetVersionString"
        )
        let daemonVersion = try SessionBus.stringReply(versionReply)
        dbus_message_unref(versionReply)

        guard let ifIndex = Self.interfaceIndex(named: interfaceName) else {
            throw HostError("\(interfaceName) does not exist right now")
        }

        let groupReply = try bus.call(
            dest: Self.dest, path: "/",
            interface: Self.serverInterface, method: "EntryGroupNew"
        )
        let group = try SessionBus.objectPathReply(groupReply)
        dbus_message_unref(groupReply)

        do {
            // A same-name service already registered on this machine
            // collides at AddService time; ask the daemon for its
            // canonical alternative ("name #2") and retry rather than
            // failing discovery outright.
            var attempt = 0
            while true {
                do {
                    try Self.addService(bus: bus, groupPath: group,
                                        name: serviceName, port: port,
                                        txtRecords: txtRecords,
                                        ifIndex: ifIndex)
                    break
                } catch let error as HostError
                    where error.message.contains("CollisionError") && attempt < 4
                {
                    attempt += 1
                    serviceName = try Self.alternativeName(
                        bus: bus, for: serviceName)
                }
            }

            let commitReply = try bus.call(
                dest: Self.dest, path: group,
                interface: Self.groupInterface, method: "Commit"
            )
            dbus_message_unref(commitReply)
        } catch {
            // Every retry would otherwise leak one group toward the
            // daemon's per-client object limit.
            if let reply = try? bus.call(
                dest: Self.dest, path: group,
                interface: Self.groupInterface, method: "Free") {
                dbus_message_unref(reply)
            }
            throw error
        }
        groupPath = group
        filedIfIndex = ifIndex
        return daemonVersion
    }

    /// The leading string arguments of a signal.
    private static func stringArguments(_ msg: OpaquePointer) -> [String] {
        var out: [String] = []
        var iter = DBusMessageIter()
        guard dbus_message_iter_init(msg, &iter) != 0 else { return out }
        repeat {
            guard dbus_message_iter_get_arg_type(&iter) == DType.string else { break }
            var ptr: UnsafePointer<CChar>?
            dbus_message_iter_get_basic(&iter, &ptr)
            out.append(ptr.map { String(cString: $0) } ?? "")
        } while dbus_message_iter_next(&iter) != 0
        return out
    }

    /// EntryGroup.AddService(i interface, i protocol, u flags, s name,
    /// s type, s domain, s host, q port, aay txt). Static because it runs
    /// during init, before all stored properties are set.
    private static func addService(bus: SessionBus, groupPath: String,
                                   name: String, port: UInt16,
                                   txtRecords: [String],
                                   ifIndex: Int32) throws {
        let reply = try bus.call(
            dest: dest, path: groupPath,
            interface: groupInterface, method: "AddService",
            appendArgs: { iter in
                var ifIndex = ifIndex
                dbus_message_iter_append_basic(&iter, DType.int32, &ifIndex)
                var proto: Int32 = -1 // AVAHI_PROTO_UNSPEC: IPv4 + IPv6
                dbus_message_iter_append_basic(&iter, DType.int32, &proto)
                var flags: UInt32 = 0
                dbus_message_iter_append_basic(&iter, DType.uint32, &flags)
                try bus.appendString(&iter, name)
                try bus.appendString(&iter, serviceType)
                try bus.appendString(&iter, "") // domain: default (.local)
                try bus.appendString(&iter, "") // host: this machine
                var p = port
                dbus_message_iter_append_basic(&iter, DType.uint16, &p)
                try appendTxt(&iter, txtRecords)
            }
        )
        dbus_message_unref(reply)
    }

    private static func alternativeName(bus: SessionBus,
                                        for name: String) throws -> String {
        let reply = try bus.call(
            dest: dest, path: "/",
            interface: serverInterface, method: "GetAlternativeServiceName",
            appendArgs: { iter in
                try bus.appendString(&iter, name)
            }
        )
        defer { dbus_message_unref(reply) }
        return try SessionBus.stringReply(reply)
    }

    /// TXT is `aay` — one byte array per "key=value" record.
    private static func appendTxt(_ iter: inout DBusMessageIter,
                                  _ records: [String]) throws {
        var outer = DBusMessageIter()
        guard dbus_message_iter_open_container(&iter, DType.array, "ay", &outer) != 0
        else { throw HostError("dbus open_container(aay) failed") }
        for record in records {
            var inner = DBusMessageIter()
            guard dbus_message_iter_open_container(&outer, DType.array, "y", &inner) != 0
            else { throw HostError("dbus open_container(ay) failed") }
            for byte in Array(record.utf8) {
                var b = byte
                dbus_message_iter_append_basic(&inner, DType.byte, &b)
            }
            dbus_message_iter_close_container(&outer, &inner)
        }
        dbus_message_iter_close_container(&iter, &outer)
    }

    /// The mDNS instance name: the machine's short hostname, what the
    /// client's browse UI shows.
    static func machineName() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        gethostname(&buf, buf.count - 1)
        let full = String(cBuffer: buf)
        let short = full.split(separator: ".").first.map(String.init) ?? full
        return short.isEmpty ? "lyte-host" : short
    }
}

// MARK: - `lyte-host advertise` subcommand

/// Standalone advertisement with no capture session attached, so a
/// Mac-side `dns-sd -B _lyte._udp` / `dns-sd -L` can verify discovery.
func advertiseMain(_ args: [String]) -> Never {
    var port: UInt16 = 41000
    var seconds = 60.0
    var name: String?
    var i = 0
    do {
        while i < args.count {
            switch args[i] {
            case "--port":
                i += 1
                guard i < args.count, let p = UInt16(args[i]), p > 0 else {
                    throw HostError("--port needs a port number")
                }
                port = p
            case "--seconds":
                i += 1
                guard i < args.count, let s = Double(args[i]), s > 0 else {
                    throw HostError("--seconds needs a positive number")
                }
                seconds = s
            case "--name":
                i += 1
                guard i < args.count else { throw HostError("--name needs a value") }
                name = args[i]
            case "--help", "-h":
                print("""
                usage: lyte-host advertise [--port N] [--seconds N] [--name NAME]
                Publishes the _lyte._udp advertisement via Avahi and idles
                (default port 41000, 60s, name = hostname). Browse from a
                Mac with: dns-sd -B _lyte._udp
                """)
                exit(0)
            default:
                throw HostError("unknown argument \(args[i]) (try --help)")
            }
            i += 1
        }
        let hostStatic = try HostStaticKey.loadOrCreate()
        let advertiser = try AvahiAdvertiser(
            port: port, staticPublicKey: hostStatic.publicKey, name: name
        )
        guard advertiser.isFiled else {
            throw HostError("the Avahi daemon did not take the record")
        }
        print("""
            advertise: up for \(Int(seconds))s — browse with \
            `dns-sd -B \(AvahiAdvertiser.serviceType)`
            """)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            advertiser.service()
            Thread.sleep(forTimeInterval: 0.1)
        }
        withExtendedLifetime(advertiser) {}
        print("advertise: done — record withdrawn")
        exit(0)
    } catch {
        FileHandle.standardError.write(
            Data("lyte-host: advertise error: \(error)\n".utf8))
        exit(1)
    }
}
