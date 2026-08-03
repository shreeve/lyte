// The Linux clipboard OS leaf (HS-19, closing CL-15's queued
// follow-up): the real `HostClipboardLeaf`, driving the
// RemoteDesktop-session clipboard API the design doc names
// (docs/20260722-231500-lyte-clipboard.md §7; host build plan §6 —
// selection-change signals + fd-based transfer, both directions).
//
// WHICH RemoteDesktop session: the Mutter-internal one
// (org.gnome.Mutter.RemoteDesktop) — the same API family HS-13's input
// injector holds and the CP-5 verdict blessed. The sanctioned xdg
// portal exposes an identical Clipboard interface, but it hangs off a
// portal RemoteDesktop session whose Start auto-denies headless on
// this GNOME (CP-5 Q1) — and on GNOME the portal Clipboard is a thin
// wrapper over exactly this Mutter session API, so the leaf drives the
// implementation directly. `wl-clipboard` stays a probe tool, not a
// carriage (the design doc's ruling). The leaf holds its OWN session
// on its OWN bus connection, mirroring the injector-vs-capture
// separation: `--input off` must not kill clipboard, and vice versa.
//
// The protocol, proven live on pup before this file was written:
//   • a foreign copy → SelectionOwnerChanged (mime-types,
//     session-is-owner=false) → SelectionRead(mime) → fd → the text;
//   • apply (a client 0x1A) → SetSelection(mime-types) → we own the
//     selection; every paste in a host app → SelectionTransfer(mime,
//     serial) → SelectionWrite(serial) → fd → SelectionWriteDone;
//   • our own SetSelection also fires SelectionOwnerChanged with
//     session-is-owner=true — reported upward as the apply's echo,
//     which the session's pre-armed sync book suppresses (the
//     boomerang proof); the leaf stays dumb by design.
//
// Threading: NONE. Everything runs on the video-loop tick thread —
// `service()` (SessionWire's off-lock clipboard hook) drains the bus
// non-blockingly and pumps the fd state machines with O_NONBLOCK
// descriptors, so a slow selection owner can never stall a frame.
// No new C shim: CDBus carries the D-Bus plumbing (fds ride the 'h'
// type SessionBus already decodes) and Glibc carries the fd syscalls.
// Payloads never log — byte counts only, the CL-15 rule.
//
// P-1 (clipboard v2) adds the image half on the SAME machinery: on
// the images tier (`--clipboard=images`) a foreign owner offering no
// text flavor but a PNG one is read whole (32 MiB + 1 cap) and
// reported through `onLocalImageChange`; a client image landing
// becomes ownership with the PNG flavor, served per SelectionTransfer
// exactly like text. Text always wins when both flavors are offered
// (ClipboardImageFlavor's rule). Off the images tier the leaf is
// byte-identical to its v1 self.

import LyteIO
import Foundation
import HostWire
import LyteWire

#if os(Linux)
import CDBus

final class MutterClipboardLeaf: HostClipboardLeaf {
    var onLocalChange: ((String) -> Void)?
    /// P-1: image copies (whole PNG bytes), echoes included — nil
    /// callback or `imagesEnabled == false` both mean the text-only
    /// tier, where non-text flavors stay ignored weather (v1 exactly).
    var onLocalImageChange: (([UInt8]) -> Void)?

    /// P-1: the consent tier's leaf half (`--clipboard=images`). When
    /// false the leaf is byte-identical to its v1 self: image flavors
    /// are never read, never offered, never reported.
    private let imagesEnabled: Bool

    private let bus: SessionBus
    private var rdSession = ""

    private static let rdService = "org.gnome.Mutter.RemoteDesktop"
    private static let sessionInterface =
        "org.gnome.Mutter.RemoteDesktop.Session"

    /// Read caps: the wire ceiling plus one byte — enough to KNOW a
    /// copy is over-ceiling (the session suppresses it as overBudget
    /// weather) without swallowing an arbitrarily large pipe. Images
    /// get the P-1 ceiling (32 MiB) the same way.
    private static let textReadCap = ClipboardWire.maxTextByteCount + 1
    private static let imageReadCap =
        ClipboardImageWire.maxImageByteCount + 1
    /// A transfer that makes no progress for this long is abandoned
    /// (the owner died mid-pipe; routine weather, counted).
    private static let transferTimeoutSeconds = 2.0

