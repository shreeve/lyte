// DirectEyeLeg: the host's capture leg. A phase-stable 60 Hz screen beat
// drives HostEye's EyePipeline (scanout import, GPU pixel fingerprint,
// blit, native VAAPI encode); access units go straight to the session's
// sendFrame (or the probe file). Per poll it honors one session snapshot:
// forced-IDR demands (served on a still screen by re-encoding the retained
// frame), rate directives (no reset), the agreed chroma posture, the quiet
// video posture, and pre-encode admission against the latency budget.

#if os(Linux)

import LyteIO
import Foundation
import Glibc
import HostCore
import HostEye
import HostWire
import LyteWire

/// The eye that outlives sessions: the GL context and the pipeline open
/// once, and every later session begins a fresh encoder stream on them
/// (`EyePipeline.beginSession`), so a re-dial costs an encoder reopen,
/// not an EGL bring-up.
final class WarmEye {
    private let width: Int32
    private let height: Int32
    private var pipeline: EyePipeline?

    init(screen: DirectScreenSource) {
        self.width = screen.width
        self.height = screen.height
    }

    /// The pipeline for the next session, in its chroma posture, first
    /// frame an IDR. The first call opens it with `config`'s encoder
    /// posture, which every session of a run shares.
    func pipeline(
        config: DirectEyeLeg.Config, chroma444: Bool
    ) throws -> EyePipeline {
        if let pipeline {
            try pipeline.beginSession(chroma444: chroma444)
            return pipeline
        }
        let opened = try EyePipeline(
            width: width, height: height,
            renderNode: config.renderNode, qp: config.qp,
            bitrateBitsPerSecond: config.bitrateBitsPerSecond,
            hrdBufferBits: config.bitrateBitsPerSecond > 0
                ? Int64(EncoderHrd.bufferBits(
                    capBitsPerSecond: Int(config.bitrateBitsPerSecond),
                    fps: DirectEyeLeg.fps, vbvBits: config.vbvBits))
                : nil,
            chroma444: chroma444)
        pipeline = opened
        return opened
    }
}

final class DirectEyeLeg {
    struct Config {
        static let defaultDevice = "/dev/dri/card1"
        var device = Config.defaultDevice
        var renderNode = "/dev/dri/renderD128"
        /// The leg's wall-clock bound; `.infinity` for a service session.
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
    private let eye: WarmEye
    private let wire: SessionWire?
    private let file: UnsafeMutablePointer<FILE>?
    private(set) var frames = 0
    private(set) var firstPacket: [UInt8] = []
    private(set) var bytes = 0
    private(set) var keyframes = 0
    private(set) var missedGrabs = 0
    private(set) var directivesApplied = 0
    /// An IDR is owed; on a static screen it is served by re-encoding
    /// the retained surface.
    private var staticIdrWanted = false
    /// The owed IDR's cause tags, attached to the keyframe that leaves.
    private var pendingCauses: [String] = []
    /// Frames the session refused. Never leg-fatal: the session's own
    /// end stops the leg.
    private(set) var deliveryFailures = 0
    private(set) var admission = VideoAdmissionGate()
    private var lastDeliveryFailureWallSeconds = 0.0
    static let refusedIdrRetrySeconds = 1.0 / 60
    private var lastEncodedCaptureUs: UInt64 = 0
    private(set) var staticIdrsServed = 0
    /// Quiet-desktop heartbeat: one retained re-encode per second keeps
    /// the clock model fed and the wire warm.
    static let keepaliveSeconds = 1.0
    /// The screen beat and the encoder's frame rate.
    static let fps = 60
    /// The cursor plane's poll period: one 60 Hz beat.
    static let cursorPollMicroseconds: UInt64 = 16_667
    /// How often a running session's janitor bounds host.log.
    static let logCheckIntervalMicros: UInt64 = 60_000_000
    private var lastDeliveryWallSeconds = 0.0
    private(set) var keepalivesSent = 0
    /// The video quiet ladder: engaged only under the key-16 agreement;
    /// every step and wake is announced (0x26).
    private var quietPacer = VideoQuietPacer()
    private(set) var postureAnnouncements = 0
    /// True once the encoder runs Rext 4:4:4 (what actually ran).
    private(set) var chroma444Active = false
    /// The display's geometry changed under the leg: a clean exit, not
    /// an error.
    private(set) var modeChangeEnded = false
    private(set) var sessionEnded = false
    /// SIGINT or SIGTERM stopped the leg.
    private(set) var terminationRequested = false

