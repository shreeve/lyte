// CP-5 SPIKE (throwaway wiring, rigorous findings): prove or disprove headless
// input injection via RemoteDesktop on GNOME/Mutter, feeding the HS-13 verdict.
//
// Reachable as:  lyte-host rd-spike [--portal|--mutter] [--start-only]
//                                   [--keyboard] [--seconds N] [--fresh]
//
// Two backends:
//   --portal  org.freedesktop.portal.RemoteDesktop v2 — the sanctioned xdg path
//             and a consent surface. On this GNOME its combined Start is
//             auto-denied headless (Response 1); kept so the finding is
//             reproducible and to re-test on non-GNOME targets.
//   --mutter  org.gnome.Mutter.RemoteDesktop — GNOME-internal, the API family
//             gnome-remote-desktop itself uses. Runs fully headless over ssh:
//             no consent dialog, no token. The recommended HS-13 primary.
//
// PORTAL flow (combined ScreenCast + RemoteDesktop on ONE session, one Start):
//   RemoteDesktop.CreateSession
//   RemoteDesktop.SelectDevices   (types=KEYBOARD|POINTER, persist_mode=2,
//                                  restore_token if we have one)
//   ScreenCast.SelectSources      (MONITOR, cursor_mode=EMBEDDED)  — SAME session
//   RemoteDesktop.Start           (returns SC streams + RD restore_token)
//   ScreenCast.OpenPipeWireRemote (pipewire fd)
//   then NotifyPointerMotionAbsolute / NotifyKeyboardKeycode on the session.
//
// Evidence for "did injection land" without a human at the screen: the cursor
// is EMBEDDED in the captured frames, so we move the pointer to two known
// positions, snapshot the frames, and diff the pixels. A localized pixel
// change whose centroid tracks the commanded position is bulletproof.
//
// The RD/combined restore token persists to ~/.config/lyte-host/portal_rd_token
// so we NEVER touch the ScreenCast video pipeline's ~/.config/lyte-host/portal_token.

import CDBus
import CHevcEncode
import CPipeWireCapture
import Foundation

private let dTypeDouble: Int32 = 100 // 'd'
private let dTypeInt32: Int32 = 105  // 'i'

enum RDBackend: String {
    case portal   // org.freedesktop.portal.RemoteDesktop v2 (consent surface)
    case mutter   // org.gnome.Mutter.RemoteDesktop (GNOME-internal, no dialog)
}

struct RDSpikeOptions {
    var seconds = 6.0
    var fresh = false        // ignore any saved RD token (force fresh grant)
    var startOnly = false    // Q1/Q4 only: session lifecycle, no capture/inject
    var keyboard = false     // also fire a NotifyKeyboardKeycode burst
    var backend: RDBackend = .portal

    static func parse(_ args: [String]) -> RDSpikeOptions {
        var o = RDSpikeOptions()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--seconds": i += 1; if i < args.count, let v = Double(args[i]) { o.seconds = v }
            case "--fresh": o.fresh = true
            case "--start-only": o.startOnly = true
            case "--keyboard": o.keyboard = true
            case "--mutter": o.backend = .mutter
            case "--portal": o.backend = .portal
            default: break
            }
            i += 1
        }
        return o
    }
}

/// GNOME-internal RemoteDesktop (org.gnome.Mutter.RemoteDesktop). This is the
/// no-consent counterpart to MutterScreenCast: a RemoteDesktop session, a
/// ScreenCast session linked to it by SessionId, one RD.Start that brings up
/// both, and Notify* injection on the RD session. Proven to run fully headless
/// over ssh (CP-5). The ScreenCast stream object path is the `stream` argument
/// to NotifyPointerMotionAbsolute.
final class MutterRemoteDesktop {
    let bus: SessionBus
    private(set) var rdSession = ""
    private(set) var scSession = ""
    private(set) var streamPath = ""

    private static let rdService = "org.gnome.Mutter.RemoteDesktop"
    private static let scService = "org.gnome.Mutter.ScreenCast"

    init(sharing bus: SessionBus) { self.bus = bus }

