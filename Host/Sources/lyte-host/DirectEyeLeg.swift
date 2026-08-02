// DirectEyeLeg (direct-eye plan E1): the fused capture+encode backend
// — the doorbell paces it, HostEye grabs/blits/encodes on the Arc
// media engine, and encoded access units go straight to the session's
// sendFrame (or the probe file). No PipeWire, no portal, no Mutter:
// the compositor cannot wedge a register read.
//
// Honored session levers:
//   - forced-IDR demands (0x0302 / opening) → forceIDR encode
//   - capture timestamps: monotonic µs at ticket grab
//   - encoder rate directives (E6b): the directive's bit cap rides
//     the next frame's RC misc buffer — the native seat is the only
//     seat since the E5 demolition.

#if os(Linux)

import CDRM
import Foundation
import Glibc
import HostEye
import LyteWire

final class DirectEyeLeg {
    struct Config {
        var device = "/dev/dri/card1"
        var renderNode = "/dev/dri/renderD128"
        var seconds: Double
        var qp: Int32 = 24
        var pollUs: UInt32 = 1000
        /// Wire rate → the encoder's VBR envelope (0 = CQP).
        var bitrateBitsPerSecond: Int64 = 0
    }

    private let config: Config
    private let wire: SessionWire?
    private let file: UnsafeMutablePointer<FILE>?
    private(set) var frames = 0
    private(set) var firstPacket: [UInt8] = []
    private(set) var bytes = 0
    private(set) var keyframes = 0
    private(set) var missedGrabs = 0
    private(set) var directivesApplied = 0
    /// E5 audit GAP 1: forced-IDR demands arriving while the screen
    /// is static are served by re-encoding the last surface — armed
    /// here, counted for the books.
    private var staticIdrWanted = false
    private var lastEncodedSurface: UInt32?
    private var lastEncodedCaptureUs: UInt64 = 0
    private(set) var staticIdrsServed = 0
    /// E5 audit item 3: the quiet-desktop heartbeat cadence. One
    /// retained re-encode per second is enough to keep the clock
    /// model fed and the wire warm; the full-rate idle floor (and
    /// ratchet refinement) remain the portal's until post-E5 work.
    static let keepaliveSeconds = 1.0
    private var lastDeliveryWallSeconds = 0.0
    private(set) var keepalivesSent = 0
    /// E5 audit item 4: set when the leg ended because the display's
    /// geometry changed under it — a clean, deliberate exit, not an
    /// error.
    private(set) var modeChangeEnded = false
    private(set) var cursorShapesSeen = 0
    private(set) var cursorReadFailures = 0
    private(set) var cursorHotspotCorrections = 0
    /// E3 hotspot self-heal: the derivation at shape-change time uses
    /// the newest injected pointer against a cursor plane that can lag
    /// it by a frame mid-motion, so the derived hotspot can be off by
    /// the lag (the owner's "clicks land beside the arrow"). Once the
    /// pointer RESTS the compositor has settled the plane exactly at
    /// pointer − hotspot, so a re-read of the plane position gives the
    /// exact answer. One armed recheck per shape.
    private var lastCursorFrame: CursorFrame?
    private var sentHotspot: (x: Int, y: Int)?
    private var hotspotRecheckArmed = false
    var lastError: String?

    init(config: Config, wire: SessionWire?,
         file: UnsafeMutablePointer<FILE>?) {
        self.config = config
        self.wire = wire
        self.file = file
    }

