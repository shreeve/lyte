// HS-10: LAN discovery — the host advertises `_lyte._udp` through the
// Avahi daemon's D-Bus API, on the system bus over the house libdbus
// plumbing (DBus.swift). No system library beyond CDBus is needed:
// Avahi's daemon owns the mDNS socket, we only file a service
// registration with it.
//
// TXT design (transport pillar §4: "host identity key hash, protocol
// versions, and port"): the port rides the SRV record, so TXT carries
//   v=<wire major>      checkable before any handshake is attempted
//   pkh=<sha256 hex>    hash of the 32-byte Noise static PUBLIC key —
//                       a paired client recognizes its pinned host (and
//                       detects a re-key) from the browse result alone;
//                       the key itself still travels only through pairing
//                       (W6 PAKE) or today's printed-banner hand-carry.
//
// Lifetime is the whole API: an Avahi entry group lives exactly as long
// as the D-Bus connection that created it, so retaining this object keeps
// the advertisement up and dropping it (or exiting) withdraws the record.
// Avahi being unreachable is never fatal — discovery degrades to manual
// host:port with a doctor-style line (build-plan risk register).

import CDBus
import Foundation
import LyteCore
import LyteWire

final class AvahiAdvertiser {
    static let serviceType = "_lyte._udp"

    private let bus: SessionBus
    let serviceName: String
    let port: UInt16
    let txtRecords: [String]

    private static let dest = "org.freedesktop.Avahi"
    private static let serverInterface = "org.freedesktop.Avahi.Server"
    private static let groupInterface = "org.freedesktop.Avahi.EntryGroup"

    /// Registers and commits the service. Throws when the system bus or
    /// the Avahi daemon is unavailable — the caller decides whether that
    /// is fatal (it never is for the session path).
    ///
    /// `interfaceName` pins the advertisement to ONE interface (e.g.
    /// pup's Ethernet NIC): a host on wired+wireless otherwise
    /// advertises on both, the client resolver picks whichever, and
    /// sessions silently ride the radio (the owner's .249-vs-.232
    /// hunt). Empty = all interfaces, exactly as before.
    init(port: UInt16, staticPublicKey: [UInt8], name: String? = nil,
         interfaceName: String = "") throws {
        self.port = port
        var ifIndex: Int32 = -1 // AVAHI_IF_UNSPEC: all interfaces
        if !interfaceName.isEmpty {
            let index = if_nametoindex(interfaceName)
            guard index != 0 else {
                throw HostError("--advertise-interface \(interfaceName): "
                    + "no such interface")
            }
            ifIndex = Int32(index)
        }
        txtRecords = [
            "v=\(WireVersion.major)",
            "pkh=" + Hex.string(Sha256.digest(staticPublicKey)),
        ]
        bus = try SessionBus(kind: .system)

        let versionReply = try bus.call(
            dest: Self.dest, path: "/",
            interface: Self.serverInterface, method: "GetVersionString"
        )
        let daemonVersion = try SessionBus.stringReply(versionReply)
        dbus_message_unref(versionReply)

        let groupReply = try bus.call(
            dest: Self.dest, path: "/",
            interface: Self.serverInterface, method: "EntryGroupNew"
        )
        let groupPath = try SessionBus.objectPathReply(groupReply)
        dbus_message_unref(groupReply)

        // A same-name service already registered on this machine collides
        // at AddService time; ask the daemon for its canonical alternative
        // ("name #2") and retry rather than failing discovery outright.
        var candidate = name ?? Self.machineName()
        var attempt = 0
        while true {
            do {
                try Self.addService(bus: bus, groupPath: groupPath,
                                    name: candidate, port: port,
                                    txtRecords: txtRecords,
                                    ifIndex: ifIndex)
                break
            } catch let error as HostError
                where error.message.contains("CollisionError") && attempt < 4
            {
                attempt += 1
                candidate = try Self.alternativeName(bus: bus, for: candidate)
            }
        }
        serviceName = candidate

        let commitReply = try bus.call(
            dest: Self.dest, path: groupPath,
            interface: Self.groupInterface, method: "Commit"
        )
        dbus_message_unref(commitReply)

        print("discovery: advertising \"\(serviceName)\" \(Self.serviceType) "
            + "port \(port) [\(txtRecords.joined(separator: " "))] "
            + "(\(daemonVersion))")
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

    /// The mDNS instance name: the machine's short hostname — what the
    /// client's browse UI shows, matching Sunshine's convention so "pup"
    /// is "pup" in both lists until the crutch retires.
    static func machineName() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        gethostname(&buf, buf.count - 1)
        let full = String(cString: buf)
        let short = full.split(separator: ".").first.map(String.init) ?? full
        return short.isEmpty ? "lyte-host" : short
    }
}

// MARK: - `lyte-host advertise` subcommand

/// Standalone advertisement for gate evidence and doctoring: publish the
/// record for a while with no capture session attached, so a Mac-side
/// `dns-sd -B _lyte._udp` / `dns-sd -L` browse can verify the LAN story
/// in isolation.
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
        print("advertise: up for \(Int(seconds))s — browse with "
            + "`dns-sd -B \(AvahiAdvertiser.serviceType)`")
        Thread.sleep(forTimeInterval: seconds)
        withExtendedLifetime(advertiser) {}
        print("advertise: done — record withdrawn")
        exit(0)
    } catch {
        FileHandle.standardError.write(
            Data("lyte-host: advertise error: \(error)\n".utf8))
        exit(1)
    }
}