    /// Returns the PipeWire node id for the recorded monitor.
    func openCombined() throws -> UInt32 {
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

        let recReply = try bus.call(
            dest: Self.scService, path: scSession,
            interface: "org.gnome.Mutter.ScreenCast.Session", method: "RecordMonitor",
            appendArgs: { iter in
                try self.bus.appendString(&iter, "") // primary monitor
                try self.bus.appendOptions(&iter, [("cursor-mode", .u32(1))]) // EMBEDDED
            })
        streamPath = try SessionBus.objectPathReply(recReply)
        dbus_message_unref(recReply)

        try bus.addMatch("type='signal',interface='org.gnome.Mutter.ScreenCast.Stream',"
            + "member='PipeWireStreamAdded',path='\(streamPath)'")

        // RD.Start brings up the linked SC stream too (SC.Start would fail:
        // "Must be started from remote desktop session").
        let startReply = try bus.call(
            dest: Self.rdService, path: rdSession,
            interface: "org.gnome.Mutter.RemoteDesktop.Session", method: "Start")
        dbus_message_unref(startReply)

        return try bus.waitForUInt32Signal(
            interface: "org.gnome.Mutter.ScreenCast.Stream",
            member: "PipeWireStreamAdded", path: streamPath, timeout: 15)
    }

    private func sessionIdProperty() throws -> String {
        guard let msg = dbus_message_new_method_call(
            Self.rdService, rdSession, "org.freedesktop.DBus.Properties", "Get")
        else { throw HostError("cannot alloc Properties.Get") }
        defer { dbus_message_unref(msg) }
        var iter = DBusMessageIter()
        dbus_message_iter_init_append(msg, &iter)
        try bus.appendString(&iter, "org.gnome.Mutter.RemoteDesktop.Session")
        try bus.appendString(&iter, "SessionId")
        var err = DBusError(); dbus_error_init(&err)
        guard let reply = dbus_connection_send_with_reply_and_block(bus.conn, msg, 5000, &err)
        else { dbus_error_free(&err); throw HostError("SessionId Get failed") }
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

    private func notify(_ method: String,
                        _ extra: (inout DBusMessageIter) throws -> Void) throws {
        guard let msg = dbus_message_new_method_call(
            Self.rdService, rdSession,
            "org.gnome.Mutter.RemoteDesktop.Session", method)
        else { throw HostError("cannot alloc \(method)") }
        defer { dbus_message_unref(msg) }
        var iter = DBusMessageIter()
        dbus_message_iter_init_append(msg, &iter)
        try extra(&iter)
        var err = DBusError(); dbus_error_init(&err)
        guard let reply = dbus_connection_send_with_reply_and_block(bus.conn, msg, 5000, &err)
        else {
            let n = err.name.map { String(cString: $0) } ?? "?"
            let m = err.message.map { String(cString: $0) } ?? "?"
            dbus_error_free(&err)
            throw HostError("\(method) failed: \(n): \(m)")
        }
        dbus_message_unref(reply)
    }

    func movePointerAbsolute(x: Double, y: Double) throws {
        try notify("NotifyPointerMotionAbsolute") { iter in
            try self.bus.appendString(&iter, self.streamPath)
            var xx = x; dbus_message_iter_append_basic(&iter, dTypeDouble, &xx)
            var yy = y; dbus_message_iter_append_basic(&iter, dTypeDouble, &yy)
        }
    }

    func keyboardKeycode(_ keycode: UInt32, pressed: Bool) throws {
        try notify("NotifyKeyboardKeycode") { iter in
            var kc = keycode; dbus_message_iter_append_basic(&iter, DType.uint32, &kc)
            var st: dbus_bool_t = pressed ? 1 : 0
            dbus_message_iter_append_basic(&iter, DType.boolean, &st)
        }
    }

    func stop() {
        guard !rdSession.isEmpty else { return }
        if let r = try? bus.call(
            dest: Self.rdService, path: rdSession,
            interface: "org.gnome.Mutter.RemoteDesktop.Session", method: "Stop") {
            dbus_message_unref(r)
        }
    }
}

final class RemoteDesktopSpike {
    private let bus: SessionBus
    private let opts: RDSpikeOptions
    private var tokenCounter = 0

