import SwiftUI
@preconcurrency import AVFoundation
import LyteTransport
import LyteUI
import LyteWire

/// Per-window connection state machine: pick host → (pair) → connect →
/// stream. Owns the Lyte-UDP session, display layer, and input capture.
@MainActor
@Observable
final class ConnectionModel {
    enum Phase {
        case pickHost
        case connecting(String)
        case streaming
        case failed(String)
    }

    var phase: Phase = .pickHost
    var muted = false {
        didSet { lyteSession?.setAudioMuted(muted) }
    }
    var statusLine = ""

    // CL-13: host audio routing — the strip's truth. `hostAudioNegotiated`
    // decides whether the host-mute control EXISTS (capability key 9
    // survived intersection); `hostAudioPosture` is the 0x19-confirmed
    // state, nil until the host's first status. Never set optimistically:
    // the toggle asks and waits for the wire's answer.
    private(set) var hostAudioNegotiated = false
    private(set) var hostAudioPosture: HostAudioRoutingMode?
    // CL-15: clipboard sharing — `clipboardNegotiated` decides whether
    // the strip's toggle EXISTS (key 10 survived intersection);
    // `clipboardSharing` is the live consent state (seeded from the
    // per-host default at connect, default OFF — clipboards carry
    // passwords). The pasteboard watcher runs only while both hold.
    private(set) var clipboardNegotiated = false
    private(set) var clipboardSharing = false
    private var pasteboardSync: PasteboardSync?
    /// The stats readout's visibility (the strip's chart toggle).
    var statsVisible = false

    private(set) var hostAddress: String?
    private(set) var hostName: String?
    /// The pinned identity hash of the streaming host — the per-host
    /// preference key (CL-13).
    private(set) var hostPublicKeyHash: String?
    let displayLayer = AVSampleBufferDisplayLayer()

    // The Lyte-UDP session (CL-8). Mode/pill mirror the session's
    // mediaReceiver machine for the stream overlay.
    private(set) var lyteSession: LyteUdpSession?
    private(set) var lyteWireMode: SessionWireMode = .active
    private(set) var lyteFrozen = false
    // CL-9: the host's stream dimensions (from the first delivered
    // sample's format description) — LyteInputCapture's coordinate
    // space; the capture drops absolute moves until this is known.
    private(set) var lyteVideoSize: CGSize = .zero
    var lyteInputCapture: LyteInputCapture?

    var windowTitle: String {
        switch phase {
        case .streaming:
            return "\(hostName ?? hostAddress ?? "host") — Lyte"
        default:
            return "Lyte"
        }
    }

    // MARK: - Streaming