    /// Blocking loop, portal-run-shaped: returns when the clock (or a
    /// session end / failure) says so.
    func run() {
        let fd = open(config.device, O_RDWR)
        guard fd >= 0 else {
            lastError = "direct: open(\(config.device)) errno \(errno)"
            return
        }
        defer { close(fd) }
        drmSetClientCap(fd, UInt64(DRM_CLIENT_CAP_UNIVERSAL_PLANES), 1)
        guard let planes = findActivePlanes(fd: fd) else {
            lastError = "direct: no active primary plane"
            return
        }
        guard let probe = grabTicket(fd: fd, fbId: planes.primary.fb) else {
            lastError = "direct: GETFB2 refused — the direct backend "
                + "needs CAP_SYS_ADMIN (run under sudo or the E4 unit)"
            return
        }
        let width = Int32(probe.width)
        let height = Int32(probe.height)
        probe.release()
        // HS-13: the uinput fallback maps absolute pointer coordinates
        // against the monitor extent — tell the wire what we captured
        // (the portal Sink used to do this at encoder open).
        wire?.noteMonitorExtent(
            width: UInt32(width), height: UInt32(height))

        // The encoder seat (E6b, sole occupant since the demolition):
        // the native VAAPI pens — zero libavcodec, rate directives
        // apply live (the RC misc buffer rides the next frame).
        let gl: EyeGL
        let encoder: EyeVaapiEncoder
        do {
            gl = try EyeGL(renderNode: config.renderNode)
            encoder = try EyeVaapiEncoder(
                width: width, height: height, fps: 60, qp: config.qp,
                renderNode: config.renderNode,
                bitrateBitsPerSecond: config.bitrateBitsPerSecond)
        } catch {
            lastError = "direct: init failed: \(error)"
            return
        }
        let rc = config.bitrateBitsPerSecond > 0
            ? "vbr \(config.bitrateBitsPerSecond / 1_000_000) Mbps cap"
            : "cqp \(config.qp)"
        print("direct: eye open — \(width)x\(height) on "
            + "\(config.device), native VAAPI \(rc) "
            + "(rate directives apply live)")

        // E3: the cursor plane travels as metadata, never as video.
        // The watcher shares the doorbell fd and cadence; a session-
        // less (file-mode) leg has no one to tell, so it skips.
        let cursorWatcher = wire != nil ? EyeCursorWatcher(fd: fd) : nil
        if wire != nil {
            print(cursorWatcher != nil
                ? "direct: cursor watcher on plane "
                    + "\(cursorWatcher!.planeId) — shapes ride 0x24"
                : "direct: no cursor plane — shapes OFF this run")
        }

        var targets: [UInt32: NV12Target] = [:]
        var lastFB: UInt32 = 0
        var pendingCauses: [String] = []
        let t0 = nowSeconds()
        var lastServiceAt = 0.0

        while nowSeconds() - t0 < config.seconds {
            if wire?.sessionEnded == true { break }
            // HS-18: an interrupted run (SIGINT/SIGTERM) exits through
            // the same door as a completed one, so the audio-routing
            // restore and the typed teardown both happen. (The portal
            // Sink polled this on its tick; the leg is the only poller
            // now that the Sink is demolished.)
            if lyteTerminationRequested != 0 {
                print("session: termination signal — closing cleanly")
                break
            }
            // The shell service cadence: the portal path drives
            // SessionWire.service() from its idle-floor tick, and the
            // agreed-time pendings (the 0x19 starting posture, the
            // standing 0x24 cursor shape, clipboard applies) flush
            // ONLY there — sendFrame's serviceOnce covers protocol
            // timers, not the shell. Without this, a direct leg whose
            // cursor never changes sends zero shapes (the E3 motion
            // leg's 0-sent books caught it).
            let now = nowSeconds()
            if now - lastServiceAt >= 0.010 {
                lastServiceAt = now
                wire?.service()
            }
            pollCursor(cursorWatcher)

            // Rate directives apply live: the cap becomes the VBR
            // envelope on the next frame's RC misc buffer.
            if let directive = wire?.takeEncoderRateDirective() {
                encoder.setRateBitsPerSecond(
                    Int64(directive.maxBitsPerSecond))
                directivesApplied += 1
                if directivesApplied == 1 {
                    print("direct: rate directive "
                        + "(\(directive.kind.rawValue)) applied — "
                        + "\(directive.maxBitsPerSecond / 1_000_000)"
                        + " Mbps cap")
                }
            }

            // E5 audit GAP 1: demands are taken EVERY poll, not only
            // when pixels change — a client recovering on a static
            // desktop must not wait for the next damage to get its
            // IDR. With no new fb, the last encoded surface still
            // holds the screen: re-encode it as the IDR, stamped with
            // its ORIGINAL capture time (the playout's retained-frame
            // law: recovery re-encodes are quality/dependency events,
            // not network-late frames).
            let demand = wire?.takeForcedIdrDemand() ?? []
            if !demand.isEmpty {
                pendingCauses += demand.names
                staticIdrWanted = true
            }

            guard let fb = currentFB(fd: fd, planeId: planes.primary.id),
                  fb != lastFB else {
                if staticIdrWanted, let sid = lastEncodedSurface {
                    do {
                        let packet = try encoder.encode(
                            surface: sid, forceIDR: true)
                        let causes = packet.keyframe ? pendingCauses : []
                        if packet.keyframe { pendingCauses.removeAll() }
                        deliver(Data(packet.data),
                                keyframe: packet.keyframe,
                                causes: causes,
                                captureUs: lastEncodedCaptureUs)
                        staticIdrWanted = false
                        staticIdrsServed += 1
                        lastDeliveryWallSeconds = nowSeconds()
                        print("direct: static-screen IDR served "
                            + "(re-encoded retained surface \(sid))")
                    } catch {
                        lastError = "direct: static IDR: \(error)"
                        return
                    }
                    continue
                }
                // E5 audit item 3 (minimal form): the idle keepalive.
                // A quiet desktop still supplies the wire one retained
                // re-encode per second — the clock model stays fed,
                // transit stays measurable across roams, and the
                // client's freshness logic sees a live host instead of
                // silence. ORIGINAL capture stamp (retained-frame
                // law), never an IDR, wire sessions only — file-mode
                // captures stay damage-driven so their books grade
                // the screen, not the heartbeat.
                if wire != nil, let sid = lastEncodedSurface,
                   nowSeconds() - lastDeliveryWallSeconds
                       >= Self.keepaliveSeconds {
                    do {
                        let packet = try encoder.encode(
                            surface: sid, forceIDR: false)
                        deliver(Data(packet.data),
                                keyframe: packet.keyframe,
                                causes: [],
                                captureUs: lastEncodedCaptureUs)
                        keepalivesSent += 1
                        lastDeliveryWallSeconds = nowSeconds()
                    } catch {
                        lastError = "direct: keepalive: \(error)"
                        return
                    }
                    continue
                }
                usleep(config.pollUs)
                continue
            }
            lastFB = fb
            guard let ticket = grabTicket(fd: fd, fbId: fb) else {
                missedGrabs += 1
                continue
            }
            // E5 audit item 4 (minimal form): a display mode change
            // mid-session arrives as tickets whose geometry no longer
            // matches the encoder's. Scaling them into the old-size
            // target would silently distort the picture; ending the
            // leg cleanly is the honest minimum — the session tears
            // down typed, the supervisor respawns the host, and the
            // client's existing auto-re-dial reads fresh geometry.
            // (In-place encoder re-open is the deluxe follow-up.)
            if Int32(ticket.width) != width
                || Int32(ticket.height) != height {
                ticket.release()
                print("direct: display mode changed \(width)x\(height)"
                    + " → \(ticket.width)x\(ticket.height) — ending "
                    + "session; the re-dial reads fresh geometry")
                modeChangeEnded = true
                return
            }
            let captureUs = UInt64(nowSeconds() * 1_000_000)

            let forceIdr = frames == 0 || staticIdrWanted
            staticIdrWanted = false
            if frames == 0 { pendingCauses.append("opening") }

            var ticketReleased = false
            do {
                var source = try gl.importTexture(
                    width: Int32(ticket.width),
                    height: Int32(ticket.height),
                    fourcc: ticket.fourcc, modifier: ticket.modifier,
                    planes: ticket.planes)
                func blitInto(
                    _ sid: UInt32,
                    export: () throws -> (y: ExportedPlane,
                                          uv: ExportedPlane)
                ) throws {
                    if targets[sid] == nil {
                        let exported = try export()
                        let target = try gl.makeNV12Target(
                            width: width, height: height,
                            yFourcc: exported.y.fourcc,
                            yModifier: exported.y.modifier,
                            yPlane: (exported.y.fd, exported.y.offset,
                                     exported.y.pitch),
                            uvFourcc: exported.uv.fourcc,
                            uvModifier: exported.uv.modifier,
                            uvPlane: (exported.uv.fd, exported.uv.offset,
                                      exported.uv.pitch))
                        close(exported.y.fd)
                        if exported.uv.fd != exported.y.fd {
                            close(exported.uv.fd)
                        }
                        targets[sid] = target
                    }
                    gl.blit(
                        source: source,
                        srcWidth: Int32(ticket.width),
                        srcHeight: Int32(ticket.height),
                        into: targets[sid]!)
                    gl.destroy(&source)
                    ticket.release()
                    ticketReleased = true
                }

                // Synchronous seat: vaSyncSurface inside encode
                // means the round-robin input is free by return —
                // no in-flight aliasing. 1-in-1-out: keyframe truth
                // rides ON THE PACKET, and the armed causes attach
                // to the IDR when it emerges.
                let sid = encoder.inputSurfaces[
                    frames % encoder.inputSurfaces.count]
                try blitInto(sid) { try encoder.exportSurface(sid) }
                let packet = try encoder.encode(
                    surface: sid, forceIDR: forceIdr)
                lastEncodedSurface = sid
                lastEncodedCaptureUs = captureUs
                let causes = packet.keyframe ? pendingCauses : []
                if packet.keyframe { pendingCauses.removeAll() }
                deliver(Data(packet.data), keyframe: packet.keyframe,
                        causes: causes, captureUs: captureUs)
                frames += 1
                lastDeliveryWallSeconds = nowSeconds()
            } catch {
                if !ticketReleased { ticket.release() }
                lastError = "direct: frame \(frames): \(error)"
                return
            }
        }

        // No drain: the native seat is 1-in-1-out; nothing is held
        // back at close.
        print("direct: eye closed — \(frames) frames, \(bytes) bytes, "
            + "\(keyframes) IDRs, missed_grabs=\(missedGrabs), "
            + "directives_applied=\(directivesApplied), "
            + "static_idrs=\(staticIdrsServed), "
            + "keepalives=\(keepalivesSent), "
            + "cursor_shapes=\(cursorShapesSeen), "
            + "hotspot_corrections=\(cursorHotspotCorrections)")
    }