    static let rdTokenPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lyte-host/portal_rd_token")

    // Capture + injection evidence state (all touched only on the PW loop thread).
    var capture: OpaquePointer?
    var streamNode: UInt32 = 0
    var sessionHandle = ""
    var mutterRD: MutterRemoteDesktop?  // set when --mutter backend is used

    var width: UInt32 = 0
    var height: UInt32 = 0
    var stride: Int32 = 0
    var latest: [UInt8] = []
    var latestAt: Double = 0
    var frames = 0
    var firstFrameAt: Double?

    enum Phase { case settling, movedP1, movedP2, done }
    var phase: Phase = .settling
    var t0: Double = 0
    var frameA: [UInt8] = []       // baseline (cursor at origin-ish)
    var frameP1: [UInt8] = []      // after move to P1
    var frameP2: [UInt8] = []      // after move to P2
    var p1 = (x: 0.0, y: 0.0)
    var p2 = (x: 0.0, y: 0.0)

    // Latency probe: after issuing a move, watch for the first frame that
    // differs from the pre-move reference; record notify→visible delta.
    var watching = false
    var watchRef: [UInt8] = []
    var watchAt: Double = 0
    var watchLatencyMs: Double?
    var keyboardFiredAt: Double?

    init(opts: RDSpikeOptions) throws {
        self.opts = opts
        bus = try SessionBus()
    }

    // MARK: - Public entry

    func run() throws {
        if opts.backend == .mutter { try runMutter(); return }
        print("== lyte rd-spike : xdg RemoteDesktop v2 headless injection probe (backend=portal) ==")
        print("RD token path: \(Self.rdTokenPath.path)  (SC video token untouched)")

        let session = try createSession()
        sessionHandle = session

        let hadToken = (loadRDToken() != nil) && !opts.fresh
        try selectDevices(session: session)
        if !opts.startOnly {
            try selectSources(session: session)
        }
        let (nodes, token) = try start(session: session, hadToken: hadToken)
        if let token { saveRDToken(token) }

        print("Q1 RESULT: combined RemoteDesktop+ScreenCast session STARTED headlessly "
            + "over ssh. streams=\(nodes) rd_restore_token=\(token != nil ? "returned" : "none")")

        if opts.startOnly {
            print("--start-only: session established; skipping capture/injection.")
            return
        }
        guard let node = nodes.first else {
            throw HostError("Start returned no ScreenCast stream node; cannot gather frame evidence")
        }
        streamNode = node
        let fd = try openPipeWireRemote(session: session)
        print("ScreenCast pipewire fd=\(fd) node=\(node)")

        try captureAndInject(pipewireFd: fd, node: node)
        reportEvidence()
    }

    // MARK: - Mutter-internal backend (no consent dialog)

    private func runMutter() throws {
        print("== lyte rd-spike : GNOME-internal RemoteDesktop injection probe (backend=mutter) ==")
        let rd = MutterRemoteDesktop(sharing: bus)
        mutterRD = rd
        let node = try rd.openCombined()
        print("Q1 RESULT (mutter): combined org.gnome.Mutter RemoteDesktop+ScreenCast "
            + "session STARTED headlessly over ssh, NO consent dialog. "
            + "rd_session=\(rd.rdSession) stream=\(rd.streamPath) node=\(node)")
        if opts.startOnly {
            print("--start-only: session established; skipping capture/injection.")
            rd.stop()
            return
        }
        streamNode = node
        // Mutter publishes the node on the default PipeWire remote; capture
        // connects with fd < 0 to reach it (same as MutterScreenCast).
        try captureAndInject(pipewireFd: -1, node: node)
        reportEvidence()
        rd.stop()
    }

    // MARK: - Portal session flow

    private func prepareRequest() throws -> (handleToken: String, requestPath: String) {
        tokenCounter += 1
        let handleToken = "lyte_rd_\(tokenCounter)"
        let requestPath = "/org/freedesktop/portal/desktop/request/"
            + bus.senderToken + "/" + handleToken
        try bus.addMatch("type='signal',interface='org.freedesktop.portal.Request',"
            + "member='Response',path='\(requestPath)'")
        return (handleToken, requestPath)
    }

