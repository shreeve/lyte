// The Linux clipboard OS leaf: the real `HostClipboardLeaf`, driving
// Mutter's RemoteDesktop session clipboard API
// (org.gnome.Mutter.RemoteDesktop) — selection-change signals and fd-based
// transfer, both directions. On GNOME the portal Clipboard wraps this same
// API, and no data-control protocol is available
// (docs/decisions/20260807-015743-wayland-clipboard-gnome-blocker.md).
// The leaf holds its OWN session on its OWN bus connection: `--input off`
// must not kill clipboard, and vice versa.
//
// The protocol:
//   • a foreign copy → SelectionOwnerChanged (mime-types,
//     session-is-owner=false) → SelectionRead(mime) → fd → the bytes;
//   • apply (a client 0x1A) → SetSelection(mime-types) → we own the
//     selection; every host paste → SelectionTransfer(mime, serial) →
//     SelectionWrite(serial) → fd → SelectionWriteDone;
//   • our own SetSelection fires SelectionOwnerChanged with
//     session-is-owner=true — reported upward as the apply's echo, which
//     the session's pre-armed sync book suppresses; the leaf stays dumb.
//
// Lifetime: one leaf serves every session of the process. Foreign copies
// are read only between `attach()` and `detach()` (consent starts at
// session start), but the leaf is serviced between sessions too, so host
// pastes of the last client-set content are served, not left to time out.
//
// Threading: none. `service()` drains the bus non-blockingly and pumps
// O_NONBLOCK fds, so a slow selection owner never stalls a frame. It runs
// on the janitor thread during a session and on the main thread's
// handshake idle hook between sessions — never both at once.
// Payloads never log — byte counts only.
//
// Images (`--clipboard=images`): a foreign owner offering no text flavor
// but a PNG one is read whole and reported through `onLocalImageChange`;
// a client image becomes ownership with the PNG flavor. Text wins when
// both are offered. Off the images tier, image flavors are never touched.

import LyteIO
import Foundation
import HostWire
import LyteWire

/// A clipboard pipe transfer's stall clock. Transfers are pumped on the
/// janitor tick through a 64 KiB pipe, so a large image takes many
/// seconds; only a transfer that makes no progress for
/// `timeoutSeconds` is abandoned.
struct TransferStall {
    static let timeoutSeconds = 2.0
    private(set) var lastProgressAt: Double

    init(at now: Double) { lastProgressAt = now }

    mutating func progressed(at now: Double) { lastProgressAt = now }

    func stalled(at now: Double) -> Bool {
        now - lastProgressAt > Self.timeoutSeconds
    }
}

#if os(Linux)
import CDBus

final class MutterClipboardLeaf: HostClipboardLeaf {
    var onLocalChange: ((String) -> Void)?
    /// Image copies (whole PNG bytes), echoes included. Nil or
    /// `imagesEnabled == false` means the text-only tier.
    var onLocalImageChange: (([UInt8]) -> Void)?

    /// `--clipboard=images`. When false image flavors are never read,
    /// offered or reported.
    private let imagesEnabled: Bool

    private let bus: SessionBus
    private var rdSession = ""

    private static let rdService = "org.gnome.Mutter.RemoteDesktop"
    private static let sessionInterface =
        "org.gnome.Mutter.RemoteDesktop.Session"

    /// Read caps: the wire ceiling plus one byte — enough to KNOW a copy
    /// is over-ceiling (the session suppresses it as overBudget) without
    /// swallowing an arbitrarily large pipe.
    private static let textReadCap = ClipboardWire.maxTextByteCount + 1
    private static let imageReadCap =
        ClipboardImageWire.maxImageByteCount + 1

    /// What we own on the OS clipboard (the last applied client set),
    /// served on every SelectionTransfer while we stay owner.
    private enum OwnedContent {
        case none
        /// UTF-8 bytes of an applied 0x1A.
        case text([UInt8])
        /// PNG bytes of an applied clipboard-image landing.
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
    /// A session is live: foreign copies are read and reported.
    private var attached = false

    private enum ReadKind {
        case text
        case image
    }

    private struct PendingRead {
        var fd: Int32
        var kind: ReadKind
        var buffer: [UInt8] = []
        var stall: TransferStall
    }
    private var pendingRead: PendingRead?

    private struct PendingWrite {
        var serial: UInt32
        var fd: Int32
        var data: [UInt8]
        var offset = 0
        var stall: TransferStall
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
    private(set) var changesOutsideSessionSkipped = 0
    private(set) var imageChangesReported = 0
    private(set) var imageAppliesTaken = 0

    init(imagesEnabled: Bool = false) throws {
        self.imagesEnabled = imagesEnabled
        // A dedicated connection: the clipboard session lives and dies
        // with this object (a SIGKILL closes the connection and session).
        bus = try SessionBus()
        let createReply = try bus.call(
            dest: Self.rdService, path: "/org/gnome/Mutter/RemoteDesktop",
            interface: Self.rdService, method: "CreateSession",
            timeoutMs: SessionBus.setupTimeoutMs)
        rdSession = try SessionBus.objectPathReply(createReply)
        dbus_message_unref(createReply)
    }

