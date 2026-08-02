// DirectEyeLeg (direct-eye plan E1): the fused capture+encode backend
// — the doorbell paces it, HostEye grabs/blits/encodes on the Arc
// media engine, and encoded access units go straight to the session's
// sendFrame (or the probe file). No PipeWire, no portal, no Mutter:
// the compositor cannot wedge a register read.
//
// Honored session levers:
//   - forced-IDR demands (0x0302 / opening) → forceIDR encode
//   - capture timestamps: monotonic µs at ticket grab
//   - encoder rate directives — NATIVE seat only (E6b): the directive's
//     bit cap rides the next frame's RC misc buffer. The libav seat
//     still defers (hevc_vaapi takes rate control at open() only);
//     it exists as scaffolding until the demolition PR.

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
        /// E6b: EyeVaapiEncoder in the encoder seat — zero
        /// libavcodec, and rate directives APPLY live instead of
        /// deferring (the RC misc buffer rides the next frame).
        var nativeEncoder = false
    }

    private let config: Config
    private let wire: SessionWire?
    private let file: UnsafeMutablePointer<FILE>?
    private(set) var frames = 0
    private(set) var firstPacket: [UInt8] = []
    private(set) var bytes = 0
    private(set) var keyframes = 0
    private(set) var missedGrabs = 0
    private(set) var directivesDeferred = 0
    private(set) var directivesApplied = 0
    private(set) var cursorShapesSeen = 0
    private(set) var cursorReadFailures = 0
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

        // The encoder seat: the native pens (E6b) or the libav
        // scaffolding (E1). One enum, so every use site states which
        // truths differ — surface acquisition, rate directives, drain.
        enum Seat {
            case libav(EyeEncoder)
            case native(EyeVaapiEncoder)
        }
        let gl: EyeGL
        let seat: Seat
        do {
            gl = try EyeGL(renderNode: config.renderNode)
            if config.nativeEncoder {
                seat = .native(try EyeVaapiEncoder(
                    width: width, height: height, fps: 60, qp: config.qp,
                    renderNode: config.renderNode,
                    bitrateBitsPerSecond: config.bitrateBitsPerSecond))
            } else {
                seat = .libav(try EyeEncoder(
                    width: width, height: height, fps: 60, qp: config.qp,
                    renderNode: config.renderNode,
                    bitrateBitsPerSecond: config.bitrateBitsPerSecond))
            }
        } catch {
            lastError = "direct: init failed: \(error)"
            return
        }
        let rc = config.bitrateBitsPerSecond > 0
            ? "vbr \(config.bitrateBitsPerSecond / 1_000_000) Mbps cap"
            : "cqp \(config.qp)"
        switch seat {
        case .native:
            print("direct: eye open — \(width)x\(height) on "
                + "\(config.device), native VAAPI \(rc) "
                + "(rate directives apply live)")
        case .libav:
            print("direct: eye open — \(width)x\(height) on "
                + "\(config.device), hevc_vaapi \(rc) "
                + "(live rate directives deferred — retiring seat)")
        }

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

            // Rate directives: the native seat APPLIES them — the cap
            // becomes the VBR envelope on the next frame's RC misc
            // buffer. The libav seat consumes-and-counts so the queue
            // still drains.
            if let directive = wire?.takeEncoderRateDirective() {
                switch seat {
                case .native(let encoder):
                    encoder.setRateBitsPerSecond(
                        Int64(directive.maxBitsPerSecond))
                    directivesApplied += 1
                    if directivesApplied == 1 {
                        print("direct: rate directive "
                            + "(\(directive.kind.rawValue)) applied — "
                            + "\(directive.maxBitsPerSecond / 1_000_000)"
                            + " Mbps cap")
                    }
                case .libav:
                    directivesDeferred += 1
                    if directivesDeferred == 1 {
                        print("direct: rate directive "
                            + "(\(directive.kind.rawValue)) deferred — "
                            + "libav seat is CQP-only; counting")
                    }
                }
            }

            guard let fb = currentFB(fd: fd, planeId: planes.primary.id),
                  fb != lastFB else {
                usleep(config.pollUs)
                continue
            }
            lastFB = fb
            guard let ticket = grabTicket(fd: fd, fbId: fb) else {
                missedGrabs += 1
                continue
            }
            let captureUs = UInt64(nowSeconds() * 1_000_000)

            let demand = wire?.takeForcedIdrDemand() ?? []
            let forceIdr = frames == 0 || !demand.isEmpty
            if frames == 0 { pendingCauses.append("opening") }
            pendingCauses += demand.names

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

                let packets: [(data: Data, keyframe: Bool)]
                switch seat {
                case .native(let encoder):
                    // Synchronous seat: vaSyncSurface inside encode
                    // means the round-robin input is free by return —
                    // no in-flight aliasing.
                    let sid = encoder.inputSurfaces[
                        frames % encoder.inputSurfaces.count]
                    try blitInto(sid) { try encoder.exportSurface(sid) }
                    let one = try encoder.encode(
                        surface: sid, forceIDR: forceIdr)
                    packets = [(Data(one.data), one.keyframe)]
                case .libav(let encoder):
                    let frame = try encoder.nextFrame()
                    let sid = encoder.surfaceID(of: frame)
                    try blitInto(sid) { try encoder.exportSurface(sid) }
                    packets = try encoder.encode(
                        frame, pts: Int64(frames), forceIDR: forceIdr)
                    encoder.release(frame)
                }
                for packet in packets {
                    // The libav wrapper pipelines by a frame: keyframe
                    // truth rides ON THE PACKET, and the armed causes
                    // attach to the IDR whenever it actually emerges.
                    // (The native seat is 1-in-1-out, same contract.)
                    let causes = packet.keyframe ? pendingCauses : []
                    if packet.keyframe { pendingCauses.removeAll() }
                    deliver(packet.data, keyframe: packet.keyframe,
                            causes: causes, captureUs: captureUs)
                }
                frames += 1
            } catch {
                if !ticketReleased { ticket.release() }
                lastError = "direct: frame \(frames): \(error)"
                return
            }
        }

        // Drain: only the pipelined libav seat holds a frame back.
        if case .libav(let encoder) = seat,
           let tail = try? encoder.encode(nil, pts: Int64(frames)) {
            for packet in tail {
                let causes = packet.keyframe ? pendingCauses : []
                if packet.keyframe { pendingCauses.removeAll() }
                deliver(packet.data, keyframe: packet.keyframe,
                        causes: causes,
                        captureUs: UInt64(nowSeconds() * 1_000_000))
            }
        }
        print("direct: eye closed — \(frames) frames, \(bytes) bytes, "
            + "\(keyframes) IDRs, missed_grabs=\(missedGrabs), "
            + "directives_applied=\(directivesApplied), "
            + "directives_deferred=\(directivesDeferred), "
            + "cursor_shapes=\(cursorShapesSeen)")
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
            break
        case .hidden:
            cursorShapesSeen += 1
            wire.noteCursorShape(.hidden)
        case .shape(let frame):
            cursorShapesSeen += 1
            var hx = 0, hy = 0
            if let pointer = wire.lastAbsolutePointerInjection() {
                hx = Int(pointer.x.rounded())
                    - frame.planeCrtcX - frame.cropX
                hy = Int(pointer.y.rounded())
                    - frame.planeCrtcY - frame.cropY
            }
            hx = min(max(hx, 0), frame.width - 1)
            hy = min(max(hy, 0), frame.height - 1)
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