    private func createSession() throws -> String {
        let (handleToken, requestPath) = try prepareRequest()
        let reply = try bus.callPortal(
            interface: "org.freedesktop.portal.RemoteDesktop",
            method: "CreateSession",
            options: [
                ("handle_token", .string(handleToken)),
                ("session_handle_token", .string("lyte_rd_session")),
            ])
        dbus_message_unref(reply)
        let (code, results) = try bus.waitForResponse(requestPath: requestPath, timeout: 30)
        print("RemoteDesktop.CreateSession → Response code \(code)")
        guard code == 0, let s = results.sessionHandle else {
            throw HostError("CreateSession failed (code \(code))")
        }
        return s
    }

    private func selectDevices(session: String) throws {
        let (handleToken, requestPath) = try prepareRequest()
        var options: [(String, DBusVariant)] = [
            ("handle_token", .string(handleToken)),
            ("types", .u32(3)),        // KEYBOARD(1) | POINTER(2)
            ("persist_mode", .u32(2)), // PERSISTENT (v2)
        ]
        if let token = loadRDToken(), !opts.fresh {
            options.append(("restore_token", .string(token)))
            print("RemoteDesktop.SelectDevices: presenting saved RD restore token")
        } else {
            print("RemoteDesktop.SelectDevices: no token (fresh grant path)")
        }
        let reply = try bus.callPortal(
            interface: "org.freedesktop.portal.RemoteDesktop",
            method: "SelectDevices",
            objectPathArgs: [session],
            options: options)
        dbus_message_unref(reply)
        let (code, _) = try bus.waitForResponse(requestPath: requestPath, timeout: 30)
        print("RemoteDesktop.SelectDevices → Response code \(code)")
        guard code == 0 else { throw HostError("SelectDevices failed (code \(code))") }
    }

    private func selectSources(session: String) throws {
        let (handleToken, requestPath) = try prepareRequest()
        let options: [(String, DBusVariant)] = [
            ("handle_token", .string(handleToken)),
            ("types", .u32(1)),        // MONITOR
            ("multiple", .bool(false)),
            ("cursor_mode", .u32(2)),  // EMBEDDED — cursor rendered into frames
        ]
        let reply = try bus.callPortal(
            interface: "org.freedesktop.portal.ScreenCast",
            method: "SelectSources",
            objectPathArgs: [session],
            options: options)
        dbus_message_unref(reply)
        let (code, _) = try bus.waitForResponse(requestPath: requestPath, timeout: 30)
        print("ScreenCast.SelectSources (same session) → Response code \(code)")
        guard code == 0 else { throw HostError("SelectSources failed (code \(code))") }
    }