    deinit { stop() }

    func start() throws {
        try bus.addMatch("""
            type='signal',interface='\(Self.sessionInterface)',\
            member='SelectionOwnerChanged',path='\(rdSession)'
            """)
        try bus.addMatch("""
            type='signal',interface='\(Self.sessionInterface)',\
            member='SelectionTransfer',path='\(rdSession)'
            """)
        let startReply = try bus.call(
            dest: Self.rdService, path: rdSession,
            interface: Self.sessionInterface, method: "Start",
            timeoutMs: SessionBus.setupTimeoutMs)
        dbus_message_unref(startReply)
        // Empty options: observe only — becoming owner is apply()'s
        // job, never enablement's.
        let enableReply = try bus.call(
            dest: Self.rdService, path: rdSession,
            interface: Self.sessionInterface, method: "EnableClipboard",
            timeoutMs: SessionBus.setupTimeoutMs,
            appendArgs: { iter in
                try self.bus.appendEmptyOptions(&iter)
            })
        dbus_message_unref(enableReply)

        // Mutter replays the STANDING selection owner right after
        // EnableClipboard. Pre-session clipboard content (passwords
        // included) is not the session's to report: drain and discard
        // the replay window, as the client re-baselines at start.
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
            print("""
                clipboard: standing pre-session selection NOT \
                announced (\(baselineReplaysSkipped) baseline \
                replay(s) skipped — consent starts now)
                """)
        }
    }

    /// A session is live: whatever changed on the host clipboard while
    /// none was is drained unread first (consent starts now), then
    /// foreign copies are read and reported through the callbacks.
    func attach() {
        service()
        attached = true
    }

    /// The session ended: stop reading foreign copies. Ownership and the
    /// owned bytes stay, so host pastes keep being served (`service()`
    /// between sessions) until another owner takes the selection.
    func detach() {
        attached = false
        if let read = pendingRead {
            close(read.fd)
            pendingRead = nil
            readsAbandoned += 1
        }
    }

    /// A client 0x1A landed (gate and book already ran): become the
    /// selection owner; the text is served lazily per SelectionTransfer.
    func apply(text: String) {
        owned = .text(Array(text.utf8))
        appliesTaken += 1
        setSelection(
            mimes: ClipboardTextMime.offered,
            byteCount: text.utf8.count
        )
    }

    /// A sha-verified client image landed: become the selection owner
    /// with the PNG flavor, served lazily like text.
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
            print("""
                clipboard: SetSelection failed (\(error)) — \
                apply dropped (\(byteCount) B)
                """)
        }
    }

    /// Drains queued D-Bus signals and pumps the transfer machines.
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
        if !isOwner {
            // Another owner took the selection: nothing is ours to serve.
            owned = .none
        }

        // A change always supersedes any read in flight.
        if let read = pendingRead {
            close(read.fd)
            pendingRead = nil
            readsAbandoned += 1
        }

        let kind: ReadKind
        let mime: String
        switch HostSelectionChange.judge(
            sessionLive: attached, sessionIsOwner: isOwner,
            offered: mimeTypes, imagesEnabled: imagesEnabled
        ) {
        case .ignoreOutsideSession:
            changesOutsideSessionSkipped += 1
            return
        case .reportOwnEcho:
            // The apply's echo: reported; the session's book suppresses it.
            switch owned {
            case .none:
                break
            case .text(let bytes):
                deliver(String(decoding: bytes, as: UTF8.self))
            case .image(let bytes):
                deliverImage(bytes)
            }
            return
        case .ignoreFlavor:
            nonTextChangesIgnored += 1
            return
        case .read(let flavor, let image):
            kind = image ? .image : .text
            mime = flavor
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
                fd: fd, kind: kind,
                stall: TransferStall(at: SystemMonotonicClock.nowSeconds))
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
                read.stall.progressed(at: SystemMonotonicClock.nowSeconds)
                read.buffer.append(contentsOf: scratch[0..<n])
                if read.buffer.count >= cap {
                    // Over the ceiling: deliver what we have; the session
                    // judges it overBudget and it never leaves.
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
                if read.stall.stalled(at: SystemMonotonicClock.nowSeconds) {
                    close(read.fd)
                    pendingRead = nil
                    readsAbandoned += 1
                    print("""
                        clipboard: selection read timed out \
                        (\(read.buffer.count) B partial, abandoned)
                        """)
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
                stall: TransferStall(at: SystemMonotonicClock.nowSeconds)))
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
                    write.stall.progressed(at: SystemMonotonicClock.nowSeconds)
                    continue
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if write.stall.stalled(at: SystemMonotonicClock.nowSeconds) {
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
                    print("""
                        clipboard: transfer serial \(write.serial) \
                        failed at \(write.offset)/\(write.data.count) B
                        """)
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
    /// SetSelection options shape).
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
                // Mutter wraps the list as "(as)"; unwrap one struct
                // level if present (a bare "as" also works).
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