    /// What we own on the OS clipboard (the last applied client set),
    /// served on every SelectionTransfer while we stay owner.
    private enum OwnedContent {
        case none
        /// UTF-8 bytes of an applied 0x1A.
        case text([UInt8])
        /// PNG bytes of an applied clipboard-image landing (P-1).
        case image([UInt8])

        var bytes: [UInt8] {
            switch self {
            case .none: return []
            case .text(let bytes), .image(let bytes): return bytes
            }
        }
    }
    private var owned: OwnedContent = .none
    private var sessionIsOwner = false

    private enum ReadKind {
        case text
        case image
    }

    private struct PendingRead {
        var fd: Int32
        var kind: ReadKind
        var buffer: [UInt8] = []
        var startedAt: Double
    }
    private var pendingRead: PendingRead?

    private struct PendingWrite {
        var serial: UInt32
        var fd: Int32
        var data: [UInt8]
        var offset = 0
        var startedAt: Double
    }
    private var pendingWrites: [PendingWrite] = []

    // Observability (byte counts and verdicts, never content).
    private(set) var changesReported = 0
    private(set) var appliesTaken = 0
    private(set) var transfersServed = 0
    private(set) var transfersFailed = 0
    private(set) var readsAbandoned = 0
    private(set) var nonTextChangesIgnored = 0
    private(set) var baselineReplaysSkipped = 0
    // P-1: the image lane's own books.
    private(set) var imageChangesReported = 0
    private(set) var imageAppliesTaken = 0

    init(imagesEnabled: Bool = false) throws {
        self.imagesEnabled = imagesEnabled
        // A dedicated connection: the clipboard session's lifetime is
        // this object's, independent of capture and input (a SIGKILL
        // closes the connection, which closes the session — nothing
        // stranded).
        bus = try SessionBus()
        let createReply = try bus.call(
            dest: Self.rdService, path: "/org/gnome/Mutter/RemoteDesktop",
            interface: Self.rdService, method: "CreateSession")
        rdSession = try SessionBus.objectPathReply(createReply)
        dbus_message_unref(createReply)
    }

    deinit { stop() }

    func start() throws {
        try bus.addMatch("type='signal',interface='\(Self.sessionInterface)',"
            + "member='SelectionOwnerChanged',path='\(rdSession)'")
        try bus.addMatch("type='signal',interface='\(Self.sessionInterface)',"
            + "member='SelectionTransfer',path='\(rdSession)'")
        let startReply = try bus.call(
            dest: Self.rdService, path: rdSession,
            interface: Self.sessionInterface, method: "Start")
        dbus_message_unref(startReply)
        // Empty options: observe only — becoming owner is apply()'s
        // job, never enablement's.
        let enableReply = try bus.call(
            dest: Self.rdService, path: rdSession,
            interface: Self.sessionInterface, method: "EnableClipboard",
            appendArgs: { iter in
                try self.bus.appendOptions(&iter, [])
            })
        dbus_message_unref(enableReply)

        // Mutter replays the STANDING selection owner right after
        // EnableClipboard (observed live: a pre-session copy arrived
        // as a fresh SelectionOwnerChanged). The client half never
        // reads pre-consent pasteboard content (PasteboardSync
        // re-baselines at start); the leaf holds the symmetric line —
        // clipboards carry passwords, and whatever sat on the host
        // clipboard from before the session is not the session's to
        // narrate. Drain and discard the replay window.
        let drainDeadline = SystemMonotonicClock.nowSeconds + 0.4
        while SystemMonotonicClock.nowSeconds < drainDeadline {
            _ = dbus_connection_read_write(bus.conn, 50)
            while let msg = dbus_connection_pop_message(bus.conn) {
                defer { dbus_message_unref(msg) }
                if dbus_message_is_signal(
                    msg, Self.sessionInterface,
                    "SelectionOwnerChanged") != 0 {
                    baselineReplaysSkipped += 1
                }
            }
        }
        if baselineReplaysSkipped > 0 {
            print("clipboard: standing pre-session selection NOT "
                + "announced (\(baselineReplaysSkipped) baseline "
                + "replay(s) skipped — consent starts now)")
        }
    }

    /// A client 0x1A landed (the session's gate + book already ran):
    /// become the selection owner. The text is retained and served
    /// lazily per SelectionTransfer — the Wayland ownership model.
    func apply(text: String) {
        owned = .text(Array(text.utf8))
        appliesTaken += 1
        setSelection(
            mimes: ClipboardTextMime.offered,
            byteCount: text.utf8.count
        )
    }

