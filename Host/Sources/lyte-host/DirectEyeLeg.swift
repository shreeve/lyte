// DirectEyeLeg (direct-eye plan E1): the fused capture+encode backend
// — a phase-stable screen beat paces it, HostEye observes pixels on the GPU,
// grabs/blits/encodes changed scanout on the Arc
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

import LyteIO
import Foundation
import Glibc
import HostCore
import HostEye
import HostWire
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
    /// The video quiet ladder (postures design): engaged only under
    /// the key-16 agreement; every step and wake is announced (0x26).
    private var quietPacer = VideoQuietPacer()
    private(set) var postureAnnouncements = 0
    /// V-4: true once a Best-tier agreement reopened the encoder in
    /// Rext 4:4:4 — the stats block reports the encoder that RAN.
    private(set) var chroma444Active = false
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
    /// The screen observer's stage clocks explain where a late observation
    /// spent its time. Content cadence is deliberately absent: a 30 fps video
    /// on a 60 Hz observation grid is normal, not a skipped capture beat.
    private struct StageClocks {
        var cursorUs: UInt64 = 0
        var grabUs: UInt64 = 0
        var fingerprintUs: UInt64 = 0
        var blitUs: UInt64 = 0
        var encodeUs: UInt64 = 0
        var deliverUs: UInt64 = 0
        mutating func formMax(_ other: StageClocks) {
            cursorUs = max(cursorUs, other.cursorUs)
            grabUs = max(grabUs, other.grabUs)
            fingerprintUs = max(fingerprintUs, other.fingerprintUs)
            blitUs = max(blitUs, other.blitUs)
            encodeUs = max(encodeUs, other.encodeUs)
            deliverUs = max(deliverUs, other.deliverUs)
        }
        func described() -> String {
            "cursor=\(Self.ms(cursorUs)) "
            + "grab=\(Self.ms(grabUs)) "
            + "fingerprint=\(Self.ms(fingerprintUs)) "
            + "blit=\(Self.ms(blitUs)) "
            + "encode=\(Self.ms(encodeUs)) deliver=\(Self.ms(deliverUs))"
        }
        static func ms(_ us: UInt64) -> String {
            String(format: "%.1f", Double(us) / 1000)
        }
    }
    private var lastStages = StageClocks()
    private var maxStages = StageClocks()
    /// The janitor (the #84 finding made law): the shell service —
    /// clipboard D-Bus applies, audio-routing moves, bulk file I/O —
    /// used to ride the capture thread and stalled it 106 ms at
    /// connect; a mid-session file drop would stall it for the whole
    /// write. Now a dedicated thread sweeps every 10 ms and the eye
    /// only watches. `serviceLock` guards the shared clocks/flag.
    private let serviceLock = NSLock()
    private var serviceStopRequested = false
    private var serviceMaxMicroseconds: UInt64 = 0
    private let serviceDone = DispatchSemaphore(value: 0)
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
        let screen: DirectScreenSource
        do {
            screen = try DirectScreenSource(device: config.device)
        } catch DirectScreenSourceError.openDevice(let path, let code) {
            lastError = "direct: open(\(path)) errno \(code)"
            return
        } catch DirectScreenSourceError.noActivePrimaryPlane(_) {
            lastError = "direct: no active primary plane"
            return
        } catch DirectScreenSourceError.initialTicketDenied(_) {
            lastError = "direct: GETFB2 refused — the direct backend "
                + "needs CAP_SYS_ADMIN (run under sudo or the E4 unit)"
            return
        } catch {
            lastError = "direct: screen source failed: \(error)"
            return
        }
        let fd = screen.fileDescriptor
        let width = screen.width
        let height = screen.height
        // HS-13: the uinput fallback maps absolute pointer coordinates
        // against the monitor extent — tell the wire what we captured
        // (the portal Sink used to do this at encoder open).
        wire?.noteMonitorExtent(
            width: UInt32(width), height: UInt32(height))

        // The encoder seat (E6b, sole occupant since the demolition):
        // the native VAAPI pens — zero libavcodec, rate directives
        // apply live (the RC misc buffer rides the next frame).
        let gl: EyeGL
        var encoder: EyeVaapiEncoder
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
        // The watcher shares the DRM fd and loop cadence; a session-
        // less (file-mode) leg has no one to tell, so it skips.
        let cursorWatcher = wire != nil ? EyeCursorWatcher(fd: fd) : nil
        if wire != nil {
            print(cursorWatcher != nil
                ? "direct: cursor watcher on plane "
                    + "\(cursorWatcher!.planeId) — shapes ride 0x24"
                : "direct: no cursor plane — shapes OFF this run")
        }

        var targets: [UInt32: NV12Target] = [:]
        var targets444: [UInt32: AyuvTarget] = [:]
        var scanoutSource: ImportedTexture?
        var scanoutIdentity: UInt32?
        var samplingCadence = ScreenSamplingCadence()
        var observations: UInt64 = 0
        var framebufferTransitions: UInt64 = 0
        var changedObservations: UInt64 = 0
        var skippedObservationBeats: UInt64 = 0
        var observationSkipEvents: UInt64 = 0
        var pendingCauses: [String] = []
        let t0 = SystemMonotonicClock.nowSeconds
        // The stillness clock: last pixel change or client input.
        var lastActivityWallSeconds = t0

        // The shell service cadence: the agreed-time pendings (the
        // 0x19 starting posture, the standing 0x24 cursor shape,
        // clipboard applies, bulk file I/O) flush ONLY through
        // service() — sendFrame's serviceOnce covers protocol timers,
        // not the shell. It used to ride this loop and the beat book
        // convicted it (106 ms connect stall = a skipped capture
        // beat); now the janitor sweeps on its own thread and the
        // screen beat never goes blind for a mop bucket. SessionWire is
        // cross-thread by design with `lock` as the discipline; this
        // thread is service()'s ONLY caller.
        if let wire {
            nonisolated(unsafe) let leg = self
            nonisolated(unsafe) let wire = wire
            let janitor = Thread {
                while true {
                    leg.serviceLock.lock()
                    let stop = leg.serviceStopRequested
                    leg.serviceLock.unlock()
                    if stop { break }
                    let start = SystemMonotonicClock.nowMicroseconds
                    wire.service()
                    let took = SystemMonotonicClock.nowMicroseconds - start
                    leg.serviceLock.lock()
                    if took > leg.serviceMaxMicroseconds {
                        leg.serviceMaxMicroseconds = took
                    }
                    leg.serviceLock.unlock()
                    usleep(10_000)
                }
                leg.serviceDone.signal()
            }
            janitor.name = "lyte-shell-service"
            janitor.start()
        }
        defer {
            if wire != nil {
                serviceLock.lock()
                serviceStopRequested = true
                serviceLock.unlock()
                serviceDone.wait()
            }
            if var source = scanoutSource {
                gl.destroy(&source)
            }
        }

        // Recovery and quiet-desktop traffic do not depend on a fresh pixel
        // observation. This is deliberately serviced from the 1 ms shell
        // loop while screen reads stay on their independent 60 Hz grid.
        func serveRetainedFrameIfNeeded() throws -> Bool {
            if staticIdrWanted, let sid = lastEncodedSurface {
                let packet = try encoder.encode(surface: sid, forceIDR: true)
                let causes = packet.keyframe ? pendingCauses : []
                if packet.keyframe { pendingCauses.removeAll() }
                deliver(Data(packet.data),
                        keyframe: packet.keyframe,
                        causes: causes,
                        captureUs: lastEncodedCaptureUs)
                staticIdrWanted = false
                staticIdrsServed += 1
                lastDeliveryWallSeconds = SystemMonotonicClock.nowSeconds
                print("direct: static-screen IDR served "
                    + "(re-encoded retained surface \(sid))")
                return true
            }

            var keepaliveInterval = Self.keepaliveSeconds
            if let wire {
                let inputSeconds = Double(wire.lastInputActivityNS) / 1e9
                let idle = SystemMonotonicClock.nowSeconds
                    - max(lastActivityWallSeconds, inputSeconds)
                if wire.videoQuietPostureAgreed() {
                    let verdict = quietPacer.assess(idleSeconds: idle)
                    keepaliveInterval = verdict.keepaliveSeconds
                    if let announce = verdict.announce {
                        wire.sendVideoPostureState(
                            quiet: announce.quiet,
                            keepaliveSeconds: announce.keepaliveSeconds)
                        postureAnnouncements += 1
                    }
                }
            }
            if wire != nil, let sid = lastEncodedSurface,
               SystemMonotonicClock.nowSeconds - lastDeliveryWallSeconds
                   >= keepaliveInterval {
                let packet = try encoder.encode(
                    surface: sid, forceIDR: false)
                deliver(Data(packet.data),
                        keyframe: packet.keyframe,
                        causes: [],
                        captureUs: lastEncodedCaptureUs)
                keepalivesSent += 1
                lastDeliveryWallSeconds = SystemMonotonicClock.nowSeconds
                return true
            }
            return false
        }

        while SystemMonotonicClock.nowSeconds - t0 < config.seconds {
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
            let cursorStart = SystemMonotonicClock.nowMicroseconds
            pollCursor(cursorWatcher)
            lastStages.cursorUs = SystemMonotonicClock.nowMicroseconds - cursorStart

            // V-4: the agreed chroma is connect-time truth that
            // lands AFTER the leg opened its encoder (the declaration
            // rides the handshake). One session per leg lifetime → at
            // most one flip: a Best-tier agreement reopens the encoder
            // in Rext 4:4:4. The fresh encoder's first frame is the
            // IDR the joiner needs. Resetting the sampling/fingerprint
            // state makes the current screen fresh immediately, even
            // when the desktop is static.
            if !chroma444Active,
               ChromaPosture.from(
                   agreedChromaModes: wire?.agreedChromaModes
               ) == .yuv444 {
                do {
                    for sid in targets.keys {
                        gl.destroy(&targets[sid]!)
                    }
                    targets.removeAll()
                    for sid in targets444.keys {
                        gl.destroy(&targets444[sid]!)
                    }
                    targets444.removeAll()
                    if var source = scanoutSource {
                        gl.destroy(&source)
                        scanoutSource = nil
                    }
                    scanoutIdentity = nil
                    gl.resetFingerprint()
                    samplingCadence.reset()
                    lastEncodedSurface = nil
                    screen.resetIdentityObservation()
                    encoder = try EyeVaapiEncoder(
                        width: width, height: height, fps: 60,
                        qp: config.qp,
                        renderNode: config.renderNode,
                        bitrateBitsPerSecond:
                            config.bitrateBitsPerSecond,
                        chroma444: true)
                    chroma444Active = true
                    print("direct: Best tier agreed — encoder "
                        + "reopened as Rext 4:4:4 (AYUV, one-pass "
                        + "blit)")
                } catch {
                    lastError = "direct: 4:4:4 reopen: \(error)"
                    return
                }
            }

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

            let observationClock = SystemMonotonicClock.nowMicroseconds
            guard case .sample(let skippedBeats) = samplingCadence.poll(
                nowMicroseconds: observationClock)
            else {
                do {
                    if try serveRetainedFrameIfNeeded() { continue }
                } catch {
                    lastError = "direct: retained frame: \(error)"
                    return
                }
                usleep(config.pollUs)
                continue
            }
            observations += 1
            skippedObservationBeats += skippedBeats
            if skippedBeats > 0 {
                observationSkipEvents += 1
                if observationSkipEvents <= 40 {
                    print("direct: observation beat skipped "
                        + "\(skippedBeats) beat(s) "
                        + "prev[\(lastStages.described())] ms")
                }
            }
            guard let observation = screen.observe() else {
                do {
                    if try serveRetainedFrameIfNeeded() { continue }
                } catch {
                    lastError = "direct: retained frame: \(error)"
                    return
                }
                usleep(config.pollUs)
                continue
            }
            if observation.identityChanged { framebufferTransitions += 1 }

            let grabStart = SystemMonotonicClock.nowMicroseconds
            if scanoutSource == nil
                || scanoutIdentity != observation.framebufferIdentity {
                guard let ticket = screen.capture(observation) else {
                    missedGrabs += 1
                    continue
                }
                if Int32(ticket.width) != width
                    || Int32(ticket.height) != height {
                    ticket.release()
                    print("direct: display mode changed \(width)x\(height)"
                        + " → \(ticket.width)x\(ticket.height) — ending "
                        + "session; the re-dial reads fresh geometry")
                    modeChangeEnded = true
                    return
                }
                do {
                    let imported = try gl.importTexture(
                        width: Int32(ticket.width),
                        height: Int32(ticket.height),
                        fourcc: ticket.fourcc,
                        modifier: ticket.modifier,
                        planes: ticket.planes)
                    ticket.release()
                    if var old = scanoutSource { gl.destroy(&old) }
                    scanoutSource = imported
                    scanoutIdentity = observation.framebufferIdentity
                    gl.resetFingerprint()
                } catch {
                    ticket.release()
                    lastError = "direct: scanout import: \(error)"
                    return
                }
            }
            lastStages.grabUs = SystemMonotonicClock.nowMicroseconds - grabStart

            guard let source = scanoutSource else {
                lastError = "direct: scanout import disappeared"
                return
            }
            let pixelsChanged: Bool
            let fingerprintStart = SystemMonotonicClock.nowMicroseconds
            do {
                pixelsChanged = try gl.scanoutChanged(
                    source: source, width: width, height: height)
            } catch {
                lastError = "direct: scanout fingerprint: \(error)"
                return
            }
            lastStages.fingerprintUs =
                SystemMonotonicClock.nowMicroseconds - fingerprintStart
            maxStages.formMax(lastStages)
            guard pixelsChanged else {
                do {
                    if try serveRetainedFrameIfNeeded() { continue }
                } catch {
                    lastError = "direct: retained frame: \(error)"
                    return
                }
                usleep(config.pollUs)
                continue
            }
            changedObservations += 1
            lastActivityWallSeconds = SystemMonotonicClock.nowSeconds
            // Pixel equality, not framebuffer identity, is damage truth.
            let captureUs = observationClock

            let forceIdr = frames == 0 || staticIdrWanted
            staticIdrWanted = false
            if frames == 0 { pendingCauses.append("opening") }

            do {
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
                        srcWidth: width,
                        srcHeight: height,
                        into: targets[sid]!)
                }

                func blit444Into(_ sid: UInt32) throws {
                    if targets444[sid] == nil {
                        let plane = try encoder.exportSurfacePacked(sid)
                        let target = try gl.makeAyuvTarget(
                            width: width, height: height,
                            modifier: plane.modifier,
                            plane: (plane.fd, plane.offset,
                                    plane.pitch))
                        close(plane.fd)
                        targets444[sid] = target
                    }
                    gl.blit444(
                        source: source,
                        srcWidth: width,
                        srcHeight: height,
                        into: targets444[sid]!)
                }

                // Synchronous seat: vaSyncSurface inside encode
                // means the round-robin input is free by return —
                // no in-flight aliasing. 1-in-1-out: keyframe truth
                // rides ON THE PACKET, and the armed causes attach
                // to the IDR when it emerges.
                let sid = encoder.inputSurfaces[
                    frames % encoder.inputSurfaces.count]
                let blitStart = SystemMonotonicClock.nowMicroseconds
                if chroma444Active {
                    try blit444Into(sid)
                } else {
                    try blitInto(sid) { try encoder.exportSurface(sid) }
                }
                let encodeStart = SystemMonotonicClock.nowMicroseconds
                lastStages.blitUs = encodeStart - blitStart
                let packet = try encoder.encode(
                    surface: sid, forceIDR: forceIdr)
                let deliverStart = SystemMonotonicClock.nowMicroseconds
                lastStages.encodeUs = deliverStart - encodeStart
                lastEncodedSurface = sid
                lastEncodedCaptureUs = captureUs
                let causes = packet.keyframe ? pendingCauses : []
                if packet.keyframe { pendingCauses.removeAll() }
                deliver(Data(packet.data), keyframe: packet.keyframe,
                        causes: causes, captureUs: captureUs)
                lastStages.deliverUs = SystemMonotonicClock.nowMicroseconds - deliverStart
                maxStages.formMax(lastStages)
                frames += 1
                lastDeliveryWallSeconds = SystemMonotonicClock.nowSeconds
            } catch {
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
            + "observations=\(observations), "
            + "framebuffer_transitions=\(framebufferTransitions), "
            + "pixel_changes=\(changedObservations), "
            + "observation_beats_skipped=\(skippedObservationBeats), "
            + "posture_announcements=\(postureAnnouncements), "
            + "cursor_shapes=\(cursorShapesSeen), "
            + "hotspot_corrections=\(cursorHotspotCorrections)")
        serviceLock.lock()
        let serviceMaxUs = serviceMaxMicroseconds
        serviceLock.unlock()
        print("direct: observation-book — beats=\(observations), "
            + "skip_events=\(observationSkipEvents), "
            + "beats_skipped=\(skippedObservationBeats), "
            + "pixel_changes=\(changedObservations), "
            + "stage_max[\(maxStages.described())] ms, "
            + "service_max=\(StageClocks.ms(serviceMaxUs)) ms "
            + "(janitor thread)")
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
        let nowMicros = UInt64(SystemMonotonicClock.nowSeconds * 1_000_000)
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
