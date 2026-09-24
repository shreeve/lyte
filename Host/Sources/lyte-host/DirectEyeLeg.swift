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
        static let defaultDevice = "/dev/dri/card1"
        var device = Config.defaultDevice
        var renderNode = "/dev/dri/renderD128"
        var seconds: Double
        var qp: Int32 = 24
        var pollUs: UInt32 = 1000
        /// Wire rate → the encoder's VBR envelope (0 = CQP).
        var bitrateBitsPerSecond: Int64 = 0
        /// The opening VBV (bits): the one-FEC-group frame ceiling the
        /// encoder's HRD buffer must not exceed. Nil = no guard (file mode).
        var vbvBits: Int?
    }

    private let config: Config
    private let screen: DirectScreenSource
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
    /// Why the owed IDR is owed (the IDR books' cause tags), attached to
    /// the keyframe that finally leaves.
    private var pendingCauses: [String] = []
    /// Frames the session refused (prepare or send errors). Counted and
    /// printed, never leg-fatal: the session's own end (peer gone, the
    /// liveness timeout, a failed drain) stops the leg.
    private(set) var deliveryFailures = 0
    /// Changed frames skipped before encode because the queued video
    /// already held its latency budget.
    private(set) var admission = VideoAdmissionGate()
    private var lastDeliveryFailureWallSeconds = 0.0
    static let refusedIdrRetrySeconds = 1.0 / 60
    private var lastEncodedCaptureUs: UInt64 = 0
    private(set) var staticIdrsServed = 0
    /// E5 audit item 3: the quiet-desktop heartbeat cadence. One
    /// retained re-encode per second is enough to keep the clock
    /// model fed and the wire warm; the full-rate idle floor (and
    /// ratchet refinement) remain the portal's until post-E5 work.
    static let keepaliveSeconds = 1.0
    /// The screen beat and the encoder's frame rate.
    static let fps = 60
    /// The cursor plane's poll period: one 60 Hz beat.
    static let cursorPollMicroseconds: UInt64 = 16_667
    private var lastDeliveryWallSeconds = 0.0
    private(set) var keepalivesSent = 0
    /// The video quiet ladder (postures design): engaged only under
    /// the key-16 agreement; every step and wake is announced (0x26).
    private var quietPacer = VideoQuietPacer()
    private(set) var postureAnnouncements = 0
    /// V-4: true once the encoder runs Rext 4:4:4 — the stats block
    /// reports the encoder that RAN.
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

    init(config: Config, screen: DirectScreenSource, wire: SessionWire?,
         file: UnsafeMutablePointer<FILE>?) {
        self.config = config
        self.screen = screen
        self.wire = wire
        self.file = file
    }

    /// Opens the scanout the leg will watch. The composition root opens it
    /// before the session exists, so its geometry reaches the input
    /// injector before the first client event can.
    static func openScreen(device: String) throws -> DirectScreenSource {
        do {
            return try DirectScreenSource(device: device)
        } catch DirectScreenSourceError.openDevice(let path, let code) {
            throw HostError("direct: open(\(path)) errno \(code)")
        } catch DirectScreenSourceError.noActivePrimaryPlane {
            throw HostError("direct: no active primary plane")
        } catch DirectScreenSourceError.initialTicketDenied {
            throw HostError("direct: GETFB2 refused — the direct backend "
                + "needs CAP_SYS_ADMIN (run under sudo or the E4 unit)")
        } catch {
            throw HostError("direct: screen source failed: \(error)")
        }
    }

    /// Blocking loop: returns when the clock (or a session end, a
    /// termination signal, or a failure) says so.
    func run() {
        let fd = screen.fileDescriptor
        let width = screen.width
        let height = screen.height

        // The shell service cadence: the agreed-time pendings (the
        // 0x19 starting posture, the standing 0x24 cursor shape,
        // clipboard applies, bulk file I/O, pairing outcomes) flush ONLY
        // through service() — sendFrame's serviceOnce covers protocol
        // timers, not the shell. A dedicated janitor thread sweeps it
        // every 10 ms so the screen beat never stalls on shell IO.
        // SessionWire is cross-thread by design with `lock` as the
        // discipline; this thread is service()'s ONLY caller.
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
        }

        // Chroma is a session posture: the encoder opens once, in the
        // posture the client's declaration picks. The janitor above is
        // what receives that declaration, so it runs during the wait.
        let chroma = awaitOpeningChroma()

        // The encoder seat: the native VAAPI pens — zero libavcodec, rate
        // directives apply live (the RC misc buffer rides the next frame).
        let pipeline: EyePipeline
        do {
            pipeline = try EyePipeline(
                width: width, height: height,
                renderNode: config.renderNode, qp: config.qp,
                bitrateBitsPerSecond: config.bitrateBitsPerSecond,
                hrdBufferBits: config.bitrateBitsPerSecond > 0
                    ? Int64(EncoderHrd.bufferBits(
                        capBitsPerSecond: Int(config.bitrateBitsPerSecond),
                        fps: Self.fps, vbvBits: config.vbvBits))
                    : nil,
                chroma444: chroma == .yuv444)
        } catch {
            lastError = "direct: init failed: \(error)"
            return
        }
        chroma444Active = pipeline.chroma444
        let rc = config.bitrateBitsPerSecond > 0
            ? "vbr \(config.bitrateBitsPerSecond / 1_000_000) Mbps cap"
            : "cqp \(config.qp)"
        print("direct: eye open — \(width)x\(height) on "
            + "\(config.device), native VAAPI \(rc), "
            + (chroma == .yuv444 ? "Rext 4:4:4 (AYUV)" : "4:2:0")
            + " (rate directives apply live)")

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

        var samplingCadence = ScreenSamplingCadence()
        var observations: UInt64 = 0
        var framebufferTransitions: UInt64 = 0
        var changedObservations: UInt64 = 0
        var skippedObservationBeats: UInt64 = 0
        var observationSkipEvents: UInt64 = 0
        let t0 = SystemMonotonicClock.nowSeconds
        // The stillness clock: last pixel change or client input.
        var lastActivityWallSeconds = t0

        // Recovery and quiet-desktop traffic do not depend on a fresh pixel
        // observation. This is deliberately serviced from the 1 ms shell
        // loop while screen reads stay on their independent 60 Hz grid.
        func serveRetainedFrameIfNeeded(
            _ snapshot: SessionWire.LegSnapshot?
        ) throws -> Bool {
            // A refused IDR is retried no sooner than one beat later.
            if staticIdrWanted,
               SystemMonotonicClock.nowSeconds - lastDeliveryFailureWallSeconds
                   >= Self.refusedIdrRetrySeconds {
                staticIdrWanted = false
                let served: Void? = try pipeline.encodeRetained(forceIDR: true) {
                    bytes, keyframe in
                    deliverTakingCauses(
                        bytes, keyframe: keyframe,
                        captureUs: lastEncodedCaptureUs)
                }
                if served == nil {
                    staticIdrWanted = true // nothing retained yet
                } else {
                    staticIdrsServed += 1
                    lastDeliveryWallSeconds = SystemMonotonicClock.nowSeconds
                    print("direct: static-screen IDR served "
                        + "(re-encoded retained surface)")
                    return true
                }
            }

            var keepaliveInterval = Self.keepaliveSeconds
            if let wire, let snapshot {
                let inputSeconds = Double(snapshot.lastInputActivityNS) / 1e9
                let idle = SystemMonotonicClock.nowSeconds
                    - max(lastActivityWallSeconds, inputSeconds)
                if snapshot.videoQuietPostureAgreed {
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
            if wire != nil,
               SystemMonotonicClock.nowSeconds - lastDeliveryWallSeconds
                   >= keepaliveInterval {
                let served: Void? = try pipeline.encodeRetained(forceIDR: false) {
                    bytes, keyframe in
                    _ = deliver(bytes, keyframe: keyframe, causes: [],
                                captureUs: lastEncodedCaptureUs)
                }
                if served != nil {
                    keepalivesSent += 1
                    lastDeliveryWallSeconds = SystemMonotonicClock.nowSeconds
                    return true
                }
            }
            return false
        }

        /// Between observations: a retained frame may be owed, otherwise
        /// sleep one poll. False ends the leg (the error is recorded).
        func idle(_ snapshot: SessionWire.LegSnapshot?) -> Bool {
            do {
                if try serveRetainedFrameIfNeeded(snapshot) { return true }
            } catch {
                lastError = "direct: retained frame: \(error)"
                return false
            }
            usleep(config.pollUs)
            return true
        }

        var lastCursorPollUs: UInt64 = 0
        while SystemMonotonicClock.nowSeconds - t0 < config.seconds {
            // One session-lock round trip per poll: end, agreement,
            // directive, and IDR demand together.
            let snapshot = wire?.takeLegSnapshot()
            if snapshot?.ended == true { break }
            // HS-18: an interrupted run (SIGINT/SIGTERM) exits through
            // the same door as a completed one, so the audio-routing
            // restore and the typed teardown both happen.
            if lyteTerminationRequested != 0 {
                print("session: termination signal — closing cleanly")
                break
            }
            // The cursor plane is read on the screen's own 60 Hz grid, not
            // every 1 ms poll.
            let cursorStart = SystemMonotonicClock.nowMicroseconds
            if cursorStart &- lastCursorPollUs >= Self.cursorPollMicroseconds {
                lastCursorPollUs = cursorStart
                pollCursor(cursorWatcher)
                lastStages.cursorUs =
                    SystemMonotonicClock.nowMicroseconds - cursorStart
            }

            // A Best agreement that lands after the opening wait lapsed
            // reopens the encoder in Rext 4:4:4 (at most once per
            // session). The fresh encoder's first frame is the IDR the
            // client needs; resetting the sampling and identity state
            // makes the current screen fresh even on a static desktop.
            if !pipeline.chroma444,
               ChromaPosture.from(
                   agreedChromaModes: snapshot?.agreedChromaModes
               ) == .yuv444 {
                do {
                    try pipeline.reopen(chroma444: true)
                    chroma444Active = true
                    samplingCadence.reset()
                    screen.resetIdentityObservation()
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
            if let directive = snapshot?.directive {
                pipeline.setRateControl(
                    bitsPerSecond: Int64(directive.maxBitsPerSecond),
                    hrdBufferBits: Int64(EncoderHrd.bufferBits(
                        capBitsPerSecond: directive.maxBitsPerSecond,
                        fps: Self.fps, vbvBits: directive.vbvBits)))
                directivesApplied += 1
                if directivesApplied == 1 {
                    print("direct: rate directive "
                        + "(\(directive.kind.rawValue)) applied — "
                        + "\(directive.maxBitsPerSecond / 1_000_000)"
                        + " Mbps cap")
                }
            }

            // Demands are taken EVERY poll, not only when pixels change —
            // a client recovering on a static desktop must not wait for
            // the next damage to get its IDR. With no new pixels, the
            // retained surface still holds the screen: re-encode it as
            // the IDR, stamped with its ORIGINAL capture time (recovery
            // re-encodes are quality/dependency events, not network-late
            // frames).
            let demand = snapshot?.demand ?? []
            if !demand.isEmpty {
                pendingCauses += demand.names
                staticIdrWanted = true
            }

            let observationClock = SystemMonotonicClock.nowMicroseconds
            guard case .sample(let skippedBeats) = samplingCadence.poll(
                nowMicroseconds: observationClock)
            else {
                if idle(snapshot) { continue } else { return }
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
                if idle(snapshot) { continue } else { return }
            }
            if observation.identityChanged { framebufferTransitions += 1 }

            let grabStart = SystemMonotonicClock.nowMicroseconds
            do {
                switch try pipeline.refreshScanout(observation, from: screen) {
                case .current, .imported:
                    break
                case .missedGrab:
                    missedGrabs += 1
                    continue
                case .geometryChanged(let newWidth, let newHeight):
                    print("direct: display mode changed \(width)x\(height)"
                        + " → \(newWidth)x\(newHeight) — ending "
                        + "session; the re-dial reads fresh geometry")
                    modeChangeEnded = true
                    return
                }
            } catch {
                lastError = "direct: scanout import: \(error)"
                return
            }
            lastStages.grabUs = SystemMonotonicClock.nowMicroseconds - grabStart

            let pixelsChanged: Bool
            let fingerprintStart = SystemMonotonicClock.nowMicroseconds
            do {
                pixelsChanged = try pipeline.scanoutChanged()
            } catch {
                lastError = "direct: scanout fingerprint: \(error)"
                return
            }
            lastStages.fingerprintUs =
                SystemMonotonicClock.nowMicroseconds - fingerprintStart
            maxStages.formMax(lastStages)
            guard pixelsChanged else {
                if idle(snapshot) { continue } else { return }
            }
            changedObservations += 1
            lastActivityWallSeconds = SystemMonotonicClock.nowSeconds
            // Pre-encode admission: a queue already holding its latency
            // budget gets no new frame. The fingerprint resets so the
            // newest pixels are re-observed — and encoded — next beat.
            if let wire {
                let posture = wire.videoAdmissionPosture
                guard admission.admit(
                    backlogWireTimeNS: posture.backlogWireTimeNS,
                    budgetNS: posture.budgetNS)
                else {
                    pipeline.resetFingerprint()
                    if idle(snapshot) { continue } else { return }
                }
            }
            // Pixel equality, not framebuffer identity, is damage truth.
            let captureUs = observationClock

            let forceIdr = frames == 0 || staticIdrWanted
            staticIdrWanted = false
            if frames == 0 { pendingCauses.append("opening") }

            do {
                // 1-in-1-out: keyframe truth rides ON THE PACKET, and the
                // armed causes attach to the IDR when it emerges.
                var deliverStart: UInt64 = 0
                try pipeline.encodeFresh(forceIDR: forceIdr) {
                    bytes, keyframe in
                    deliverStart = SystemMonotonicClock.nowMicroseconds
                    lastEncodedCaptureUs = captureUs
                    deliverTakingCauses(
                        bytes, keyframe: keyframe, captureUs: captureUs)
                }
                lastStages.blitUs = pipeline.lastBlitMicroseconds
                lastStages.encodeUs = pipeline.lastEncodeMicroseconds
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
            + "delivery_failures=\(deliveryFailures), "
            + "admission_skips=\(admission.skipped), "
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
    /// re-derives it at rest. Plane CRTC requires ATOMIC client cap —
    /// see `CursorHotspot` / `ScreenSource`.
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
            let pointer = wire.lastAbsolutePointerInjection().map {
                CursorHotspot.Point(
                    x: Int($0.x.rounded()), y: Int($0.y.rounded()))
            }
            let plane = frame.planeCrtc.map {
                CursorHotspot.Point(x: $0.x, y: $0.y)
            }
            let hot = CursorHotspot.derive(
                pointer: pointer,
                planeCrtc: plane,
                crop: .init(x: frame.cropX, y: frame.cropY),
                width: frame.width, height: frame.height)
            // The first few shapes print their full inputs so a wrong
            // hotspot reads straight back to which term lied.
            if cursorShapesSeen <= 6 {
                let planeDesc = plane.map { "\($0.x),\($0.y)" }
                    ?? "nil"
                let pointerDesc = pointer.map { "\($0.x),\($0.y)" }
                    ?? "none"
                print("direct: cursor derive #\(cursorShapesSeen): "
                    + "\(frame.width)x\(frame.height) "
                    + "crop(\(frame.cropX),\(frame.cropY)) "
                    + "plane(\(planeDesc)) "
                    + "pointer(\(pointerDesc)) "
                    + "→ hotspot(\(hot.x),\(hot.y))")
            }
            lastCursorFrame = frame
            sentHotspot = (hot.x, hot.y)
            hotspotRecheckArmed = CursorHotspot.canRecheck(
                planeCrtc: plane)
            wire.noteCursorShape(CursorShape(
                width: UInt16(frame.width),
                height: UInt16(frame.height),
                hotspotX: UInt16(hot.x), hotspotY: UInt16(hot.y),
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
              CursorHotspot.canRecheck(
                  planeCrtc: .init(x: plane.x, y: plane.y))
        else {
            // Props still absent — do not invent a correction.
            hotspotRecheckArmed = false
            return
        }
        let hot = CursorHotspot.derive(
            pointer: .init(
                x: Int(pointer.x.rounded()),
                y: Int(pointer.y.rounded())),
            planeCrtc: .init(x: plane.x, y: plane.y),
            crop: .init(x: frame.cropX, y: frame.cropY),
            width: frame.width, height: frame.height)
        hotspotRecheckArmed = false
        guard hot.x != sent.x || hot.y != sent.y else { return }
        cursorHotspotCorrections += 1
        print("direct: cursor hotspot corrected "
            + "(\(sent.x),\(sent.y)) → (\(hot.x),\(hot.y)) at rest — "
            + "plane(\(plane.x),\(plane.y)) "
            + "pointer(\(Int(pointer.x)),\(Int(pointer.y)))")
        sentHotspot = (hot.x, hot.y)
        wire.noteCursorShape(CursorShape(
            width: UInt16(frame.width),
            height: UInt16(frame.height),
            hotspotX: UInt16(hot.x), hotspotY: UInt16(hot.y),
            pixels: frame.pixels))
    }

    /// The chroma posture to open the encoder in: the agreed one, or 4:2:0
    /// when no declaration lands within the opening wait (a pre-W7 peer)
    /// or there is no session (file mode).
    private func awaitOpeningChroma() -> ChromaPosture {
        guard let wire else { return .yuv420 }
        let start = SystemMonotonicClock.nowNanoseconds
        while true {
            if let posture = ChromaPosture.opening(
                agreedChromaModes: wire.agreedChromaModes,
                waitedNS: SystemMonotonicClock.nowNanoseconds - start) {
                return posture
            }
            if lyteTerminationRequested != 0 { return .yuv420 }
            usleep(config.pollUs)
        }
    }

    /// Delivers one access unit with the owed IDR causes attached when it
    /// is a keyframe. A keyframe the session refused leaves the IDR owed —
    /// causes included — so the next poll serves it again.
    private func deliverTakingCauses(
        _ packet: UnsafeRawBufferPointer, keyframe: Bool, captureUs: UInt64
    ) {
        let causes = keyframe ? pendingCauses : []
        if keyframe { pendingCauses.removeAll() }
        if !deliver(packet, keyframe: keyframe, causes: causes,
                    captureUs: captureUs), keyframe {
            pendingCauses = causes + pendingCauses
            staticIdrWanted = true
        }
    }

    /// One encoded access unit, borrowed from the encoder's coded buffer
    /// for the duration of the call. False when the session refused it.
    private func deliver(_ packet: UnsafeRawBufferPointer, keyframe: Bool,
                         causes: [String], captureUs: UInt64) -> Bool {
        guard let base = packet.baseAddress?.assumingMemoryBound(
            to: UInt8.self) else { return false }
        if firstPacket.isEmpty {
            firstPacket = Array(packet)
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
                deliveryFailures += 1
                lastDeliveryFailureWallSeconds = SystemMonotonicClock.nowSeconds
                if deliveryFailures <= 3 {
                    print("direct: session refused frame "
                        + "(\(keyframe ? "IDR" : "P")): \(error)")
                }
                return false
            }
        } else if let file {
            fwrite(base, 1, packet.count, file)
        }
        bytes += packet.count
        if keyframe { keyframes += 1 }
        return true
    }
}

#endif