    /// P-1: a sha-verified client image landed (the session's gate +
    /// book already ran): become the selection owner with the PNG
    /// flavor, served lazily like text.
    func apply(imageData: [UInt8]) {
        owned = .image(imageData)
        imageAppliesTaken += 1
        setSelection(
            mimes: ClipboardImageFlavor.offered,
            byteCount: imageData.count
        )
    }

    private func setSelection(mimes: [String], byteCount: Int) {
        do {
            let reply = try bus.call(
                dest: Self.rdService, path: rdSession,
                interface: Self.sessionInterface, method: "SetSelection",
                appendArgs: { iter in
                    try self.appendMimeTypesOptions(&iter, mimes)
                })
            dbus_message_unref(reply)
        } catch {
            print("clipboard: SetSelection failed (\(error)) — "
                + "apply dropped (\(byteCount) B)")
        }
    }

    /// The off-lock service pass (video tick cadence): drain queued
    /// D-Bus signals, pump the transfer state machines.
    func service() {
        guard !rdSession.isEmpty else { return }
        _ = dbus_connection_read_write(bus.conn, 0)
        while let msg = dbus_connection_pop_message(bus.conn) {
            defer { dbus_message_unref(msg) }
            guard let p = dbus_message_get_path(msg),
                  String(cString: p) == rdSession else { continue }
            if dbus_message_is_signal(
                msg, Self.sessionInterface, "SelectionOwnerChanged") != 0 {
                handleOwnerChanged(msg)
            } else if dbus_message_is_signal(
                msg, Self.sessionInterface, "SelectionTransfer") != 0 {
                handleTransfer(msg)
            }
        }
        pumpRead()
        pumpWrites()
    }

    func stop() {
        guard !rdSession.isEmpty else { return }
        if let read = pendingRead {
            close(read.fd)
            pendingRead = nil
        }
        for write in pendingWrites { close(write.fd) }
        pendingWrites.removeAll()
        if let reply = try? bus.call(
            dest: Self.rdService, path: rdSession,
            interface: Self.sessionInterface, method: "Stop") {
            dbus_message_unref(reply)
        }
        rdSession = ""
    }

    // MARK: - Selection owner changes (the upward half)

    private func handleOwnerChanged(_ msg: OpaquePointer) {
        let (mimeTypes, isOwner) = Self.parseOwnerChanged(msg)
        sessionIsOwner = isOwner

        // A change always supersedes any read in flight.
        if let read = pendingRead {
            close(read.fd)
            pendingRead = nil
            readsAbandoned += 1
        }

        if isOwner {
            // Our own SetSelection landing — the apply's echo. Report
            // it upward; the session's pre-armed book suppresses it
            // (the boomerang proof runs through the REAL signal path).
            switch owned {
            case .none:
                break
            case .text(let bytes):
                deliver(String(decoding: bytes, as: UTF8.self))
            case .image(let bytes):
                deliverImage(bytes)
            }
            return
        }

        // Text always wins when an owner offers both (the
        // ClipboardImageFlavor rule); images are the fallback flavor,
        // and only on the images tier.
        let kind: ReadKind
        let mime: String
        if let textMime = ClipboardTextMime.pickForRead(
            fromOffered: mimeTypes) {
            kind = .text
            mime = textMime
        } else if imagesEnabled, let imageMime =
            ClipboardImageFlavor.pickForRead(fromOffered: mimeTypes) {
            kind = .image
            mime = imageMime
        } else {
            // Rich/unknown flavors (or a cleared selection): ignored,
            // never an error.
            nonTextChangesIgnored += 1
            return
        }
        do {
            let reply = try bus.call(
                dest: Self.rdService, path: rdSession,
                interface: Self.sessionInterface, method: "SelectionRead",
                appendArgs: { iter in
                    try self.bus.appendString(&iter, mime)
                })
            defer { dbus_message_unref(reply) }
            let fd = try SessionBus.unixFd(fromReply: reply)
            Self.setNonBlocking(fd)
            pendingRead = PendingRead(
                fd: fd, kind: kind, startedAt: SystemMonotonicClock.nowSeconds
            )
            pumpRead()
        } catch {
            readsAbandoned += 1
            print("clipboard: SelectionRead refused (\(error))")
        }
    }