    /// E3: one cursor poll — fb changes become 0x24s. The hotspot is
    /// recovered as (last injected pointer − plane CRTC − crop
    /// origin): the compositor places the plane at pointer − hotspot,
    /// and i915 has no HOTSPOT props to ask instead. Mid-motion the
    /// plane can lag the newest injection by a frame, so the derived
    /// point is clamped into the image; the next shape change
    /// re-derives it at rest.
    private func pollCursor(_ watcher: EyeCursorWatcher?) {
        guard let watcher, let wire else { return }
        switch watcher.poll() {
        case .unchanged:
            recheckHotspotAtRest(watcher, wire)
        case .hidden:
            cursorShapesSeen += 1
            lastCursorFrame = nil
            hotspotRecheckArmed = false
            wire.noteCursorShape(.hidden)
        case .shape(let frame):
            cursorShapesSeen += 1
            // The derivation ledger (2026-08-01) convicted the plane
            // position: this stack commits legacy cursor moves that
            // leave CRTC_X/Y at 0, so pointer − plane − crop slammed
            // into the clamp and stamped every hotspot bottom-right
            // (the owner's ~25 px aim offset). A (0,0) plane reading
            // with the pointer far away IS the lie's fingerprint —
            // fall back to the content top-left, which is the arrow's
            // true tip within a few pixels. (Exact per-shape hotspots
            // = the Xcursor theme matcher, filed as the real fix.)
            var hx = 0, hy = 0
            if let pointer = wire.lastAbsolutePointerInjection(),
               frame.planeCrtcX != 0 || frame.planeCrtcY != 0 {
                hx = Int(pointer.x.rounded())
                    - frame.planeCrtcX - frame.cropX
                hy = Int(pointer.y.rounded())
                    - frame.planeCrtcY - frame.cropY
            }
            hx = min(max(hx, 0), frame.width - 1)
            hy = min(max(hy, 0), frame.height - 1)
            // The derivation ledger (owner's ~25 px aim offset): the
            // first few shapes print their full inputs so a wrong
            // hotspot reads straight back to which term lied.
            if cursorShapesSeen <= 6 {
                let p = wire.lastAbsolutePointerInjection()
                print("direct: cursor derive #\(cursorShapesSeen): "
                    + "\(frame.width)x\(frame.height) "
                    + "crop(\(frame.cropX),\(frame.cropY)) "
                    + "plane(\(frame.planeCrtcX),\(frame.planeCrtcY)) "
                    + "pointer("
                    + (p.map { "\(Int($0.x)),\(Int($0.y))" } ?? "none")
                    + ") → hotspot(\(hx),\(hy))")
            }
            lastCursorFrame = frame
            sentHotspot = (hx, hy)
            hotspotRecheckArmed = true
            wire.noteCursorShape(CursorShape(
                width: UInt16(frame.width),
                height: UInt16(frame.height),
                hotspotX: UInt16(hx), hotspotY: UInt16(hy),
                pixels: frame.pixels))
        case .failed(let why):
            cursorReadFailures += 1
            if cursorReadFailures == 1 {
                print("direct: cursor read failed (\(why)) — counting")
            }
        }
    }