    private func start(session: String, hadToken: Bool)
        throws -> (nodes: [UInt32], token: String?) {
        let (handleToken, requestPath) = try prepareRequest()
        let reply = try bus.callPortal(
            interface: "org.freedesktop.portal.RemoteDesktop",
            method: "Start",
            objectPathArgs: [session],
            stringArgs: [""], // parent_window: none (headless)
            options: [("handle_token", .string(handleToken))])
        dbus_message_unref(reply)

        var consentHint = false
        let (code, results) = try bus.waitForResponse(
            requestPath: requestPath, timeout: 90,
            onWaiting: {
                consentHint = true
                print("RemoteDesktop.Start: waiting… if this blocks, a one-time "
                    + "consent dialog is pending on the host's PHYSICAL screen"
                    + (hadToken ? " (unexpected: we presented a restore token)" : ""))
            })
        print("RemoteDesktop.Start → Response code \(code)"
            + (consentHint ? "  (waited: dialog may have been required)" : "  (immediate)"))
        guard code == 0 else {
            throw HostError("Start failed (code \(code)) — "
                + (code == 1 ? "cancelled/denied on the host's screen"
                             : "portal refused; a physical consent click is likely required"))
        }
        return (results.streamNodeIds, results.restoreToken)
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

    // MARK: - Notify* input injection (raw libdbus; these return void)

    private func notify(method: String, extra: (inout DBusMessageIter) throws -> Void) throws {
        guard let msg = dbus_message_new_method_call(
            "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
            "org.freedesktop.portal.RemoteDesktop", method)
        else { throw HostError("cannot alloc \(method)") }
        defer { dbus_message_unref(msg) }
        var iter = DBusMessageIter()
        dbus_message_iter_init_append(msg, &iter)
        try bus.appendString(&iter, sessionHandle, type: DType.objectPath)
        try bus.appendOptions(&iter, [])
        try extra(&iter)
        var err = DBusError(); dbus_error_init(&err)
        guard let reply = dbus_connection_send_with_reply_and_block(bus.conn, msg, 5000, &err)
        else {
            let n = err.name.map { String(cString: $0) } ?? "?"
            let m = err.message.map { String(cString: $0) } ?? "?"
            dbus_error_free(&err)
            throw HostError("\(method) failed: \(n): \(m)")
        }
        dbus_message_unref(reply)
    }

    private func appendU32(_ iter: inout DBusMessageIter, _ v: UInt32) {
        var x = v; dbus_message_iter_append_basic(&iter, DType.uint32, &x)
    }
    private func appendDouble(_ iter: inout DBusMessageIter, _ v: Double) {
        var x = v; dbus_message_iter_append_basic(&iter, dTypeDouble, &x)
    }
    private func appendI32(_ iter: inout DBusMessageIter, _ v: Int32) {
        var x = v; dbus_message_iter_append_basic(&iter, dTypeInt32, &x)
    }

    /// NotifyPointerMotionAbsolute(session, options, u stream, d x, d y)
    func movePointerAbsolute(x: Double, y: Double) throws {
        if let rd = mutterRD { try rd.movePointerAbsolute(x: x, y: y); return }
        try notify(method: "NotifyPointerMotionAbsolute") { iter in
            self.appendU32(&iter, self.streamNode)
            self.appendDouble(&iter, x)
            self.appendDouble(&iter, y)
        }
    }

    /// NotifyKeyboardKeycode(session, options, i keycode, u state)
    func keyboardKeycode(_ keycode: Int32, pressed: Bool) throws {
        if let rd = mutterRD { try rd.keyboardKeycode(UInt32(keycode), pressed: pressed); return }
        try notify(method: "NotifyKeyboardKeycode") { iter in
            self.appendI32(&iter, keycode)
            self.appendU32(&iter, pressed ? 1 : 0)
        }
    }

    // MARK: - Capture + injection driver

    private func captureAndInject(pipewireFd: Int32, node: UInt32) throws {
        var err = [CChar](repeating: 0, count: 256)
        let user = Unmanaged.passUnretained(self).toOpaque()
        guard let cap = lyte_pw_capture_new(pipewireFd, node,
                                            rdFrameTrampoline, user,
                                            &err, err.count) else {
            throw HostError("pipewire capture setup failed: \(errString(err))")
        }
        capture = cap
        // 30 Hz tick drives the injection state machine on the loop thread.
        _ = lyte_pw_capture_set_tick(cap, UInt64(1_000_000_000) / 30, rdTickTrampoline, user)
        let rc = lyte_pw_capture_run(cap, opts.seconds + 15, &err, err.count)
        if rc == -1 { throw HostError("capture failed: \(errString(err))") }
    }

    func onFrame(data: UnsafePointer<UInt8>, size: UInt32, stride: Int32,
                 width: UInt32, height: UInt32) {
        let now = monotonicNow()
        if firstFrameAt == nil { firstFrameAt = now; t0 = now }
        self.width = width; self.height = height; self.stride = stride
        let count = Int(size)
        if latest.count != count { latest = [UInt8](repeating: 0, count: count) }
        latest.withUnsafeMutableBytes { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(start: data, count: count))
        }
        latestAt = now
        frames += 1

        if watching, !watchRef.isEmpty, watchRef.count == count {
            let changed = data.withMemoryRebound(to: UInt8.self, capacity: count) { _ in
                RemoteDesktopSpike.changedPixels(watchRef, latest, stride: Int(stride),
                                                 width: Int(width), height: Int(height)).count
            }
            if changed > 20 {
                watchLatencyMs = (now - watchAt) * 1000
                watching = false
            }
        }
    }