    private func pumpRead() {
        guard var read = pendingRead else { return }
        let cap = read.kind == .image
            ? Self.imageReadCap : Self.textReadCap
        var scratch = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = scratch.withUnsafeMutableBytes { buf in
                Glibc.read(read.fd, buf.baseAddress, buf.count)
            }
            if n > 0 {
                read.buffer.append(contentsOf: scratch[0..<n])
                if read.buffer.count >= cap {
                    // Over the wire ceiling: enough is known. Deliver
                    // what we have — the session judges it overBudget
                    // and suppresses; the payload never leaves.
                    close(read.fd)
                    pendingRead = nil
                    finishRead(read)
                    return
                }
                continue
            }
            if n == 0 { // EOF — the whole selection arrived
                close(read.fd)
                pendingRead = nil
                if !read.buffer.isEmpty { finishRead(read) }
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if SystemMonotonicClock.nowSeconds - read.startedAt
                    > Self.transferTimeoutSeconds {
                    close(read.fd)
                    pendingRead = nil
                    readsAbandoned += 1
                    print("clipboard: selection read timed out "
                        + "(\(read.buffer.count) B partial, abandoned)")
                    return
                }
                pendingRead = read // progress retained across ticks
                return
            }
            if errno == EINTR { continue }
            close(read.fd)
            pendingRead = nil
            readsAbandoned += 1
            print("clipboard: selection read failed (errno \(errno))")
            return
        }
    }

    private func finishRead(_ read: PendingRead) {
        switch read.kind {
        case .text:
            deliver(String(decoding: read.buffer, as: UTF8.self))
        case .image:
            deliverImage(read.buffer)
        }
    }

    private func deliver(_ text: String) {
        changesReported += 1
        onLocalChange?(text)
    }

    private func deliverImage(_ data: [UInt8]) {
        imageChangesReported += 1
        onLocalImageChange?(data)
    }

    // MARK: - Selection transfers (serving what a 0x1A applied)

    private func handleTransfer(_ msg: OpaquePointer) {
        guard let (mime, serial) = Self.parseTransfer(msg) else { return }
        _ = mime // every offered flavor is served as the owned bytes
        do {
            let reply = try bus.call(
                dest: Self.rdService, path: rdSession,
                interface: Self.sessionInterface, method: "SelectionWrite",
                appendArgs: { iter in
                    var s = serial
                    dbus_message_iter_append_basic(
                        &iter, DType.uint32, &s)
                })
            defer { dbus_message_unref(reply) }
            let fd = try SessionBus.unixFd(fromReply: reply)
            Self.setNonBlocking(fd)
            pendingWrites.append(PendingWrite(
                serial: serial, fd: fd, data: owned.bytes,
                startedAt: SystemMonotonicClock.nowSeconds))
            pumpWrites()
        } catch {
            transfersFailed += 1
            print("clipboard: SelectionWrite refused (\(error))")
        }
    }

    private func pumpWrites() {
        var remaining: [PendingWrite] = []
        for var write in pendingWrites {
            var finished = false
            var succeeded = false
            while write.offset < write.data.count {
                let n = write.data[write.offset...].withUnsafeBytes { buf in
                    Glibc.write(write.fd, buf.baseAddress, buf.count)
                }
                if n > 0 {
                    write.offset += n
                    continue
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if SystemMonotonicClock.nowSeconds - write.startedAt
                        > Self.transferTimeoutSeconds {
                        finished = true // requestor stalled: abandon
                    }
                    break
                }
                finished = true // EPIPE etc. — requestor gone
                break
            }
            if write.offset >= write.data.count {
                finished = true
                succeeded = true
            }
            if finished {
                close(write.fd)
                writeDone(serial: write.serial, success: succeeded)
                if succeeded {
                    transfersServed += 1
                } else {
                    transfersFailed += 1
                    print("clipboard: transfer serial \(write.serial) "
                        + "failed at \(write.offset)/\(write.data.count) B")
                }
            } else {
                remaining.append(write)
            }
        }
        pendingWrites = remaining
    }

    private func writeDone(serial: UInt32, success: Bool) {
        if let reply = try? bus.call(
            dest: Self.rdService, path: rdSession,
            interface: Self.sessionInterface, method: "SelectionWriteDone",
            appendArgs: { iter in
                var s = serial
                dbus_message_iter_append_basic(&iter, DType.uint32, &s)
                var ok: dbus_bool_t = success ? 1 : 0
                dbus_message_iter_append_basic(&iter, DType.boolean, &ok)
            }) {
            dbus_message_unref(reply)
        }
    }

    // MARK: - D-Bus plumbing

    /// Appends `a{sv}` holding one "mime-types" → `as` entry (the
    /// SetSelection options shape; SessionBus's generic options helper
    /// carries only scalar variants).
    private func appendMimeTypesOptions(
        _ iter: inout DBusMessageIter, _ mimes: [String]
    ) throws {
        var array = DBusMessageIter()
        guard dbus_message_iter_open_container(
            &iter, DType.array, "{sv}", &array) != 0
        else { throw HostError("dbus open_container(a{sv}) failed") }
        var entry = DBusMessageIter()
        dbus_message_iter_open_container(&array, DType.dictEntry, nil, &entry)
        try bus.appendString(&entry, "mime-types")
        var variant = DBusMessageIter()
        dbus_message_iter_open_container(&entry, DType.variant, "as", &variant)
        var strings = DBusMessageIter()
        dbus_message_iter_open_container(&variant, DType.array, "s", &strings)
        for mime in mimes {
            try bus.appendString(&strings, mime)
        }
        dbus_message_iter_close_container(&variant, &strings)
        dbus_message_iter_close_container(&entry, &variant)
        dbus_message_iter_close_container(&array, &entry)
        dbus_message_iter_close_container(&iter, &array)
    }

    /// SelectionOwnerChanged carries `a{sv}` with "mime-types" (as)
    /// and "session-is-owner" (b).
    private static func parseOwnerChanged(
        _ msg: OpaquePointer
    ) -> (mimeTypes: [String], sessionIsOwner: Bool) {
        var mimeTypes: [String] = []
        var isOwner = false
        var iter = DBusMessageIter()
        guard dbus_message_iter_init(msg, &iter) != 0,
              dbus_message_iter_get_arg_type(&iter) == DType.array
        else { return (mimeTypes, isOwner) }
        var entry = DBusMessageIter()
        dbus_message_iter_recurse(&iter, &entry)
        while dbus_message_iter_get_arg_type(&entry) == DType.dictEntry {
            var kv = DBusMessageIter()
            dbus_message_iter_recurse(&entry, &kv)
            var keyPtr: UnsafePointer<CChar>?
            dbus_message_iter_get_basic(&kv, &keyPtr)
            let key = keyPtr.map { String(cString: $0) } ?? ""
            _ = dbus_message_iter_next(&kv)
            var value = DBusMessageIter()
            dbus_message_iter_recurse(&kv, &value) // into the variant
            switch key {
            case "mime-types":
                // Mutter wraps the list as a variant holding a STRUCT
                // containing the array — type "(as)", verified live on
                // pup — so unwrap one struct level if present (and
                // accept a bare "as" should the shape ever simplify).
                var container = value
                if dbus_message_iter_get_arg_type(&container)
                    == DType.structType {
                    var inner = DBusMessageIter()
                    dbus_message_iter_recurse(&container, &inner)
                    container = inner
                }
                guard dbus_message_iter_get_arg_type(&container)
                    == DType.array else { break }
                var element = DBusMessageIter()
                dbus_message_iter_recurse(&container, &element)
                while dbus_message_iter_get_arg_type(&element)
                    == DType.string {
                    var ptr: UnsafePointer<CChar>?
                    dbus_message_iter_get_basic(&element, &ptr)
                    if let ptr { mimeTypes.append(String(cString: ptr)) }
                    _ = dbus_message_iter_next(&element)
                }
            case "session-is-owner"
                where dbus_message_iter_get_arg_type(&value) == DType.boolean:
                var flag: dbus_bool_t = 0
                dbus_message_iter_get_basic(&value, &flag)
                isOwner = flag != 0
            default:
                break
            }
            _ = dbus_message_iter_next(&entry)
        }
        return (mimeTypes, isOwner)
    }

    /// SelectionTransfer carries (s mime_type, u serial).
    private static func parseTransfer(
        _ msg: OpaquePointer
    ) -> (mime: String, serial: UInt32)? {
        var iter = DBusMessageIter()
        guard dbus_message_iter_init(msg, &iter) != 0,
              dbus_message_iter_get_arg_type(&iter) == DType.string
        else { return nil }
        var ptr: UnsafePointer<CChar>?
        dbus_message_iter_get_basic(&iter, &ptr)
        let mime = ptr.map { String(cString: $0) } ?? ""
        guard dbus_message_iter_next(&iter) != 0,
              dbus_message_iter_get_arg_type(&iter) == DType.uint32
        else { return nil }
        var serial: UInt32 = 0
        dbus_message_iter_get_basic(&iter, &serial)
        return (mime, serial)
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}
#endif