    /// The at-rest half of the hotspot derivation: 150 ms after the
    /// last pointer injection, plane position = pointer − hotspot
    /// EXACTLY, so recompute and re-send only if the mid-motion guess
    /// was wrong. The client wears the corrected shape; the session's
    /// dedupe passes it because the hotspot differs.
    private func recheckHotspotAtRest(
        _ watcher: EyeCursorWatcher, _ wire: SessionWire
    ) {
        guard hotspotRecheckArmed, let frame = lastCursorFrame,
              let sent = sentHotspot,
              let pointer = wire.lastAbsolutePointerInjection()
        else { return }
        let nowMicros = UInt64(nowSeconds() * 1_000_000)
        guard nowMicros &- pointer.atMicros > 150_000 else { return }
        guard let plane = watcher.planeCrtcPosition(),
              plane.x != 0 || plane.y != 0 else {
            // Same fingerprint as the derive path: a (0,0) plane is
            // the legacy-cursor lie — a rest recheck against it would
            // "correct" a good hotspot into garbage.
            hotspotRecheckArmed = false
            return
        }
        var hx = Int(pointer.x.rounded()) - plane.x - frame.cropX
        var hy = Int(pointer.y.rounded()) - plane.y - frame.cropY
        hx = min(max(hx, 0), frame.width - 1)
        hy = min(max(hy, 0), frame.height - 1)
        hotspotRecheckArmed = false
        guard hx != sent.x || hy != sent.y else { return }
        cursorHotspotCorrections += 1
        print("direct: cursor hotspot corrected "
            + "(\(sent.x),\(sent.y)) → (\(hx),\(hy)) at rest — "
            + "plane(\(plane.x),\(plane.y)) "
            + "pointer(\(Int(pointer.x)),\(Int(pointer.y)))")
        sentHotspot = (hx, hy)
        wire.noteCursorShape(CursorShape(
            width: UInt16(frame.width),
            height: UInt16(frame.height),
            hotspotX: UInt16(hx), hotspotY: UInt16(hy),
            pixels: frame.pixels))
    }

    private func deliver(_ packet: Data, keyframe: Bool,
                         causes: [String], captureUs: UInt64) {
        packet.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            if firstPacket.isEmpty {
                firstPacket = Array(raw.bindMemory(to: UInt8.self))
            }
            if let wire {
                do {
                    try wire.sendFrame(
                        data: base, size: packet.count,
                        isKeyframe: keyframe, captureMicros: captureUs)
                    wire.annotateLastVideoFrame(
                        averageQP: nil,
                        idrCauses: keyframe
                            ? (causes.isEmpty ? ["spontaneous"] : causes)
                            : [])
                } catch {
                    lastError = "direct: session send failed: \(error)"
                    return
                }
            } else if let file {
                fwrite(base, 1, packet.count, file)
            }
        }
        bytes += packet.count
        if keyframe { keyframes += 1 }
    }
}

#endif