    func onTick() {
        guard firstFrameAt != nil, !latest.isEmpty else { return }
        let now = monotonicNow()
        switch phase {
        case .settling:
            if now - t0 >= 1.0 {
                frameA = latest
                p1 = (Double(width) * 0.25, Double(height) * 0.25)
                beginWatch()
                try? movePointerAbsolute(x: p1.x, y: p1.y)
                print(String(format: "inject: NotifyPointerMotionAbsolute → P1 (%.0f, %.0f)", p1.x, p1.y))
                phase = .movedP1
                t0 = now
            }
        case .movedP1:
            if now - t0 >= 1.2 {
                frameP1 = latest
                p2 = (Double(width) * 0.75, Double(height) * 0.75)
                try? movePointerAbsolute(x: p2.x, y: p2.y)
                print(String(format: "inject: NotifyPointerMotionAbsolute → P2 (%.0f, %.0f)", p2.x, p2.y))
                if opts.keyboard {
                    keyboardFiredAt = now
                    // KEY_A=30 evdev; harmless burst into whatever is focused.
                    try? keyboardKeycode(30, pressed: true)
                    try? keyboardKeycode(30, pressed: false)
                    print("inject: NotifyKeyboardKeycode KEY_A down/up fired")
                }
                phase = .movedP2
                t0 = now
            }
        case .movedP2:
            if now - t0 >= 1.2 {
                frameP2 = latest
                phase = .done
                if let cap = capture { lyte_pw_capture_quit(cap) }
            }
        case .done:
            break
        }
    }

    private func beginWatch() {
        watchRef = latest
        watchAt = monotonicNow()
        watching = true
        watchLatencyMs = nil
    }

    // MARK: - Evidence report

    private func reportEvidence() {
        print("\n== EVIDENCE ==")
        print("frames captured: \(frames), resolution \(width)x\(height), stride \(stride)")
        guard !frameA.isEmpty, !frameP1.isEmpty, !frameP2.isEmpty else {
            print("Q2 RESULT: INCONCLUSIVE — not all snapshots captured (frames may be too sparse)")
            return
        }
        dumpRaw(frameA, "/tmp/rd_frameA.raw")
        dumpRaw(frameP1, "/tmp/rd_frameP1.raw")
        dumpRaw(frameP2, "/tmp/rd_frameP2.raw")

        let w = Int(width), h = Int(height), st = Int(stride)
        let d1 = Self.changedPixels(frameA, frameP1, stride: st, width: w, height: h)
        let d2 = Self.changedPixels(frameP1, frameP2, stride: st, width: w, height: h)
        report(diff: d1, label: "A→P1", target: p1)
        report(diff: d2, label: "P1→P2", target: p2)

        // Verdict: injection proven if each diff's centroid lands near its
        // commanded target (within a generous cursor-sized tolerance).
        let ok1 = near(centroid(d1), p1, tol: max(Double(w), Double(h)) * 0.12)
        let ok2 = near(centroid(d2), p2, tol: max(Double(w), Double(h)) * 0.12)
        if ok1 || ok2 {
            print("Q2 RESULT: PASS — pointer motion injected via RemoteDesktop moved the "
                + "EMBEDDED cursor to the commanded coordinates (frame-diff centroid matches).")
        } else if !d1.isEmpty || !d2.isEmpty {
            print("Q2 RESULT: PARTIAL — frames changed after injection but centroid did not "
                + "land on target; see coordinates above (cursor may be off, or damage global).")
        } else {
            print("Q2 RESULT: FAIL — no pixel change after pointer injection; motion did not land.")
        }
        if let lat = watchLatencyMs {
            print(String(format: "Q3 RESULT: injection→visible latency ≈ %.0f ms "
                + "(NotifyPointerMotionAbsolute call → first changed captured frame)", lat))
        } else {
            print("Q3 RESULT: latency not measured (no frame delta observed while watching)")
        }
    }