    /// Clicking a PAIRED discovered Lyte host: zero-UI 1-RTT Noise IK
    /// against the pinned static + Keychain identity, then the stream
    /// window. Unpaired hosts go through the pairing sheet instead
    /// (ConnectView routes them there).
    func connectLyte(_ host: DiscoveredLyteHost) async {
        guard let pinned = PinnedHostStore.load().host(publicKeyHash: host.publicKeyHash),
              let hostStatic = pinned.staticPublicKey else {
            phase = .failed("\(host.name) is not paired — use Pair… first")
            return
        }
        hostAddress = host.address
        hostName = host.name
        hostPublicKeyHash = host.publicKeyHash
        phase = .connecting("Connecting to \(host.name) over Lyte-UDP…")

        let identity: NoiseKeyPair
        do {
            identity = try ClientNoiseIdentity.loadOrCreate()
        } catch {
            // The Keychain path needs the stable "Lyte Dev" signature —
            // builds via Scripts/make-app.sh (docs/MACOS-SIGNING.md).
            phase = .failed("client identity: \(error)")
            return
        }
        let crypto: NoiseTransportCrypto
        do {
            crypto = try NoiseTransportCrypto(
                hostAddress: host.address,
                hostPort: host.port,
                hostStaticPublicKey: hostStatic,
                staticKeys: identity)
        } catch {
            phase = .failed("host key: \(error)")
            return
        }

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        let renderer = displayLayer.sampleBufferRenderer

        // CL-13/CL-18: the per-host preference seeds the session-start
        // posture — one 0x18 leaves after the host's first 0x19 when
        // they differ. Since CL-18 the unset default is hostMuted
        // (sound follows the viewer); only the explicit "start
        // audible" opt-out asks for the host's speakers. The strip's
        // toggle is the live override thereafter.
        var sessionConfig = LyteUdpSession.Config()
        sessionConfig.core.desiredHostAudioRouting =
            pinned.sessionStartHostAudioRouting
        // CL-15: the per-host clipboard consent seeds the session's
        // starting posture; the strip's toggle is the live override.
        sessionConfig.core.shareClipboard = pinned.shareClipboard == true

        let lastDims = VideoDimsCell()
        let lyte = LyteUdpSession(
            crypto: crypto,
            config: sessionConfig,
            onSample: { [weak self] sample, _ in
                renderer.enqueue(sample)
                // Teach the input capture its coordinate space — once
                // per size, not per sample (dimension changes are a
                // renegotiation-era event, but wired honestly now).
                if let format = CMSampleBufferGetFormatDescription(sample) {
                    let dims = CMVideoFormatDescriptionGetDimensions(format)
                    if lastDims.update(width: dims.width, height: dims.height) {
                        Task { @MainActor [weak self] in
                            self?.lyteVideoSize = CGSize(
                                width: CGFloat(dims.width),
                                height: CGFloat(dims.height))
                        }
                    }
                }
            },
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleLyteEvent(event)
                }
            })

        // start() blocks through bind + the Noise handshake (retry
        // timer inside) — off the main actor.
        do {
            try await Task.detached { try lyte.start() }.value
        } catch {
            phase = .failed("Lyte-UDP connect: \(error)")
            return
        }
        lyteSession = lyte
        lyteWireMode = .active
        lyteFrozen = false
        hostAudioNegotiated = false
        hostAudioPosture = nil
        clipboardNegotiated = false
        clipboardSharing = pinned.shareClipboard == true
        // The watcher exists per session, started only once key 10
        // agrees AND sharing is on (updatePasteboardWatcher). The
        // core judges every change; the glue only reads and applies.
        pasteboardSync = PasteboardSync(onLocalChange: { [weak lyte] text in
            lyte?.shareLocalClipboard(text)
        })
        phase = .streaming
        statusLine = crypto.modeDescription
        AgentState.shared.streamBegan()
    }

    private func handleLyteEvent(_ event: LyteUdpSessionEvent) {
        switch event {
        case .capabilitiesAgreed(let agreed):
            statusLine = "capabilities agreed — idle silence "
                + (agreed.idleSilence ? "on" : "off")
            // The strip's host-mute button exists exactly when key 9
            // survived intersection (CL-13).
            hostAudioNegotiated = agreed.hostAudioRouting
            // CL-15: the clipboard toggle exists exactly when key 10
            // survived; the watcher starts if consent is already on.
            clipboardNegotiated = agreed.clipboardText
            updatePasteboardWatcher()
        case .hostAudioRoutingStatus(let mode):
            hostAudioPosture = mode
        case .hostClipboardChanged(let text):
            // Already through the core's gates (negotiated + sharing
            // on, book pre-armed); the glue just applies.
            pasteboardSync?.apply(text)
        case .capabilitiesFailed(let why):
            endLyteSession(reason: "capabilities failed: \(why)")
        case .capabilityUpdateAnswered:
            break
        case .modeChanged(let wireMode):
            lyteWireMode = wireMode
        case .stateChanged(let state):
            lyteFrozen = state == .frozen
        case .idleFrameReceived, .teardownSent, .protocolNote:
            break
        case .closed(let reason):
            switch reason {
            case .localTeardown:
                break   // endLyteSession is already driving the close
            case .peerTeardown(let why):
                endLyteSession(reason: why == .takenOver
                    ? "session taken over by another client" : nil)
            case .livenessTimeout:
                endLyteSession(reason: "host unreachable for 30 s")
            }
        }
    }

    /// Ends the Lyte-UDP session: the typed goodbye (with its ACK
    /// linger) runs off-main; UI state resets immediately.
    private func endLyteSession(reason: String?) {
        guard let lyte = lyteSession else { return }
        lyteSession = nil
        lyteFrozen = false
        hostAudioNegotiated = false
        hostAudioPosture = nil
        pasteboardSync?.stop()
        pasteboardSync = nil
        clipboardNegotiated = false
        clipboardSharing = false
        statsVisible = false
        lyteInputCapture?.stop()
        lyteInputCapture = nil
        lyteVideoSize = .zero
        Task.detached {
            // A peer/liveness close has nobody to say goodbye to; a
            // local end sends the typed 0x0A and lingers for its ACK.
            lyte.close(reason: .shuttingDown)
        }
        AgentState.shared.streamEnded()
        if let reason {
            phase = .failed(reason)
        } else {
            phase = .pickHost
        }
    }

    func endSession(reason: String?) {
        endLyteSession(reason: reason)
    }

    func disconnect() {
        endSession(reason: nil)
    }

    // MARK: - Host audio routing (CL-13)

    /// True when the 0x19-confirmed posture says the host's speakers
    /// are silent. The strip and the Actions menu render THIS — never
    /// the ask in flight.
    var hostMuted: Bool { hostAudioPosture == .hostMuted }

    /// Asks the host to flip its own speakers (0x18 on the ordered
    /// stream). The UI's toggle stays where the last 0x19 put it until
    /// the next one answers — a failed flip therefore visibly snaps
    /// back. Only reachable when `hostAudioNegotiated` (button gating),
    /// so the refusal path is a teardown race, counted as weather.
    func setHostMuted(_ muted: Bool) {
        guard hostAudioNegotiated else { return }
        try? lyteSession?.requestHostAudioRouting(
            muted ? .hostMuted : .hostAudible)
    }

    /// The per-host "start sessions with host muted" default, read
    /// live from the pinned store (CL-13; opt-out semantics since
    /// CL-18 — unset means muted, so this reads `!= false` and writes
    /// BOTH directions explicitly: unchecking is the "start audible"
    /// opt-out, not a reset). Applied at connect; the strip's toggle
    /// overrides live without touching it.
    var startHostMutedPreference: Bool {
        get {
            guard let pkh = hostPublicKeyHash,
                  let pinned = PinnedHostStore.load().host(publicKeyHash: pkh)
            else { return true }   // the CL-18 default posture
            return pinned.startHostAudioMuted != false
        }
        set {
            guard let pkh = hostPublicKeyHash else { return }
            var store = PinnedHostStore.load()
            store.setStartHostAudioMuted(publicKeyHash: pkh, muted: newValue)
            try? store.save()
        }
    }

    // MARK: - Clipboard sharing (CL-15)

    /// The strip's live consent toggle. Only reachable when
    /// `clipboardNegotiated` (button gating); flips the core's gate
    /// (nothing leaves, nothing lands, while off) and the watcher.
    func setClipboardSharing(_ enabled: Bool) {
        guard clipboardNegotiated else { return }
        clipboardSharing = enabled
        lyteSession?.setClipboardSharing(enabled)
        updatePasteboardWatcher()
    }

    /// The watcher polls exactly while consent AND capability hold —
    /// while off, the pasteboard is never even read.
    private func updatePasteboardWatcher() {
        if clipboardNegotiated, clipboardSharing, lyteSession != nil {
            pasteboardSync?.start()
        } else {
            pasteboardSync?.stop()
        }
    }

    /// The per-host "share clipboard" default, read live from the
    /// pinned store (CL-15). Applied at connect; the strip's toggle
    /// overrides live without touching it.
    var shareClipboardPreference: Bool {
        get {
            guard let pkh = hostPublicKeyHash else { return false }
            return PinnedHostStore.load()
                .host(publicKeyHash: pkh)?.shareClipboard == true
        }
        set {
            guard let pkh = hostPublicKeyHash else { return }
            var store = PinnedHostStore.load()
            store.setShareClipboard(
                publicKeyHash: pkh, share: newValue ? true : nil)
            try? store.save()
        }
    }

    // MARK: - Window verbs (strip + Actions menu, same commands)

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    // MARK: - The stats readout (CL-13)

    /// A compact snapshot of the session's existing books — the same
    /// counters wire-view prints, shaped for the overlay. Re-read on
    /// every call; the overlay's TimelineView drives the cadence.
    func statsLines() -> [String] {
        guard let session = lyteSession,
              let endpoint = session.endpoint,
              let core = session.core else { return [] }
        var lines: [String] = []

        let totals = endpoint.demux.snapshotTotals()
        var wire = "\(totals.accepted)/\(totals.datagrams) datagrams ok"
        if totals.unsealFailures > 0 {
            wire += ", \(totals.unsealFailures) unseal-failed"
        }
        lines.append(wire)

        var mode = "mode \(core.wireMode == .active ? "ACTIVE" : "IDLE")"
        if core.isFrozen { mode += " — FROZEN" }
        if hostAudioNegotiated {
            switch hostAudioPosture {
            case .hostMuted: mode += " · host audio muted"
            case .hostAudible: mode += " · host audio audible"
            case nil: mode += " · host audio pending"
            }
        }
        if clipboardNegotiated {
            mode += clipboardSharing ? " · clipboard on" : " · clipboard off"
        }
        lines.append(mode)

        // The HS-22 quality line — what the receive side can say about
        // incoming video from its own books (frame cadence, bitrate,
        // frame-size percentiles over ~5 s). Host QP/encoder posture
        // are host-log truth; this is the client-side half.
        if let q = core.pipeline.snapshotStats().quality {
            lines.append(String(
                format: "video %.0f fps · %.1f Mbps · frame p50 %d B · p95 %d B",
                q.framesPerSecond, Double(q.bitsPerSecond) / 1e6,
                q.frameBytesP50, q.frameBytesP95))
        }

        // Unconditional, capture verdict included (CL-16): "input 0
        // sent · capture INACTIVE" is the line that tells a client
        // failure from a host one.
        lines.append(core.input.snapshotStats()
            .overlayLine(captureActive: lyteInputCapture != nil))

        let audio = core.audio.snapshotStats()
        if audio.depacketizer.datagramsIngested > 0 {
            var line = "audio"
            if let p50 = audio.bufferDepthPackets.p50,
               let p99 = audio.bufferDepthPackets.p99 {
                line += " depth p50/p99 \(p50)/\(p99) pkts"
            }
            line += " · plc \(audio.jitter.plcInvocations)"
            if audio.depacketizer.packetsRebuilt > 0 {
                line += " · fec \(audio.depacketizer.packetsRebuilt)"
            }
            lines.append(line)
        }

        let clipboard = core.snapshotCounters()
        let clipboardActivity = clipboard.clipboardSharesSent
            + clipboard.clipboardAnnouncesReceived
            + clipboard.clipboardLoopSuppressed
        if clipboardNegotiated, clipboardActivity > 0 {
            lines.append("clipboard \(clipboard.clipboardSharesSent) sent"
                + " · \(clipboard.clipboardAnnouncesReceived) recv"
                + " · \(clipboard.clipboardLoopSuppressed) suppressed")
        }
        return lines
    }
}

/// Latched (width, height) so the sample callback hops to the main
/// actor only when the stream dimensions actually change (CL-9's
/// coordinate-space feed; samples arrive on the receive thread).
private final class VideoDimsCell: @unchecked Sendable {
    private let lock = NSLock()
    private var width: Int32 = 0
    private var height: Int32 = 0
    /// True when this (width, height) is new.
    func update(width: Int32, height: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard width != self.width || height != self.height else { return false }
        self.width = width
        self.height = height
        return true
    }
}