    /// How the leg ended, for the service loop.
    var end: HostServiceLoop.SessionEnd {
        if let lastError { return .failed(lastError) }
        if modeChangeEnded { return .displayModeChanged }
        if terminationRequested { return .terminationRequested }
        if sessionEnded { return .sessionEnded }
        return .clockExpired
    }
    private(set) var cursorShapesSeen = 0
    private(set) var cursorReadFailures = 0
    private(set) var cursorHotspotCorrections = 0
    /// Hotspot self-heal: mid-motion the plane can lag the newest
    /// injected pointer by a frame, so the derived hotspot can be off.
    /// At rest the plane sits exactly at pointer − hotspot, so one armed
    /// recheck per shape re-derives it.
    private var lastCursorFrame: CursorFrame?
    private var sentHotspot: (x: Int, y: Int)?
    private var hotspotRecheckArmed = false
    /// Where a late observation spent its time. Content cadence is absent:
    /// 30 fps video on a 60 Hz grid is normal, not a skipped beat.
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
            """
                cursor=\(Self.ms(cursorUs)) grab=\(Self.ms(grabUs)) \
                fingerprint=\(Self.ms(fingerprintUs)) blit=\(Self.ms(blitUs)) \
                encode=\(Self.ms(encodeUs)) deliver=\(Self.ms(deliverUs))
                """
        }
        static func ms(_ us: UInt64) -> String {
            String(format: "%.1f", Double(us) / 1000)
        }
    }
    private var lastStages = StageClocks()
    private var maxStages = StageClocks()
    /// The janitor thread runs the shell service (clipboard D-Bus,
    /// audio routing, bulk file I/O) so it never stalls the capture
    /// thread. `serviceLock` guards the shared clocks/flag.
    private let serviceLock = NSLock()
    private var serviceStopRequested = false
    private var serviceMaxMicroseconds: UInt64 = 0
    private let serviceDone = DispatchSemaphore(value: 0)
    var lastError: String?

    init(config: Config, screen: DirectScreenSource, eye: WarmEye,
         wire: SessionWire?, file: UnsafeMutablePointer<FILE>?) {
        self.config = config
        self.screen = screen
        self.eye = eye
        self.wire = wire
        self.file = file
    }

    /// Opens the scanout before the session exists, so its geometry
    /// reaches the input injector before the first client event can.
    static func openScreen(device: String) throws -> DirectScreenSource {
        do {
            return try DirectScreenSource(device: device)
        } catch DirectScreenSourceError.openDevice(let path, let code) {
            throw HostError("direct: open(\(path)) errno \(code)")
        } catch DirectScreenSourceError.noActivePrimaryPlane {
            throw HostError("direct: no active primary plane")
        } catch DirectScreenSourceError.initialTicketDenied {
            throw HostError("""
                direct: GETFB2 refused — the direct backend \
                needs CAP_SYS_ADMIN (run under sudo or the systemd unit)
                """)
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

        // Shell pendings (0x19 posture, the 0x24 cursor shape,
        // clipboard, bulk file I/O, pairing outcomes) flush ONLY through
        // service(); sendFrame covers protocol timers, not the shell.
        // This janitor thread is service()'s only caller, every 10 ms.
        if let wire {
            nonisolated(unsafe) let leg = self
            nonisolated(unsafe) let wire = wire
            let janitor = Thread {
                var nextLogCheckMicros = SystemMonotonicClock.nowMicroseconds
                    + Self.logCheckIntervalMicros
                while true {
                    leg.serviceLock.lock()
                    let stop = leg.serviceStopRequested
                    leg.serviceLock.unlock()
                    if stop { break }
                    let start = SystemMonotonicClock.nowMicroseconds
                    if start >= nextLogCheckMicros {
                        HostLogBound.check()
                        nextLogCheckMicros = start + Self.logCheckIntervalMicros
                    }
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

        // The encoder opens once, in the chroma the client declares; the
        // janitor above receives that declaration during the wait.
        let chroma = awaitOpeningChroma()

        let pipeline: EyePipeline
        do {
            pipeline = try eye.pipeline(
                config: config, chroma444: chroma == .yuv444)
        } catch {
            lastError = "direct: init failed: \(error)"
            return
        }
        chroma444Active = pipeline.chroma444
        let rc = config.bitrateBitsPerSecond > 0
            ? "vbr \(config.bitrateBitsPerSecond / 1_000_000) Mbps cap"
            : "cqp \(config.qp)"
        print("""
            direct: eye open — \(width)x\(height) on \(config.device), native \
            VAAPI \(rc), \(chroma == .yuv444 ? "Rext 4:4:4 (AYUV)" : "4:2:0") \
            (rate directives apply live)
            """)

        // The cursor plane travels as metadata (0x24), never as video;
        // file mode has no one to tell.
        let cursorWatcher = wire != nil ? EyeCursorWatcher(fd: fd) : nil
        if wire != nil {
            print(cursorWatcher != nil
                ? """
                    direct: cursor watcher on plane \
                    \(cursorWatcher!.planeId) — shapes ride 0x24
                    """
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

        // Recovery and keepalive frames run on the 1 ms poll, independent
        // of the 60 Hz observation grid.
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
                    print("""
                        direct: static-screen IDR served \
                        (re-encoded retained surface)
                        """)
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
            // One session-lock round trip per poll.
            let snapshot = wire?.takeLegSnapshot()
            if snapshot?.ended == true {
                sessionEnded = true
                break
            }
            // A signal exits through the normal door, so audio-routing
            // restore and the typed teardown both happen.
            if lyteTerminationRequested != 0 {
                print("session: termination signal — closing cleanly")
                terminationRequested = true
                break
            }
            // The cursor plane is read on the 60 Hz grid, not every poll.
            let cursorStart = SystemMonotonicClock.nowMicroseconds
            if cursorStart &- lastCursorPollUs >= Self.cursorPollMicroseconds {
                lastCursorPollUs = cursorStart
                pollCursor(cursorWatcher)
                lastStages.cursorUs =
                    SystemMonotonicClock.nowMicroseconds - cursorStart
            }

            // A late Best agreement reopens the encoder in 4:4:4 (once);
            // resetting sampling and identity makes the current screen
            // fresh, so the new encoder's first IDR carries it.
            if !pipeline.chroma444,
               ChromaPosture.from(
                   agreedChromaModes: snapshot?.agreedChromaModes
               ) == .yuv444 {
                do {
                    try pipeline.reopen(chroma444: true)
                    chroma444Active = true
                    samplingCadence.reset()
                    screen.resetIdentityObservation()
                    print("""
                        direct: Best tier agreed — encoder reopened as Rext \
                        4:4:4 (AYUV, one-pass blit)
                        """)
                } catch {
                    lastError = "direct: 4:4:4 reopen: \(error)"
                    return
                }
            }

            // The cap becomes the next frame's VBR envelope; no reset.
            if let directive = snapshot?.directive {
                pipeline.setRateControl(
                    bitsPerSecond: Int64(directive.maxBitsPerSecond),
                    hrdBufferBits: Int64(EncoderHrd.bufferBits(
                        capBitsPerSecond: directive.maxBitsPerSecond,
                        fps: Self.fps, vbvBits: directive.vbvBits)))
                directivesApplied += 1
                if directivesApplied == 1 {
                    print("""
                        direct: rate directive (\(directive.kind.rawValue)) \
                        applied — \(directive.maxBitsPerSecond / 1_000_000) \
                        Mbps cap
                        """)
                }
            }

            // Demands are taken every poll so recovery on a static desktop
            // never waits for damage; the retained surface is re-encoded
            // with its ORIGINAL capture time (not a network-late frame).
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
                    print("""
                        direct: observation beat skipped \(skippedBeats) \
                        beat(s) prev[\(lastStages.described())] ms
                        """)
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
                    print("""
                        direct: display mode changed \(width)x\(height)\
                         → \(newWidth)x\(newHeight) — ending \
                        session; the re-dial reads fresh geometry
                        """)
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
            // A queue at its latency budget gets no new frame; the reset
            // fingerprint re-observes the newest pixels next beat.
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
                // 1-in-1-out: keyframe truth rides on the packet.
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

        // No drain: the encoder is 1-in-1-out.
        print("""
            direct: eye closed — \(frames) frames, \(bytes) bytes, \
            \(keyframes) IDRs, missed_grabs=\(missedGrabs), \
            directives_applied=\(directivesApplied), \
            static_idrs=\(staticIdrsServed), \
            keepalives=\(keepalivesSent), \
            observations=\(observations), \
            framebuffer_transitions=\(framebufferTransitions), \
            pixel_changes=\(changedObservations), \
            observation_beats_skipped=\(skippedObservationBeats), \
            posture_announcements=\(postureAnnouncements), \
            delivery_failures=\(deliveryFailures), \
            admission_skips=\(admission.skipped), \
            cursor_shapes=\(cursorShapesSeen), \
            hotspot_corrections=\(cursorHotspotCorrections)
            """)
        serviceLock.lock()
        let serviceMaxUs = serviceMaxMicroseconds
        serviceLock.unlock()
        print("""
            direct: observation-book — beats=\(observations), \
            skip_events=\(observationSkipEvents), \
            beats_skipped=\(skippedObservationBeats), \
            pixel_changes=\(changedObservations), \
            stage_max[\(maxStages.described())] ms, \
            service_max=\(StageClocks.ms(serviceMaxUs)) ms (janitor thread)
            """)
    }

    /// One cursor poll: fb changes become 0x24s. The hotspot is
    /// pointer − plane CRTC − crop origin (i915 has no HOTSPOT props);
    /// see `CursorHotspot`.
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
            let pointer = wire.lastAbsolutePointerInjection().flatMap {
                InputCoordinate.pixel(x: $0.x, y: $0.y)
            }
            let plane = frame.planeCrtc.map {
                CursorHotspot.Point(x: $0.x, y: $0.y)
            }
            let hot = CursorHotspot.derive(
                pointer: pointer,
                planeCrtc: plane,
                crop: .init(x: frame.cropX, y: frame.cropY),
                width: frame.width, height: frame.height)
            // The first shapes print their inputs for diagnosis.
            if cursorShapesSeen <= 6 {
                let planeDesc = plane.map { "\($0.x),\($0.y)" }
                    ?? "nil"
                let pointerDesc = pointer.map { "\($0.x),\($0.y)" }
                    ?? "none"
                print("""
                    direct: cursor derive #\(cursorShapesSeen): \
                    \(frame.width)x\(frame.height) \
                    crop(\(frame.cropX),\(frame.cropY)) plane(\(planeDesc)) \
                    pointer(\(pointerDesc)) → hotspot(\(hot.x),\(hot.y))
                    """)
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

    /// 150 ms after the last pointer injection the plane sits exactly at
    /// pointer − hotspot: re-derive, and re-send only if it differs.
    private func recheckHotspotAtRest(
        _ watcher: EyeCursorWatcher, _ wire: SessionWire
    ) {
        guard hotspotRecheckArmed, let frame = lastCursorFrame,
              let sent = sentHotspot,
              let injected = wire.lastAbsolutePointerInjection(),
              let pointer = InputCoordinate.pixel(x: injected.x, y: injected.y)
        else { return }
        let nowMicros = UInt64(SystemMonotonicClock.nowSeconds * 1_000_000)
        guard nowMicros &- injected.atMicros > 150_000 else { return }
        guard let plane = watcher.planeCrtcPosition(),
              CursorHotspot.canRecheck(
                  planeCrtc: .init(x: plane.x, y: plane.y))
        else {
            // Props still absent — do not invent a correction.
            hotspotRecheckArmed = false
            return
        }
        let hot = CursorHotspot.derive(
            pointer: pointer,
            planeCrtc: .init(x: plane.x, y: plane.y),
            crop: .init(x: frame.cropX, y: frame.cropY),
            width: frame.width, height: frame.height)
        hotspotRecheckArmed = false
        guard hot.x != sent.x || hot.y != sent.y else { return }
        cursorHotspotCorrections += 1
        print("""
            direct: cursor hotspot corrected (\(sent.x),\(sent.y)) → \
            (\(hot.x),\(hot.y)) at rest — plane(\(plane.x),\(plane.y)) \
            pointer(\(pointer.x),\(pointer.y))
            """)
        sentHotspot = (hot.x, hot.y)
        wire.noteCursorShape(CursorShape(
            width: UInt16(frame.width),
            height: UInt16(frame.height),
            hotspotX: UInt16(hot.x), hotspotY: UInt16(hot.y),
            pixels: frame.pixels))
    }

    /// The agreed chroma posture, or 4:2:0 when no declaration lands
    /// within the opening wait or there is no session (file mode).
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

    /// Delivers one access unit, attaching the owed causes to a keyframe.
    /// A refused keyframe leaves the IDR (and its causes) owed.
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
                    print("""
                        direct: session refused frame \
                        (\(keyframe ? "IDR" : "P")): \(error)
                        """)
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