    private func report(diff: [(x: Int, y: Int)], label: String, target: (x: Double, y: Double)) {
        guard !diff.isEmpty else {
            print("  \(label): no changed pixels")
            return
        }
        let xs = diff.map { $0.x }, ys = diff.map { $0.y }
        let c = centroid(diff)
        print(String(format: "  %@: %d changed px, bbox x[%d..%d] y[%d..%d], "
            + "centroid (%.0f, %.0f), target (%.0f, %.0f)",
            label, diff.count, xs.min()!, xs.max()!, ys.min()!, ys.max()!,
            c.x, c.y, target.x, target.y))
    }

    private func centroid(_ d: [(x: Int, y: Int)]) -> (x: Double, y: Double) {
        guard !d.isEmpty else { return (-1, -1) }
        let sx = d.reduce(0) { $0 + $1.x }, sy = d.reduce(0) { $0 + $1.y }
        return (Double(sx) / Double(d.count), Double(sy) / Double(d.count))
    }
    private func near(_ c: (x: Double, y: Double), _ t: (x: Double, y: Double), tol: Double) -> Bool {
        c.x >= 0 && abs(c.x - t.x) <= tol && abs(c.y - t.y) <= tol
    }

    /// Returns coordinates of pixels differing beyond a per-byte threshold.
    /// 32bpp packed; compares the RGB bytes of each pixel.
    static func changedPixels(_ a: [UInt8], _ b: [UInt8], stride: Int,
                              width: Int, height: Int) -> [(x: Int, y: Int)] {
        var out: [(x: Int, y: Int)] = []
        guard a.count == b.count, stride >= width * 4 else { return out }
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for y in 0..<height {
                    let row = y * stride
                    for x in 0..<width {
                        let i = row + x * 4
                        let dr = Int(pa[i]) - Int(pb[i])
                        let dg = Int(pa[i+1]) - Int(pb[i+1])
                        let db = Int(pa[i+2]) - Int(pb[i+2])
                        if abs(dr) + abs(dg) + abs(db) > 48 { out.append((x, y)) }
                    }
                }
            }
        }
        return out
    }

    private func dumpRaw(_ frame: [UInt8], _ path: String) {
        FileManager.default.createFile(atPath: path, contents: Data(frame))
    }

    // MARK: - RD token persistence (separate file from the SC video token)

    private func loadRDToken() -> String? {
        guard let t = try? String(contentsOf: Self.rdTokenPath, encoding: .utf8) else { return nil }
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private func saveRDToken(_ token: String) {
        do {
            try FileManager.default.createDirectory(
                at: Self.rdTokenPath.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try token.write(to: Self.rdTokenPath, atomically: true, encoding: .utf8)
            print("RD restore token saved → \(Self.rdTokenPath.path)")
        } catch {
            print("warning: could not persist RD restore token: \(error)")
        }
    }
}

private func rdFrameTrampoline(user: UnsafeMutableRawPointer?,
                               data: UnsafePointer<UInt8>?, size: UInt32,
                               stride: Int32, width: UInt32, height: UInt32,
                               fmt: lyte_pixfmt, graphUs: UInt64) {
    guard let user, let data else { return }
    let spike = Unmanaged<RemoteDesktopSpike>.fromOpaque(user).takeUnretainedValue()
    spike.onFrame(data: data, size: size, stride: stride, width: width, height: height)
}

private func rdTickTrampoline(user: UnsafeMutableRawPointer?) {
    guard let user else { return }
    let spike = Unmanaged<RemoteDesktopSpike>.fromOpaque(user).takeUnretainedValue()
    spike.onTick()
}

func rdSpikeMain(_ args: [String]) {
    lyte_stdout_linebuf()
    let opts = RDSpikeOptions.parse(args)
    do {
        let spike = try RemoteDesktopSpike(opts: opts)
        try spike.run()
        lyte_stdout_flush()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("rd-spike: error: \(error)\n".utf8))
        exit(1)
    }
}
