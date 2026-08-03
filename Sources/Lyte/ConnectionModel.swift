import SwiftUI
@preconcurrency import AVFoundation
import LyteTransport
import LyteUI
import LyteWire
import UniformTypeIdentifiers

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

    /// Fresh-connect patience (the respawn-gap hunt in connectLyte):
    /// silence keeps re-dialing until this budget runs out. Sized to
    /// cover a full host restart (portal reopen + self-probes,
    /// 10–15 s observed) with margin, not to camp forever.
    static let freshConnectBudgetMicroseconds: UInt64 = 45_000_000
    /// Invalidates in-flight connect rounds (Cancel, or a newer
    /// connect superseding an old one mid-dial).
    private var connectGeneration = 0
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
    /// Postures design (key 14): whether the WIRE audio-off control
    /// exists — mode 0x03 survived intersection. The posture itself
    /// still rides `hostAudioPosture` (0x19 truth, never the ask).
    private(set) var audioStreamOffNegotiated = false
    /// The posture to return to when the stream comes back on — the
    /// last 0x19-confirmed STREAMING mode (streamOff never lands
    /// here). Seeded with the CL-18 default.
    private var lastStreamingAudioPosture: HostAudioRoutingMode = .hostMuted
    // CL-15: clipboard sharing — `clipboardNegotiated` decides whether
    // the strip's toggle EXISTS (key 10 survived intersection);
    // `clipboardSharing` is the live consent state (seeded from the
    // per-host default at connect, default OFF — clipboards carry
    // passwords). The pasteboard watcher runs only while both hold.
    private(set) var clipboardNegotiated = false
    private(set) var clipboardSharing = false
    // P-1: the images rung — `clipboardImagesNegotiated` decides
    // whether the rung's toggle EXISTS (keys 10∧12 both survived);
    // `clipboardImageSharing` is its live consent state. Images move
    // only when text sharing AND this both hold (Text + images).
    private(set) var clipboardImagesNegotiated = false
    private(set) var clipboardImageSharing = false
    private var pasteboardSync: PasteboardSync?
    // F-4: bulk transfer — `bulkNegotiated` decides whether a drop can
    // OFFER (key 11 survived intersection = the host's standing
    // consent toggle is on); `bulkStatus` mirrors the coordinator's
    // snapshot for the progress pill; `bulkNotice` is the transient
    // verdict line ("sent", "host isn't accepting files", …).
    private(set) var bulkNegotiated = false
    private(set) var bulkStatus = BulkSendSnapshot.idle
    private(set) var bulkNotice: String?
    /// The coordinator OUTLIVES the wire session (that is what makes
    /// resume-on-reconnect real: it keeps the transfer id + path and
    /// re-offers the same id into the next session) but never a host
    /// change — a file dropped for one host must not follow the user
    /// to another.
    private var bulkCoordinator: BulkSendCoordinator?
    private var bulkCoordinatorHostKey: String?
    private var bulkNoticeTask: Task<Void, Never>?
    // V-5: the Chroma tier (owner decision 1) — the live per-window
    // declaration choice (Good = 4:2:0 / Better = 4:2:2 dormant /
    // Best = 4:4:4), seeded from the per-host default at connect.
    // Flipping it is a CLEAN RECONNECT with the new declaration
    // (declaration-as-choice: chroma is connect-time only). The
    // fallback path (Best against a host without it) downgrades THIS
    // live state, never the persisted preference. `chromaNotice` is
    // the non-modal fallback banner.
    private(set) var chromaTier: ChromaTier = .good
    private(set) var chromaNotice: String?
    private var chromaNoticeTask: Task<Void, Never>?
    /// The stats readout's visibility (the strip's chart toggle).
    var statsVisible = false

    private(set) var hostAddress: String?
    private(set) var hostName: String?
    /// The pinned identity hash of the streaming host — the per-host
    /// preference key (CL-13).
    private(set) var hostPublicKeyHash: String?
    let displayLayer = AVSampleBufferDisplayLayer()
    /// Video samples hop OFF the receive thread before touching the
    /// renderer: during a live window resize the layer is mid-CA-
    /// transaction on main and `enqueue` can block against it — and
    /// the receive thread demuxes AUDIO too, so a resize storm was
    /// chopping playback (underruns with zero loss, found live
    /// 2026-07-30). A serial hop keeps frame order; a transient
    /// enqueue stall now queues video frames here instead of damming
    /// the socket.
    private let videoDeliveryQueue = DispatchQueue(
        label: "lyte.video.delivery", qos: .userInteractive)
    private let videoDeliveryBooks = VideoDeliveryBooks()
    /// Actual-app flight recorder: source cadence, receive cadence,
    /// delivery queue, renderer enqueue, and Apple's decode/display books.
    /// Bounded to six seconds at 60 fps and always on — visual failures
    /// cannot depend on the stats overlay being open.
    private let videoFlightRecorder = VideoFlightRecorder()
    /// The link-health fold over the recorder's ring (already-measured
    /// per-frame stage timings → one user-facing verdict). Ticked at
    /// 1 Hz from the stream container; the meter's ordinal high-water
    /// mark makes overlapping scans idempotent, and a recorder reset
    /// (ordinals restart) clears it implicitly.
    private let linkHealthMeter = LinkHealthMeter()
    /// Last cushion ceiling pushed into the live playout — the 1 Hz
    /// tick compares the slider against this to apply changes
    /// mid-stream.
    private var appliedCushionMicroseconds: UInt64 = 0
    /// nil until streaming produces a verdict; .good renders nothing —
    /// a clean link needs no announcement.
    private(set) var linkHealth: LinkHealthAssessment?
    /// in-fps over the same ~1 s window shape as the delivery books'
    /// out-fps, so the overlay's in/out slash-pair compares honestly.
    private let videoInMeter = RateMeter()
    private var videoRendererHandoff: VideoRendererHandoff?

    // F-5: roaming/reconnect. The policy exists for the whole
    // streaming life of a window (it IS the "can this window
    // reconnect" verdict); its status drives the stream overlay's
    // banner. `sessionEpoch` fences late events from detached
    // sessions — a re-dial mints a new epoch and the dead session's
    // stragglers (a .closed racing the teardown, mostly) are noise.
    private var roaming: RoamingPolicy?
    private var roamingTask: Task<Void, Never>?
    private(set) var roamingStatus: RoamingStatus = .attached
    private var pathWatcher: NetworkPathWatcher?
    private var sessionEpoch = 0

    /// The stream overlay's roaming banner; nil while the session is
    /// healthy (or merely FROZEN — the pill's tier).
    var roamingStatusLine: String? {
        RoamingStatusLine.line(
            for: roamingStatus,
            hostName: hostName ?? hostAddress ?? "the host")
    }

    /// The Actions menu's Reconnect verb exists while a streaming
    /// window has an identity to hunt (roaming or not — a manual
    /// reconnect over a limping session is legitimate).
    var canReconnect: Bool { roaming != nil }

    /// Disconnect must work during roaming too — the session object
    /// is gone but the window still hunts.
    var canEndSession: Bool { lyteSession != nil || roaming != nil }

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
    /// E3: the stream surface, held weakly so the model can dress it
    /// with the host's announced cursor (StreamView installs it).
    weak var lyteVideoView: VideoLayerView?

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
        HandshakeWitness.record("autoconnectBegin", fields: [
            "host": host.address,
            "port": String(host.port),
        ])

        let environment = ProcessInfo.processInfo.environment
        // A benchmark autoconnect has no human interaction surface. Never
        // let Security.framework wait on hidden authorization UI before the
        // first handshake byte; an ACL problem must fail bounded and loud.
        let identityAuthenticationUI:
            ClientNoiseIdentityProvider.AuthenticationUI =
                environment["LYTE_BENCHMARK_RUN_ID"] == nil ? .allow : .fail
        let identity: NoiseKeyPair
        do {
            // SecItemCopyMatching may synchronously cross securityd and
            // wait for Keychain authorization. It must never pin the
            // MainActor: doing so makes the whole stream window vanish
            // into an unresponsive app before the first handshake byte.
            HandshakeWitness.record("identityLookupBegin", fields: [
                "authenticationUI":
                    identityAuthenticationUI == .allow ? "allow" : "fail",
            ])
            identity = try await ClientNoiseIdentityProvider.shared.identity(
                authenticationUI: identityAuthenticationUI)
            HandshakeWitness.record("identityLookupCompleted")
        } catch {
            HandshakeWitness.record("identityLookupFailed", fields: [
                "error": String(describing: error),
            ])
            // The Keychain path needs the stable "Lyte Dev" signature —
            // builds via Scripts/make-app.sh (docs/MACOS-SIGNING.md).
            phase = .failed("client identity: \(error)")
            return
        }

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
        // P-1: the images rung rides only on top of text consent.
        sessionConfig.core.shareClipboardImages =
            pinned.shareClipboard == true
            && pinned.shareClipboardImages == true
        // V-5: the per-host Chroma tier seeds the declaration — the
        // chroma singleton IS the choice (the host maps it straight
        // to an encoder posture).
        let benchmarkChroma = environment["LYTE_BENCHMARK_RUN_ID"] == nil
            ? nil
            : environment["LYTE_BENCHMARK_CHROMA_TIER"]
                .flatMap(ChromaTier.init(rawValue:))
        if let benchmarkChroma, benchmarkChroma.isSelectable {
            chromaTier = benchmarkChroma
        } else {
            chromaTier = pinned.sessionChromaTier
        }
        sessionConfig.core.capabilities = sessionConfig.core.capabilities
            .declaringChroma(tier: chromaTier)

        // The respawn-gap patience: a paired host that answered
        // discovery moments ago but is SILENT now is almost always
        // rebooting (the dev loop runs one host process per session;
        // a production restart looks the same) — its boot takes
        // 10–15 s of portal/probe setup while a single dial gives up
        // in ~10. So silence hunts instead of dead-ending: short
        // dials (the roaming shape, 3 × 700 ms), a 2 s re-browse
        // between them (the reborn host re-registers — follow its
        // freshest address), inside one honest budget. Every OTHER
        // failure — crypto rejection, unpaired, socket errors —
        // still fails immediately: patience is only for silence.
        connectGeneration += 1
        let generation = connectGeneration
        let deadline = Self.monotonicMicroseconds()
            + Self.freshConnectBudgetMicroseconds
        var dialAddress = host.address
        var dialPort = host.port
        var round = 0
        let lyte: LyteUdpSession
        while true {
            round += 1
            let crypto: NoiseTransportCrypto
            do {
                crypto = try NoiseTransportCrypto(
                    hostAddress: dialAddress,
                    hostPort: dialPort,
                    hostStaticPublicKey: hostStatic,
                    staticKeys: identity,
                    attempts: round == 1 ? 5 : 3,
                    attemptTimeoutMilliseconds: round == 1 ? 2_000 : 700)
            } catch {
                phase = .failed("host key: \(error)")
                return
            }
            let candidate = makeLyteSession(
                crypto: crypto, config: sessionConfig)
            // start() blocks through bind + the Noise handshake (retry
            // timer inside) — off the main actor.
            do {
                HandshakeWitness.record("sessionStartBegin", fields: [
                    "round": String(round),
                    "host": dialAddress,
                    "port": String(dialPort),
                ])
                try await Task.detached { try candidate.start() }.value
                HandshakeWitness.record("sessionStartCompleted", fields: [
                    "round": String(round),
                ])
                guard generation == connectGeneration,
                      case .connecting = phase else {
                    // The human cancelled mid-dial: this session has
                    // no owner — close it politely and walk away.
                    Task.detached { candidate.close(reason: .shuttingDown) }
                    return
                }
                lyte = candidate
                hostAddress = dialAddress
                statusLine = crypto.modeDescription
                break
            } catch {
                HandshakeWitness.record("sessionStartFailed", fields: [
                    "round": String(round),
                    "error": String(describing: error),
                ])
                guard generation == connectGeneration,
                      case .connecting = phase else { return }
                guard case TransportCryptoError.handshakeFailed(let why)
                        = error, why.hasPrefix("no response"),
                      Self.monotonicMicroseconds() < deadline else {
                    phase = .failed("Lyte-UDP connect: \(error)")
                    return
                }
                phase = .connecting("\(host.name) isn't answering — "
                    + "it may be restarting; still trying…")
                // The quiet re-browse: if the reborn host is already
                // advertising, dial where it lives NOW.
                let sighting = await LyteDiscovery.browse(duration: 2.0)
                    .first { $0.publicKeyHash == host.publicKeyHash }
                guard generation == connectGeneration,
                      case .connecting = phase else { return }
                if let sighting {
                    dialAddress = sighting.address
                    dialPort = sighting.port
                }
            }
        }
        lyteSession = lyte
        lyte.setAudioMuted(muted)
        lyteWireMode = .active
        lyteFrozen = false
        hostAudioNegotiated = false
        audioStreamOffNegotiated = false
        hostAudioPosture = nil
        clipboardNegotiated = false
        clipboardSharing = pinned.shareClipboard == true
        clipboardImagesNegotiated = false
        clipboardImageSharing = sessionConfig.core.shareClipboardImages
        // The watcher exists per session, started only once key 10
        // agrees AND sharing is on (updatePasteboardWatcher). The
        // core judges every change; the glue only reads and applies.
        pasteboardSync = makePasteboardSync(for: lyte)
        bulkNegotiated = false
        // The pinned lookup above guarantees a pkh in practice; the
        // address fallback keeps the key total.
        prepareBulkCoordinator(hostKey: host.publicKeyHash ?? host.address)
        // F-5: the roaming brain + the client-side path monitor exist
        // for the window's whole streaming life.
        if let pkh = host.publicKeyHash {
            startRoamingMachinery(
                publicKeyHash: pkh, address: host.address, port: host.port)
        }
        phase = .streaming
        AgentState.shared.streamBegan()
    }

    /// The connecting screen's Cancel: invalidates the in-flight
    /// connect (any round that completes afterward closes its session
    /// politely and walks away) and returns to the picker.
    func cancelConnect() {
        connectGeneration += 1
        phase = .pickHost
    }

    /// Builds one wire session against this window's display layer,
    /// minting a fresh event epoch — the shared leg of the first
    /// connect and every roaming re-dial.
    private func makeLyteSession(
        crypto: NoiseTransportCrypto, config: LyteUdpSession.Config
    ) -> LyteUdpSession {
        videoFlightRecorder.reset()
        videoDeliveryBooks.reset()
        videoInMeter.reset()
        videoRendererHandoff?.stop()
        displayLayer.sampleBufferRenderer.flush()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        let hostClock = CMClockGetHostTimeClock()
        var timebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: hostClock,
            timebaseOut: &timebase) == noErr,
           let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(hostClock))
            CMTimebaseSetRate(timebase, rate: 1)
            displayLayer.controlTimebase = timebase
        }
        let renderer = displayLayer.sampleBufferRenderer
        let clockModel = HostClockModel()
        let recoveryRequester = VideoRecoveryRequester()
        let handoff = VideoRendererHandoff(
            renderer: renderer,
            queue: videoDeliveryQueue,
            clockModel: clockModel,
            books: videoDeliveryBooks,
            recorder: videoFlightRecorder,
            recoveryRequester: recoveryRequester,
            playoutConfig: Self.playoutConfigFromSettings())
        appliedCushionMicroseconds = Self.cushionMicrosecondsFromSettings()
        videoRendererHandoff = handoff
        let lastDims = VideoDimsCell()
        sessionEpoch += 1
        let epoch = sessionEpoch
        let session = LyteUdpSession(
            crypto: crypto,
            config: config,
            clockModel: clockModel,
            onVideoRecoveryDemand: { [weak handoff] cause, frame in
                handoff?.beginRecovery(cause: cause, after: frame)
            },
            onVideoRecoveryTrace: { [videoFlightRecorder] event in
                videoFlightRecorder.recordRecoveryLifecycle(
                    kind: event.kind,
                    frame: event.frame.rawValue,
                    cause: event.cause,
                    isRandomAccess: event.isRandomAccess)
            },
            onSample: {
                [weak self, handoff] sample, unit in
                handoff.submit(sample: sample, unit: unit)
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
                    self?.handleLyteEvent(event, epoch: epoch)
                }
            })
        recoveryRequester.bind(session)
        return session
    }

    private func handleLyteEvent(_ event: LyteUdpSessionEvent, epoch: Int) {
        // A detached session's stragglers must not touch the model —
        // the epoch fence (F-5): only the CURRENT session speaks.
        guard epoch == sessionEpoch else { return }
        handleLyteEvent(event)
    }

    /// E3: wear the host's announced cursor over the stream. The
    /// scale maps host device pixels onto the video's current
    /// on-glass points through the aspect-fit rect, so the worn
    /// shape matches the video's magnification; before the first
    /// sample lands (no video size yet) 0.75 approximates the host's
    /// 1.333 logical scale.
    private func applyHostCursor(_ shape: CursorShape) {
        guard let view = lyteVideoView else { return }
        var scale: CGFloat = 0.75
        if lyteVideoSize.width > 0, view.bounds.width > 0 {
            let fit = AVMakeRect(
                aspectRatio: lyteVideoSize, insideRect: view.bounds)
            scale = fit.width / lyteVideoSize.width
        }
        view.hostCursor = HostCursorImage.cursor(from: shape, scale: scale)
    }

    private func handleLyteEvent(_ event: LyteUdpSessionEvent) {
        switch event {
        case .capabilitiesAgreed(let agreed):
            statusLine = "capabilities agreed — idle silence "
                + (agreed.idleSilence ? "on" : "off")
            // The strip's host-mute button exists exactly when key 9
            // survived intersection (CL-13).
            hostAudioNegotiated = agreed.hostAudioRouting
            audioStreamOffNegotiated = agreed.audioStreamOff
            // CL-15: the clipboard toggle exists exactly when key 10
            // survived; the watcher starts if consent is already on.
            clipboardNegotiated = agreed.clipboardText
            // P-1: the images rung exists exactly when 10∧12 survived
            // (a text-only host truthfully never declares key 12).
            clipboardImagesNegotiated = agreed.clipboardImagesAgreed
            updatePasteboardWatcher()
            // F-4: attach the coordinator's chan-8 leg. A transfer the
            // last session interrupted re-offers its SAME id here.
            bulkNegotiated = agreed.bulkTransfer
            let session = lyteSession
            bulkCoordinator?.sessionReady(
                negotiated: agreed.bulkTransfer,
                send: { [weak session] bytes in
                    // A refused send is a teardown race — the ARQ
                    // state is dying with the session; resume covers.
                    try? session?.sendBulkMessage(bytes)
                })
        case .bulkMessageReceived(let message):
            bulkCoordinator?.ingest(message)
        case .hostAudioRoutingStatus(let mode):
            hostAudioPosture = mode
            if mode != .streamOff { lastStreamingAudioPosture = mode }
        case .hostClipboardChanged(let text):
            // Already through the core's gates (negotiated + sharing
            // on, book pre-armed); the glue just applies.
            pasteboardSync?.apply(text)
        case .hostCursorShapeChanged(let shape):
            applyHostCursor(shape)
        case .hostClipboardImageChanged(let data, _):
            // P-1: sha-verified PNG through the core's gates (10∧12 +
            // the images tier, book pre-armed); the glue just applies.
            pasteboardSync?.apply(imageData: data)
        case .capabilitiesFailed(let failure):
            handleCapabilitiesFailure(failure)
        case .capabilityUpdateAnswered:
            break
        case .modeChanged(let wireMode):
            lyteWireMode = wireMode
        case .stateChanged(let state):
            lyteFrozen = state == .frozen
            // F-5: the FROZEN edge feeds the roaming silence clock;
            // any other state is evidence moving again.
            if state == .frozen {
                roamingInput { policy, now in policy.wentSilent(now: now) }
            } else {
                roamingInput { policy, now in
                    policy.evidenceReturned(now: now)
                }
            }
        case .idleFrameReceived, .teardownSent, .protocolNote:
            break
        case .closed(let reason):
            switch reason {
            case .localTeardown:
                break   // endLyteSession is already driving the close
            case .peerTeardown(let why):
                // A typed goodbye is a decision, not weather — the
                // host MEANT to end this; roaming would fight it.
                endLyteSession(reason: why == .takenOver
                    ? "session taken over by another client" : nil)
            case .livenessTimeout:
                // F-5: the liveness verdict was the hotel experience —
                // a dead frame and a "host unreachable" bounce. Now it
                // begins roaming: keep the window, hunt the identity.
                beginRoamingAfterLoss()
            }
        }
    }

    /// Ends the Lyte-UDP session for good: the typed goodbye (with its
    /// ACK linger) runs off-main; UI state resets immediately; any
    /// roaming hunt stops — this is the human's exit, roaming's
    /// included (during a hunt the session object is already gone and
    /// only the roaming machinery needs stopping).
    private func endLyteSession(reason: String?) {
        guard lyteSession != nil || roaming != nil else { return }
        stopRoamingMachinery()
        lyteInputCapture?.stop()
        lyteInputCapture = nil
        // E3: back to AppKit's own arrow — a dead session must not
        // leave the host's shape (or its hidden state) stuck on.
        lyteVideoView?.hostCursor = nil
        if let lyte = lyteSession {
            lyteSession = nil
            sessionEpoch += 1
            Task.detached {
                // A peer/liveness close has nobody to say goodbye to;
                // a local end sends the typed 0x0A and lingers for
                // its ACK.
                lyte.close(reason: .shuttingDown)
            }
        }
        lyteFrozen = false
        hostAudioNegotiated = false
        audioStreamOffNegotiated = false
        hostAudioPosture = nil
        pasteboardSync?.stop()
        pasteboardSync = nil
        clipboardNegotiated = false
        clipboardSharing = false
        clipboardImagesNegotiated = false
        clipboardImageSharing = false
        // F-4: the coordinator survives the session end — a transfer
        // interrupted mid-flight waits (id + path intact) for the next
        // connect to this host and re-offers the same id.
        bulkCoordinator?.sessionEnded()
        bulkNegotiated = false
        chromaNoticeTask?.cancel()
        chromaNotice = nil
        linkHealth = nil
        // The sitting is over — the cumulative stall books go with
        // it. (Roam re-dials do NOT pass here; their recorder reset
        // only restarts the meter's window, never the totals.)
        linkHealthMeter.resetSessionBooks()
        statsVisible = false
        videoRendererHandoff?.stop()
        videoRendererHandoff = nil
        displayLayer.sampleBufferRenderer.flush()
        videoFlightRecorder.reset()
        videoDeliveryBooks.reset()
        videoInMeter.reset()
        lyteVideoSize = .zero
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

    /// The stall-cushion setting (Settings → Video): the playout's
    /// delay CEILING. The adaptive machinery still starts at ~20 ms
    /// and only grows on measured lateness, decaying slowly after —
    /// this knob decides how much it is ALLOWED to grow. 50 ms
    /// absorbs ordinary jitter; ~120 swallows a full Wi-Fi roam-scan
    /// deaf-window (the measured 75–115 ms class) at the cost of that
    /// much video delay while the link misbehaves. 0 disables the
    /// cushion entirely: the floor and starting delay collapse with
    /// the ceiling and frames present the moment they arrive. Read at
    /// session start; new connections pick up changes.
    static let playoutCushionKey = "playoutCushionMilliseconds"
    static let playoutCushionDefault = 50
    static let playoutCushionRange = 0...150

    private static func cushionMicrosecondsFromSettings() -> UInt64 {
        // 0 is a legal setting now, so "never set" must be the absent
        // key, not the integer default.
        let defaults = UserDefaults.standard
        let ms = defaults.object(forKey: playoutCushionKey) == nil
            ? playoutCushionDefault
            : min(max(defaults.integer(forKey: playoutCushionKey),
                      playoutCushionRange.lowerBound),
                  playoutCushionRange.upperBound)
        return UInt64(ms) * 1_000
    }

    private static func playoutConfigFromSettings()
        -> VideoBeatConductor.Config
    {
        // The slider is the cue's ceiling. The conductor needs at
        // least one beat to hold the grid; Config clamps below that.
        VideoBeatConductor.Config(
            maximumCueMicroseconds: cushionMicrosecondsFromSettings())
    }

    /// The 1 Hz link-health tick (driven by the stream container's
    /// task loop): fold the recorder's ring — the meter's high-water
    /// mark skips frames already folded — and publish the verdict.
    func tickLinkHealth() {
        // The cushion slider is live: the same 1 Hz heartbeat that
        // folds link health pushes ceiling changes into the playout.
        let cushion = Self.cushionMicrosecondsFromSettings()
        if cushion != appliedCushionMicroseconds {
            videoRendererHandoff?.updateCushionCeiling(
                microseconds: cushion)
            appliedCushionMicroseconds = cushion
        }
        for f in videoFlightRecorder.recentFrames() {
            linkHealthMeter.observe(
                ordinal: f.ordinal,
                transitStretchMilliseconds: f.transitStretchMilliseconds,
                queueWaitMilliseconds: f.queueWaitMilliseconds,
                enqueueMilliseconds: f.enqueueMilliseconds,
                frameSeconds: Double(f.hostMicroseconds) / 1_000_000)
        }
        linkHealth = linkHealthMeter.assessment()
    }

    func disconnect() {
        endSession(reason: nil)
    }

    // MARK: - Chroma tier (V-5)

    /// The strip/menu Chroma control's verb: persist the per-host
    /// preference and reconnect cleanly with the new declaration —
    /// chroma is connect-time only (overview §2's renegotiation row),
    /// so a flip IS a re-dial, never an in-session mutation. The
    /// dormant Better tier is refused here too (the control disables
    /// it; this is the model's own gate).
    func setChromaTier(_ tier: ChromaTier) {
        guard tier.isSelectable, tier != chromaTier else { return }
        chromaTier = tier
        if let pkh = hostPublicKeyHash {
            var store = PinnedHostStore.load()
            store.setChromaTier(publicKeyHash: pkh, tier: tier)
            try? store.save()
        }
        // Flip = clean reconnect (typed goodbye + immediate re-dial;
        // the F-5 machinery is the proven path).
        reconnectNow()
    }

    /// The typed negotiation failure's fate: `noCommonChromaMode` on
    /// a non-Good declaration auto-re-dials at Good with the banner
    /// (the pillar's named degradation — never silent, never a hang:
    /// V-4's host holds ≤2 s and fails typed); everything else stays
    /// the failure it is.
    private func handleCapabilitiesFailure(
        _ failure: CapabilityNegotiationError
    ) {
        let declared = chromaTier
        switch ChromaFallbackPolicy.verdict(
            declaredTier: declared, failure: failure
        ) {
        case .redialAtGood where roaming != nil:
            // Live downgrade only — the per-host preference stands
            // (the host may gain the tier; the user said Best).
            chromaTier = .good
            showChromaNotice(
                "\(hostName ?? "The host") doesn't offer "
                + "\(declared.displayName) (\(declared.samplingLabel)) "
                + "— reconnecting at Good (4:2:0)")
            reconnectNow()
        case .redialAtGood, .fail:
            endLyteSession(reason: "capabilities failed: \(failure)")
        }
    }

    /// The non-modal fallback banner; fades on its own (longer than
    /// the bulk notice — it explains a whole reconnect).
    private func showChromaNotice(_ text: String) {
        chromaNotice = text
        chromaNoticeTask?.cancel()
        chromaNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.chromaNotice = nil
        }
    }

    // MARK: - Roaming/reconnect (F-5)

    /// The Actions menu's Reconnect verb: tear the wire session down
    /// (typed goodbye — a host that can still hear one frees its side
    /// immediately) and act NOW — an immediate probe dial at the
    /// last-known address plus a discovery scan, ladders reset.
    func reconnectNow() {
        guard roaming != nil else { return }
        detachWireSession(goodbye: true)
        roamingInput { policy, now in policy.manualReconnect(now: now) }
    }

    private func startRoamingMachinery(
        publicKeyHash: String, address: String, port: UInt16
    ) {
        roaming = RoamingPolicy(
            targetPublicKeyHash: publicKeyHash,
            address: address, port: port)
        roamingStatus = .attached
        let watcher = NetworkPathWatcher()
        pathWatcher = watcher
        // The Mac hopped networks: HS-12 migration gets the policy's
        // grace to carry the session (the feedback cadence keeps
        // sending from the new source unprompted); the ladder runs
        // only if the path stays dark.
        watcher.start { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.roamingInput { policy, now in
                    policy.pathChanged(now: now)
                }
            }
        }
    }

    private func stopRoamingMachinery() {
        roamingTask?.cancel()
        roamingTask = nil
        roaming = nil
        roamingStatus = .attached
        pathWatcher?.stop()
        pathWatcher = nil
    }

    /// The 30 s liveness verdict: the peer is gone. Keep the window
    /// (the last frame + the roaming banner), keep everything
    /// per-host (coordinator, posture, consent), drop the wire
    /// session, hunt the identity.
    private func beginRoamingAfterLoss() {
        guard roaming != nil else {
            // No identity to hunt (shouldn't happen — the policy is
            // born with the session): the pre-F-5 posture.
            endLyteSession(reason: "host unreachable for 30 s")
            return
        }
        detachWireSession(goodbye: false)
        roamingInput { policy, now in policy.sessionClosed(now: now) }
    }

    /// Roaming-preserving teardown: the wire session goes away, the
    /// stream window and everything per-HOST stays for the re-dial —
    /// the live clipboard consent, the confirmed host-audio posture
    /// (the reconnect config re-asks for it), the input capture (its
    /// sends route through `lyteSession` live and simply drop while
    /// nil), and the bulk coordinator (the next `sessionReady`
    /// re-offers the same id — the F-4 resume path, which is exactly
    /// what makes a mid-transfer roam finish sha-exact).
    private func detachWireSession(goodbye: Bool) {
        guard let lyte = lyteSession else { return }
        lyteSession = nil
        sessionEpoch += 1
        videoRendererHandoff?.stop()
        videoRendererHandoff = nil
        displayLayer.sampleBufferRenderer.flush()
        videoFlightRecorder.reset()
        videoDeliveryBooks.reset()
        videoInMeter.reset()
        lyteFrozen = false
        hostAudioNegotiated = false
        audioStreamOffNegotiated = false
        pasteboardSync?.stop()
        pasteboardSync = nil
        clipboardNegotiated = false
        clipboardImagesNegotiated = false
        bulkCoordinator?.sessionEnded()
        bulkNegotiated = false
        Task.detached {
            if goodbye {
                lyte.close(reason: .shuttingDown)
            } else {
                lyte.stop()   // machine closed — nobody to say it to
            }
        }
    }

    /// One policy interaction: mutate under the injected wall clock,
    /// execute the actions, mirror the status, re-arm the deadline
    /// task. The single funnel for every roaming mutation.
    private func roamingInput(
        _ mutate: (inout RoamingPolicy, UInt64) -> [RoamingAction]
    ) {
        guard var policy = roaming else { return }
        let now = Self.monotonicMicroseconds()
        let actions = mutate(&policy, now)
        roaming = policy
        roamingStatus = policy.status
        for action in actions {
            switch action {
            case .beginScan:
                runRoamingScan()
            case .dial(let address, let port, let discovered):
                runRoamingDial(
                    address: address, port: port, discovered: discovered)
            }
        }
        armRoamingTask()
    }

    /// One standing task sleeps to the policy's next deadline and
    /// ticks — the StripRevealPolicy driving shape.
    private func armRoamingTask() {
        roamingTask?.cancel()
        roamingTask = nil
        guard let deadline = roaming?.nextDeadline else { return }
        roamingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let now = Self.monotonicMicroseconds()
                if now < deadline {
                    try? await Task.sleep(
                        nanoseconds: (deadline - now) * 1_000)
                    continue
                }
                break
            }
            guard !Task.isCancelled else { return }
            self?.roamingTask = nil
            self?.roamingInput { policy, now in policy.tick(now: now) }
        }
    }

    /// One quiet browse pass; the completion ALWAYS answers the
    /// policy (the beginScan/scanCompleted contract).
    private func runRoamingScan() {
        Task { @MainActor [weak self] in
            let hosts = await LyteDiscovery.browse(duration: 2.0)
            let sightings = hosts.compactMap { host -> RoamingSighting? in
                guard let pkh = host.publicKeyHash else { return nil }
                return RoamingSighting(
                    publicKeyHash: pkh,
                    address: host.address, port: host.port)
            }
            self?.roamingInput { policy, now in
                policy.scanCompleted(sightings: sightings, now: now)
            }
        }
    }

    /// One re-acquisition dial: fresh 1-RTT Noise IK against the SAME
    /// pinned static — same pairing, no re-PIN (the store keys by
    /// identity; the address is just where the identity lives now).
    /// A shorter retry window than the first connect (a host that
    /// hasn't freed the dead session answers with silence — the
    /// ladder retries, don't camp).
    private func runRoamingDial(
        address: String, port: UInt16, discovered: Bool
    ) {
        detachWireSession(goodbye: true)
        guard let pkh = hostPublicKeyHash,
              let pinned = PinnedHostStore.load().host(publicKeyHash: pkh),
              let hostStatic = pinned.staticPublicKey else {
            endLyteSession(
                reason: "\(hostName ?? "host") is no longer paired")
            return
        }
        let crypto: NoiseTransportCrypto
        do {
            // A roaming dial follows a successfully established session,
            // so the process cache must already hold the authenticated
            // identity. Never summon SecurityAgent from an automatic path.
            guard let identity =
                    ClientNoiseIdentityProvider.shared.cachedIdentity
            else {
                roamingInput { policy, now in policy.dialFailed(now: now) }
                return
            }
            crypto = try NoiseTransportCrypto(
                hostAddress: address,
                hostPort: port,
                hostStaticPublicKey: hostStatic,
                staticKeys: identity,
                attempts: 3,
                attemptTimeoutMilliseconds: 700)
        } catch {
            roamingInput { policy, now in policy.dialFailed(now: now) }
            return
        }
        // Restore the LIVE posture, not the per-host default: the
        // confirmed host-audio state rides the session-start ask, the
        // clipboard consent seeds the new core's gate directly.
        var config = LyteUdpSession.Config()
        config.core.desiredHostAudioRouting =
            hostAudioPosture ?? pinned.sessionStartHostAudioRouting
        config.core.shareClipboard = clipboardSharing
        config.core.shareClipboardImages = clipboardImageSharing
        // V-5: the LIVE tier rides every re-dial — a mid-session flip
        // and the chroma fallback both funnel through here with the
        // tier they mean.
        config.core.capabilities = config.core.capabilities
            .declaringChroma(tier: chromaTier)
        let lyte = makeLyteSession(crypto: crypto, config: config)
        Task { @MainActor [weak self] in
            do {
                try await Task.detached { try lyte.start() }.value
                self?.adoptReconnectedSession(
                    lyte, crypto: crypto, address: address, port: port)
            } catch {
                self?.roamingInput { policy, now in
                    policy.dialFailed(now: now)
                }
            }
        }
    }

    /// A re-dial became a session: swap it in without touching the
    /// per-host state, refresh the pinned dial hints (the host lives
    /// HERE now), and let the capability agreement drive the rest —
    /// the bulk coordinator's re-offer rides `.capabilitiesAgreed`
    /// exactly as a first connect does.
    private func adoptReconnectedSession(
        _ lyte: LyteUdpSession, crypto: NoiseTransportCrypto,
        address: String, port: UInt16
    ) {
        guard roaming != nil, case .streaming = phase else {
            // The human disconnected mid-dial: this session has no
            // owner — close it politely and walk away.
            Task.detached { lyte.close(reason: .shuttingDown) }
            return
        }
        lyteSession = lyte
        lyte.setAudioMuted(muted)
        lyteWireMode = .active
        lyteFrozen = false
        hostAddress = address
        hostAudioNegotiated = false
        audioStreamOffNegotiated = false
        // hostAudioPosture stays: the reconnect config already asked
        // for it; the host's first 0x19 refreshes the truth.
        clipboardNegotiated = false
        clipboardImagesNegotiated = false
        pasteboardSync = makePasteboardSync(for: lyte)
        bulkNegotiated = false
        statusLine = crypto.modeDescription
        // The dial hints follow the host (identity-keyed pin; the
        // refresh keeps pairedAt and every per-host preference).
        if let pkh = hostPublicKeyHash {
            var store = PinnedHostStore.load()
            if let pinned = store.host(publicKeyHash: pkh),
               let key = pinned.staticPublicKey {
                store.pin(
                    staticPublicKey: key, name: pinned.name,
                    address: address, port: port,
                    pairedAt: pinned.pairedAt)
                try? store.save()
            }
        }
        roamingInput { policy, now in
            policy.sessionEstablished(
                address: address, port: port, now: now)
        }
    }

    private static func monotonicMicroseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000
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

    /// The wire is currently carrying no audio track at all.
    var hostAudioOff: Bool { hostAudioPosture == .streamOff }

    /// Mute-at-source (postures design): off → 0x03, the whole track
    /// leaves the wire; on → back to the last confirmed STREAMING
    /// posture. Same contract as setHostMuted — the button renders
    /// the 0x19 answer, never the ask.
    func setHostAudioOff(_ off: Bool) {
        guard audioStreamOffNegotiated else { return }
        try? lyteSession?.requestHostAudioRouting(
            off ? .streamOff : lastStreamingAudioPosture)
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

    /// The images rung's live toggle (P-1). Only reachable when
    /// `clipboardImagesNegotiated`; images move only while text
    /// sharing is ALSO on — the tier, not a second channel.
    func setClipboardImageSharing(_ enabled: Bool) {
        guard clipboardImagesNegotiated else { return }
        clipboardImageSharing = enabled
        lyteSession?.setClipboardImageSharing(enabled)
        updatePasteboardWatcher()
    }

    /// The watcher polls exactly while consent AND capability hold —
    /// while off, the pasteboard is never even read. The images rung
    /// gates the watcher's IMAGE reads the same way (never read
    /// without consent), on top of the running/stopped state.
    private func updatePasteboardWatcher() {
        pasteboardSync?.setImagesEnabled(
            clipboardImagesNegotiated && clipboardImageSharing)
        if clipboardNegotiated, clipboardSharing, lyteSession != nil {
            pasteboardSync?.start()
        } else {
            pasteboardSync?.stop()
        }
    }

    /// One watcher per session, both flavors funneled into the core's
    /// judges (P-1 grew the image leg beside CL-15's text leg).
    private func makePasteboardSync(
        for lyte: LyteUdpSession
    ) -> PasteboardSync {
        let sync = PasteboardSync(onLocalChange: { [weak lyte] text in
            lyte?.shareLocalClipboard(text)
        })
        sync.onLocalImageChange = { [weak lyte] data in
            lyte?.shareLocalClipboardImage(data)
        }
        return sync
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

    /// The per-host images-rung default (P-1) — the third tier step.
    var shareClipboardImagesPreference: Bool {
        get {
            guard let pkh = hostPublicKeyHash else { return false }
            return PinnedHostStore.load()
                .host(publicKeyHash: pkh)?.shareClipboardImages == true
        }
        set {
            guard let pkh = hostPublicKeyHash else { return }
            var store = PinnedHostStore.load()
            store.setShareClipboardImages(
                publicKeyHash: pkh, share: newValue ? true : nil)
            try? store.save()
        }
    }

    // MARK: - Bulk transfer (F-4)

    /// True while a transfer (or its queue) is worth a pill.
    var bulkActive: Bool { !bulkStatus.isIdle }

    /// One coordinator per HOST: reconnects to the same host keep it
    /// (resume); a different host abandons everything first (a dropped
    /// file's consent was for that host, nobody else).
    private func prepareBulkCoordinator(hostKey: String) {
        if bulkCoordinatorHostKey == hostKey, bulkCoordinator != nil {
            return
        }
        bulkCoordinator?.abandonAll()
        bulkCoordinatorHostKey = hostKey
        bulkCoordinator = BulkSendCoordinator(
            onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.bulkStatus = self.bulkCoordinator?.snapshot() ?? .idle
                }
            },
            onNotice: { [weak self] notice in
                Task { @MainActor [weak self] in
                    self?.showBulkNotice(notice)
                }
            })
        bulkStatus = .idle
    }

    /// The stream view's drop handler: extract file URLs off the item
    /// providers (async), then judge. Returns whether the drag is
    /// worth accepting at all (any file-URL candidate while
    /// streaming); the capability verdict surfaces as a NOTICE after
    /// the drop — never a silent nothing (the F-4 gating rule).
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        let candidates = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !candidates.isEmpty, lyteSession != nil else { return false }
        Task { @MainActor [weak self] in
            var urls: [URL] = []
            for provider in candidates {
                if let url = await Self.loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            self?.dropFiles(urls)
        }
        return true
    }

    /// The gating verdicts, spoken (multi-file drops queue and send
    /// serially — the coordinator's documented v1 policy).
    func dropFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let coordinator = bulkCoordinator else { return }
        switch coordinator.drop(urls: urls) {
        case .accepted:
            break   // the pill takes over
        case .hostNotAccepting:
            showBulkNotice(
                "\(hostName ?? "The host") isn't accepting files — "
                + "enable file drops on the host")
        case .notConnected:
            showBulkNotice("Not connected — file not sent")
        }
    }

    /// The pill's × and the Actions menu item: cancel the active
    /// transfer AND the queue (cancel means stop sending).
    func cancelBulkTransfers() {
        bulkCoordinator?.cancelAll()
    }

    /// Transient verdict line under the pill; fades after a beat.
    private func showBulkNotice(_ text: String) {
        bulkNotice = text
        bulkNoticeTask?.cancel()
        bulkNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.bulkNotice = nil
        }
    }

    private static func loadFileURL(
        from provider: NSItemProvider
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    // MARK: - Window verbs (strip + Actions menu, same commands)

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    // MARK: - The stats readout (CL-13)

    /// 1_734_567 → "1.73M"; 41_200 → "41.2k"; small counts stay exact.
    /// Only ever used for denominators — deficits always print exact.
    private static func compactCount(_ n: UInt64) -> String {
        switch n {
        case ..<10_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1e3)
        default: return String(format: "%.2fM", Double(n) / 1e6)
        }
    }

    /// A compact snapshot of the session's existing books — the same
    /// counters wire-view prints, shaped for the overlay. Re-read on
    /// every call; the overlay's TimelineView drives the cadence.
    struct StatsRow: Identifiable {
        var label: String
        var value: String
        var id: String { label }
    }

    func statsRows() -> [StatsRow] {
        guard let session = lyteSession,
              let endpoint = session.endpoint,
              let core = session.core else { return [] }
        var rows: [StatsRow] = []
        func row(_ label: String, _ value: String) {
            rows.append(StatsRow(label: label, value: value))
        }

        // Row order (owner-shaped, 2026-07-30): mode heads the block,
        // net under it, then audio and video ADJACENT (the two media
        // rows read together), input last. Conditional rows follow.
        //
        // The net line: loss deficit-first (a success-count brags; the
        // deficit is the signal, and a percent must never round a real
        // loss into looking clean), then the clock model's honest RTT.
        let totals = endpoint.demux.snapshotTotals()
        let perChannel = endpoint.demux.snapshotChannels()
        let missing = perChannel.reduce(UInt64(0)) { $0 + $1.stats.seqMissing }
        let lateFilled = perChannel.reduce(UInt64(0)) { $0 + $1.stats.seqLateFilled }
        let lost = missing > lateFilled ? missing - lateFilled : 0
        let expected = totals.datagrams + lost
        var wire = lost == 0
            ? "lost 0 of \(Self.compactCount(expected)) host packets"
            : String(format: "lost %d of %@ host packets (%.3f%%)",
                     lost, Self.compactCount(expected),
                     100 * Double(lost) / Double(max(1, expected)))
        // roundtrip min + jitter, spelled out — "±" falsely implies a
        // symmetric spread; the stat is the floor plus upward spread
        // (p90 − min), which is what "jitter" means to every reader.
        // Window: last 10 beacons ≈ 10 s — beacons tick at 1 Hz, so
        // this is as close to the owner's 2–3 s gauge ruling as the
        // cadence allows without starving the p90 of samples.
        let rtts = core.echoResponder.snapshotClockSamples()
            .suffix(10).map(\.rttMicroseconds).sorted()
        if let minRtt = rtts.first {
            let p90 = rtts[min(rtts.count - 1, (rtts.count * 9) / 10)]
            wire += String(
                format: " · roundtrip min %.1f ms · jitter %.1f ms",
                Double(minRtt) / 1000,
                Double(p90 - minRtt) / 1000)
        }
        if totals.unsealFailures > 0 {
            wire += ", \(totals.unsealFailures) unseal-failed"
        }
        // Caps-as-alarm (owner grammar, 2026-07-30): nominal states are
        // lowercase so a HEALTHY overlay contains zero uppercase — the
        // glance-test is "any caps anywhere?". FROZEN and NOT CAPTURED
        // are the only words allowed to shout.
        var mode = core.wireMode == .active ? "active" : "idle"
        if core.isFrozen { mode += " — FROZEN" }
        // Chroma lives HERE (owner catch, round three): it is fixed at
        // ANNOUNCE — changing tiers means a reconnect — so it is a
        // session state like the postures beside it, not a live
        // metric. The codec rides with it (same announce-time truth —
        // the YouTube-panel steal, 2026-08-03).
        if let chroma = core.streamChromaDescription {
            mode += " · hevc \(chroma)"
        }
        if hostAudioNegotiated {
            switch hostAudioPosture {
            case .hostMuted: mode += " · host audio muted"
            case .hostAudible: mode += " · host audio audible"
            case .streamOff: mode += " · audio stream off"
            case nil: mode += " · host audio pending"
            }
        }
        if clipboardNegotiated {
            mode += clipboardSharing
                ? " · clipboard shared" : " · clipboard private"
        }
        // Capture is a session STATE (who owns the keyboard/mouse now),
        // so it lives here with its siblings, not on the input line.
        mode += lyteInputCapture != nil
            ? " · keys+mouse captured" : " · keys+mouse NOT CAPTURED"
        // The radio watchdog's verdict, caps-alarm grammar: appears
        // ONLY when streams are live, awdl0 stayed up through a
        // re-engage, and jitter is therefore about to say why.
        if AgentState.shared.radioAlarm { mode += " · AWDL LOOSE" }
        row("session", mode)

        // Unconditional (CL-16): "user: 0 events sent to host" is
        // the datum that tells a client-capture failure from a
        // host-side one. (The transport line keeps its ruled prefix;
        // the ledger strips it into the label column.)
        let userLine = core.input.snapshotStats().overlayLine()
        row("user", userLine.hasPrefix("user:")
            ? String(userLine.dropFirst(5))
                .trimmingCharacters(in: .whitespaces)
            : userLine)

        // Owner order: outbound then inbound — the directions read as
        // a pair — then the inbound media lines they frame.
        row("network", wire)

        let audio = core.audio.snapshotStats()
        if audio.depacketizer.datagramsIngested > 0 {
            var parts: [String] = []
            // Buffer depth in ms, not packets (exact: 5 ms hard-CBR
            // packets) — "15/40 ms of cushion" needs no decoder ring.
            let depth = audio.bufferDepthPackets.percentiles([0.50, 0.99])
            if let p50 = depth[0], let p99 = depth[1] {
                parts.append("buffer p50/p99 \(p50 * 5)/\(p99 * 5) ms")
            }
            // Each concealment papered over one missing-audio gap — a
            // potential tiny audible artifact; the count IS the story.
            parts.append("gaps concealed \(audio.jitter.plcInvocations)")
            if audio.depacketizer.packetsRebuilt > 0 {
                parts.append("repaired \(audio.depacketizer.packetsRebuilt)")
            }
            row("audio", parts.joined(separator: " · "))
        }

        // The HS-22 quality line — what the receive side can say about
        // incoming video from its own books (frame cadence, bitrate,
        // frame-size percentiles over ~5 s). Host QP/encoder posture
        // are host-log truth; this is the client-side half.
        let nowMicroseconds = DispatchTime.now().uptimeNanoseconds / 1000
        let delivery = videoDeliveryBooks.snapshot(
            nowMicroseconds: nowMicroseconds)
        let pipelineStats = core.pipeline.snapshotStats()
        if let q = pipelineStats.quality {
            // in = frames fully assembled off the wire (reorder/FEC
            // healed); out = frames handed to the renderer. The
            // slash-pair is honest because BOTH ride the same 3 s
            // meter window (RateMeter) — a widening split is a
            // glass-side stall, not a network one. Mbps leads and
            // stands bare (self-naming); chroma moved to the stream
            // line (session state, not live metric).
            var video = String(format: "%.1f Mbps",
                               Double(q.bitsPerSecond) / 1e6)
            let inFps = videoInMeter.rate(
                count: pipelineStats.framesDecoded,
                nowMicroseconds: nowMicroseconds)
            switch (inFps, delivery.outFps) {
            case (let inRate?, let out?):
                video += String(format: " · in/out %.0f/%.0f fps",
                                inRate, out)
            case (let inRate?, nil):
                video += String(format: " · in %.0f fps", inRate)
            default:
                break
            }
            video += String(
                format: " · size p50/p95 %d/%d B",
                q.frameBytesP50, q.frameBytesP95)
            // The delivery hop (dispatch → renderer accepted, queue
            // wait included): the resize-storm stall detector.
            if let p50 = delivery.hopP50, let p99 = delivery.hopP99 {
                video += String(
                    format: " · deliver p50/p99 %.1f/%.1f ms", p50, p99)
            }
            row("video", video)
        }
        let flight = videoFlightRecorder.snapshot()
        if flight.frames > 0 {
            var glass = String(
                format: "source/ready p99 %.1f/%.1f ms"
                    + " · transit %.1f ms · sample %.1f ms"
                    + " · queue/enqueue %.1f/%.1f ms",
                flight.sourceGapP99Milliseconds ?? 0,
                flight.readyGapP99Milliseconds ?? 0,
                flight.transitStretchP99Milliseconds ?? 0,
                Double(pipelineStats.sampleBuildMicroseconds.p99 ?? 0) / 1_000,
                flight.queueWaitP99Milliseconds ?? 0,
                flight.enqueueP99Milliseconds ?? 0)
            if let renderer = flight.rendererMetrics {
                glass += " · render \(renderer.totalFrames)"
                    + " drop \(renderer.droppedFrames)"
                    + " corrupt \(renderer.corruptedFrames)"
                glass += String(
                    format: " delay %.1f ms",
                    renderer.accumulatedDelayMilliseconds)
            }
            // The conductor's standing cushion — YouTube's "buffer
            // health" steal, in the grid's own beats-to-glass terms.
            if let cushion = flight.targetDelayMilliseconds {
                glass += String(format: " · cushion %.0f ms", cushion)
            }
            glass += " · \(flight.bottleneck)"
            row("glass", glass)
        }

        let clipboard = core.snapshotCounters()
        let clipboardActivity = clipboard.clipboardSharesSent
            + clipboard.clipboardAnnouncesReceived
            + clipboard.clipboardLoopSuppressed
        if clipboardNegotiated, clipboardActivity > 0 {
            row("clipboard", "\(clipboard.clipboardSharesSent) sent"
                + " · \(clipboard.clipboardAnnouncesReceived) recv"
                + " · \(clipboard.clipboardLoopSuppressed) suppressed")
        }

        // P-1: the image lane's books, while it has any.
        let images = core.clipboardImageCounters
        let imageActivity = images.sharesStarted + images.imagesApplied
            + images.sharesSuppressed + images.receivesRefused
        if clipboardImagesNegotiated, imageActivity > 0 {
            row("clip images", "\(images.sharesCompleted)"
                + "/\(images.sharesStarted) sent"
                + " · \(images.imagesApplied) applied"
                + " · \(images.sharesSuppressed) suppressed")
        }

        // F-4: the bulk channel's books, while it has any.
        if clipboard.bulkMessagesSent + clipboard.bulkMessagesReceived > 0 {
            var line = "\(clipboard.bulkMessagesSent) sent"
                + " · \(clipboard.bulkMessagesReceived) recv"
            if let progress = bulkStatus.progress,
               progress.totalByteCount > 0 {
                line += String(format: " · %.0f%%", progress.fraction * 100)
            }
            row("bulk", line)
        }
        return rows
    }

    func diagnosticBenchmarkSample(
        runID: String,
        workload: String,
        elapsedSeconds: Double,
        afterOrdinal: UInt64
    ) -> DiagnosticBenchmarkSample {
        let session = lyteSession
        let core = session?.core
        let pipeline = core?.pipeline.snapshotStats()
        let idr = core?.idrRequester.snapshotStats()
        let receiver = core?.audio.snapshotStats()
        let player = session?.audioPlayer?.snapshotStats()
        let counters = core?.snapshotCounters()
        let phaseName: String
        switch phase {
        case .pickHost: phaseName = "pickHost"
        case .connecting: phaseName = "connecting"
        case .streaming: phaseName = "streaming"
        case .failed: phaseName = "failed"
        }
        return DiagnosticBenchmarkSample(
            runID: runID,
            workload: workload,
            elapsedSeconds: elapsedSeconds,
            phase: phaseName,
            flight: videoFlightRecorder.snapshot(),
            frames: videoFlightRecorder.recentFrames().filter {
                $0.ordinal > afterOrdinal
            },
            video: .init(
                framesDecoded: pipeline?.framesDecoded ?? 0,
                framesSkipped: pipeline?.framesSkipped ?? 0,
                samplesDelivered: pipeline?.samplesDelivered ?? 0,
                samplesWithheld: pipeline?.samplesWithheld ?? 0,
                sampleFailures: pipeline?.sampleFailures ?? 0,
                idrVerdicts: idr?.verdicts ?? 0,
                idrRequests: idr?.requestsSent ?? 0,
                idrRetries: idr?.retryRequests ?? 0),
            audio: .init(
                datagramsReceived: counters?.audioDatagramsReceived ?? 0,
                packetsEmitted: receiver?.depacketizer.packetsEmitted ?? 0,
                packetsRebuilt: receiver?.depacketizer.packetsRebuilt ?? 0,
                packetsUnrecoverable:
                    receiver?.depacketizer.packetsUnrecoverable ?? 0,
                packetsPlayed: receiver?.jitter.packetsPlayed ?? 0,
                plcInvocations: receiver?.jitter.plcInvocations ?? 0,
                latePacketsDropped: receiver?.jitter.latePacketsDropped ?? 0,
                recenterEvents: receiver?.jitter.recenterEvents ?? 0,
                packetsDroppedInRecenter:
                    receiver?.jitter.packetsDroppedInRecenter ?? 0,
                starvedVerdicts: receiver?.jitter.starvedVerdicts ?? 0,
                targetPackets: receiver?.jitter.targetPackets ?? 0,
                interArrivalStdDevMicroseconds:
                    receiver?.jitter.interArrivalStdDevMicroseconds ?? 0,
                playerAvailable: player != nil,
                packetsFed: player?.packetsFed ?? 0,
                plcPacketsFed: player?.plcPacketsFed ?? 0,
                ringDepthFrames: player?.ringDepthFrames ?? 0,
                underrunFrames: player?.underrunFrames ?? 0,
                declickProtectedUnderrunFrames:
                    player?.underrunFrames ?? 0,
                decodeFailures: player?.decodeFailures ?? 0,
                routeChangeFailures: player?.routeChangeFailures ?? 0,
                hostAnnouncedQuiet: core?.hostAnnouncedAudioQuiet ?? false),
            streamChroma: core?.streamChromaDescription)
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

/// Serial, bounded ownership of compressed samples between the sample-build
/// worker and AVFoundation. `isReadyForMoreMediaData == false` queues the
/// complete dependency chain; pressure discards the whole episode, flushes,
/// and enters await-IDR instead of dropping an arbitrary P-frame.
private final class VideoRendererHandoff: @unchecked Sendable {
    private struct Pending: @unchecked Sendable {
        var sample: CMSampleBuffer
        var unit: DecodeUnit
        var dispatchedNanoseconds: UInt64
        var token: VideoFlightRecorder.Token
        var build: VideoFrameBuildTelemetry?
        var decision: VideoBeatConductor.Decision
        var encounteredRendererBackpressure: Bool
    }

    private let renderer: AVSampleBufferVideoRenderer
    private let queue: DispatchQueue
    private let clockModel: HostClockModel
    private let playout: VideoBeatConductorController
    private let books: VideoDeliveryBooks
    private let recorder: VideoFlightRecorder
    private let recoveryRequester: VideoRecoveryRequester
    private var policy = BoundedRendererHandoff<Pending>()
    private var requesting = false
    private var stopped = false
    private var recoveryEpisode: UInt64 = 0
    private var activeRecoveryEpisode: UInt64?
    private var forcedMetricsProbes = 0
    private var flushBarrier = RendererRecoveryFlushBarrier()

    init(
        renderer: AVSampleBufferVideoRenderer,
        queue: DispatchQueue,
        clockModel: HostClockModel,
        books: VideoDeliveryBooks,
        recorder: VideoFlightRecorder,
        recoveryRequester: VideoRecoveryRequester,
        playoutConfig: VideoBeatConductor.Config = .init()
    ) {
        self.renderer = renderer
        self.queue = queue
        self.clockModel = clockModel
        self.books = books
        self.recorder = recorder
        self.recoveryRequester = recoveryRequester
        self.playout = VideoBeatConductorController(
            config: playoutConfig)
    }

    /// The Settings slider is live — the model's 1 Hz tick pushes
    /// ceiling changes here mid-stream.
    func updateCushionCeiling(microseconds: UInt64) {
        playout.updateCueCeiling(
            maximumCueMicroseconds: microseconds)
    }

    func submit(sample: CMSampleBuffer, unit: DecodeUnit) {
        nonisolated(unsafe) let transferred = sample
        let dispatched = DispatchTime.now().uptimeNanoseconds
        let arrival = dispatched / 1_000
        let mapped = clockModel.map(unit.timestamp)?.microseconds ?? arrival
        let decision = playout.schedule(
            mappedCaptureMicroseconds: mapped,
            arrivalMicroseconds: arrival,
            sourceCaptureMicroseconds: unit.timestamp.microseconds,
            isRandomAccess: unit.isIDR)
        PipelineWitness.record("frameReady", fields: [
            "frame": String(unit.frameNumber.rawValue),
            "captureMicroseconds": String(unit.timestamp.microseconds),
            "mappedCaptureMicroseconds": String(mapped),
            "readyMonotonicNanoseconds": String(dispatched),
            "scheduledPresentationMicroseconds": String(
                decision.presentationMicroseconds),
            "targetDelayMicroseconds": String(
                decision.targetDelayMicroseconds),
            "latenessMicroseconds": String(decision.latenessMicroseconds),
        ])
        let pending = Pending(
            sample: transferred,
            unit: unit,
            dispatchedNanoseconds: dispatched,
            token: recorder.frameReady(
                frame: unit.frameNumber.rawValue,
                hostMicroseconds: unit.timestamp.microseconds,
                nowNanoseconds: dispatched),
            build: VideoSampleTiming.buildTelemetry(from: sample),
            decision: decision,
            encounteredRendererBackpressure: false)
        queue.async { [weak self] in
            self?.accept(pending)
        }
    }

    func beginRecovery(cause: VideoRecoveryCause, after frame: FrameNumber) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let awaiting = self.policy.awaitingRandomAccess
            let irapPending = self.policy.randomAccessPending
            self.recorder.recordRecoveryLifecycle(
                kind: awaiting
                    ? "handoffDamageOverlap" : "handoffDamageReceived",
                frame: frame.rawValue,
                cause: cause,
                episode: self.activeRecoveryEpisode,
                awaitingRandomAccess: awaiting,
                randomAccessPending: irapPending,
                pendingCount: self.policy.count)
            self.process(
                self.policy.failEpisode(),
                recoveryFrame: frame,
                cause: cause,
                requestRecovery: false)
        }
    }

    func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            flushBarrier.reset()
            renderer.stopRequestingMediaData()
            requesting = false
            let discarded = policy.reset()
            for entry in discarded {
                finish(entry.element, dropped: true, recovery: false)
            }
        }
    }

    private func accept(_ incoming: Pending) {
        var pending = incoming
        pending.encounteredRendererBackpressure =
            !renderer.isReadyForMoreMediaData
        guard !stopped else {
            finish(pending, dropped: true, recovery: false)
            return
        }

        if pending.decision.shouldFlush || renderer.status == .failed {
            let cause: VideoRecoveryCause = pending.decision.shouldFlush
                ? .freshPresentationDebt : .rendererFailure
            recorder.recordRecoveryLifecycle(
                kind: "handoffLocalDamage",
                frame: pending.unit.frameNumber.rawValue,
                cause: cause,
                episode: activeRecoveryEpisode,
                isRandomAccess: pending.unit.isIDR,
                awaitingRandomAccess: policy.awaitingRandomAccess,
                randomAccessPending: policy.randomAccessPending,
                pendingCount: policy.count)
            process(
                policy.failEpisode(),
                recoveryFrame: pending.unit.frameNumber,
                cause: cause)
        }

        let now = DispatchTime.now().uptimeNanoseconds / 1_000
        let outcome = policy.offer(
            pending,
            isRandomAccess: pending.unit.isIDR,
            nowMicroseconds: now)
        process(
            outcome,
            recoveryFrame: pending.unit.frameNumber,
            cause: .rendererBackpressure)
        if pending.unit.isIDR {
            recorder.recordRecoveryLifecycle(
                kind: outcome.accepted
                    ? "handoffIrapAcceptedPendingEnqueue"
                    : "handoffIrapRejected",
                frame: pending.unit.frameNumber.rawValue,
                episode: activeRecoveryEpisode,
                isRandomAccess: true,
                awaitingRandomAccess: policy.awaitingRandomAccess,
                randomAccessPending: policy.randomAccessPending,
                pendingCount: policy.count)
        } else if !outcome.accepted, policy.awaitingRandomAccess {
            recorder.recordRecoveryLifecycle(
                kind: "handoffRejectedNonIrap",
                frame: pending.unit.frameNumber.rawValue,
                episode: activeRecoveryEpisode,
                isRandomAccess: false,
                awaitingRandomAccess: true,
                randomAccessPending: policy.randomAccessPending,
                pendingCount: policy.count)
        } else if outcome.accepted, policy.awaitingRandomAccess {
            recorder.recordRecoveryLifecycle(
                kind: "invariantViolationNonIrapAcceptedDuringRecovery",
                frame: pending.unit.frameNumber.rawValue,
                episode: activeRecoveryEpisode,
                isRandomAccess: false,
                awaitingRandomAccess: true,
                randomAccessPending: policy.randomAccessPending,
                pendingCount: policy.count)
        }
        if outcome.accepted {
            armRenderer()
            let deadline = policy.config.deadlineMicroseconds
            queue.asyncAfter(deadline: .now() + .microseconds(Int(deadline))) {
                [weak self] in
                self?.expire()
            }
        }
    }

    private func armRenderer() {
        guard flushBarrier.mayEnqueue,
              !requesting,
              policy.count > 0 else { return }
        requesting = true
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.drainReady()
        }
    }

    private func drainReady() {
        guard !stopped, flushBarrier.mayEnqueue else { return }
        if renderer.status == .failed {
            process(
                policy.failEpisode(),
                recoveryFrame: FrameNumber(rawValue: 0),
                cause: .rendererFailure)
            return
        }
        while renderer.isReadyForMoreMediaData,
              let entry = policy.popReady() {
            let pending = entry.element
            let closesRecovery =
                policy.awaitingRandomAccess
                && policy.randomAccessPending
                && pending.unit.isIDR
            let started = DispatchTime.now().uptimeNanoseconds
            guard let timed = VideoSampleTiming.retimed(
                pending.sample,
                presentationMicroseconds:
                    pending.decision.presentationMicroseconds
            ) else {
                var failure = policy.failEpisode()
                failure.discarded.insert(entry, at: 0)
                process(
                    failure,
                    recoveryFrame: pending.unit.frameNumber,
                    cause: .rendererFailure)
                return
            }
            if closesRecovery {
                // `flush()` discards queued samples, but CoreMedia requires
                // this attachment to reset the compressed decoder itself.
                // Without it, live metrics count every frame after a
                // debt-triggered flush as corrupted until another reset.
                CMSetAttachment(
                    timed,
                    key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                    value: kCFBooleanTrue,
                    attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
            }
            let resetAttached = CMGetAttachment(
                timed,
                key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
                attachmentModeOut: nil) != nil
            if pending.unit.isIDR
                || activeRecoveryEpisode != nil
                || forcedMetricsProbes > 0 {
                recorder.recordRecoveryLifecycle(
                    kind: pending.unit.isIDR
                        ? "rendererEnqueueIrap" : "rendererEnqueueNonIrap",
                    frame: pending.unit.frameNumber.rawValue,
                    episode: activeRecoveryEpisode,
                    isRandomAccess: pending.unit.isIDR,
                    resetDecoderBeforeDecoding: resetAttached,
                    awaitingRandomAccess: policy.awaitingRandomAccess,
                    randomAccessPending: policy.randomAccessPending,
                    pendingCount: policy.count)
            }
            PipelineWitness.record("rendererEnqueueBegin", fields: [
                "frame": String(pending.unit.frameNumber.rawValue),
                "scheduledPresentationMicroseconds": String(
                    pending.decision.presentationMicroseconds),
            ])
            renderer.enqueue(timed)
            PipelineWitness.record("rendererEnqueueCompleted", fields: [
                "frame": String(pending.unit.frameNumber.rawValue),
            ])
            if pending.unit.isIDR {
                policy.noteRandomAccessEnqueued()
                playout.noteRandomAccessEnqueued()
                recoveryRequester.noteIrapEnqueued(
                    frame: pending.unit.frameNumber)
                if closesRecovery {
                    forcedMetricsProbes = 3
                    recorder.recordRecoveryLifecycle(
                        kind: "handoffRecoveryClosed",
                        frame: pending.unit.frameNumber.rawValue,
                        episode: activeRecoveryEpisode,
                        isRandomAccess: true,
                        resetDecoderBeforeDecoding: resetAttached,
                        awaitingRandomAccess: policy.awaitingRandomAccess,
                        randomAccessPending: policy.randomAccessPending,
                        pendingCount: policy.count)
                    activeRecoveryEpisode = nil
                }
            }
            finish(
                pending,
                enqueueStarted: started,
                enqueueFinished: DispatchTime.now().uptimeNanoseconds,
                rendererReady:
                    !pending.encounteredRendererBackpressure,
                rendererFailed: false,
                dropped: false,
                recovery: false)
        }
        if policy.count == 0 {
            renderer.stopRequestingMediaData()
            requesting = false
        }
    }

    private func expire() {
        guard !stopped else { return }
        let outcome = policy.expire(
            nowMicroseconds: DispatchTime.now().uptimeNanoseconds / 1_000)
        process(
            outcome,
            recoveryFrame: FrameNumber(rawValue: 0),
            cause: .rendererBackpressure)
    }

    private func process(
        _ outcome: BoundedRendererHandoff<Pending>.Outcome,
        recoveryFrame: FrameNumber,
        cause: VideoRecoveryCause,
        requestRecovery: Bool = true
    ) {
        if outcome.recoveryRequested {
            recoveryEpisode &+= 1
            activeRecoveryEpisode = recoveryEpisode
            renderer.stopRequestingMediaData()
            requesting = false
            let startedFlush = flushBarrier.begin()
            recorder.recordRecoveryCause(cause)
            recorder.recordRecoveryLifecycle(
                kind: startedFlush
                    ? "rendererRecoveryFlushStarted"
                    : "rendererRecoveryFlushAlreadyPending",
                frame: recoveryFrame.rawValue,
                cause: cause,
                episode: activeRecoveryEpisode,
                awaitingRandomAccess: policy.awaitingRandomAccess,
                randomAccessPending: policy.randomAccessPending,
                pendingCount: policy.count)
            if startedFlush {
                renderer.flush(removingDisplayedImage: false) {
                    [weak self] in
                    self?.queue.async { [weak self] in
                        guard let self, !self.stopped else { return }
                        self.flushBarrier.complete()
                        self.recorder.recordRecoveryLifecycle(
                            kind: "rendererRecoveryFlushCompleted",
                            frame: recoveryFrame.rawValue,
                            cause: cause,
                            episode: self.activeRecoveryEpisode,
                            awaitingRandomAccess:
                                self.policy.awaitingRandomAccess,
                            randomAccessPending:
                                self.policy.randomAccessPending,
                            pendingCount: self.policy.count)
                        self.armRenderer()
                    }
                }
            }
            if requestRecovery {
                recoveryRequester.request(
                    after: outcome.discarded.last?.element.unit.frameNumber
                        ?? recoveryFrame,
                    cause: cause)
            }
            if outcome.discarded.isEmpty {
                recorder.recordRendererRecovery()
            }
        }
        for (index, entry) in outcome.discarded.enumerated() {
            finish(
                entry.element,
                rendererReady: renderer.isReadyForMoreMediaData,
                rendererFailed: renderer.status == .failed,
                dropped: true,
                recovery: outcome.recoveryRequested && index == 0)
        }
    }

    private func finish(
        _ pending: Pending,
        enqueueStarted: UInt64? = nil,
        enqueueFinished: UInt64? = nil,
        rendererReady: Bool = false,
        rendererFailed: Bool = false,
        dropped: Bool,
        recovery: Bool
    ) {
        let started = enqueueStarted ?? DispatchTime.now().uptimeNanoseconds
        let finished = enqueueFinished ?? started
        books.record(
            hopMilliseconds:
                Double(finished &- pending.dispatchedNanoseconds) / 1e6)
        recorder.frameEnqueued(
            pending.token,
            enqueueStartedNanoseconds: started,
            enqueueFinishedNanoseconds: finished,
            rendererReady: rendererReady,
            rendererFailed: rendererFailed,
            rendererDropped: dropped,
            sampleBuildMicroseconds:
                pending.build?.sampleBuildMicroseconds,
            assemblyLockHoldMicroseconds:
                pending.build?.assemblyLockHoldMicroseconds,
            scheduledPresentationMicroseconds:
                pending.decision.presentationMicroseconds,
            targetDelayMicroseconds:
                pending.decision.targetDelayMicroseconds,
            presentationLatenessMicroseconds:
                pending.decision.latenessMicroseconds,
            rendererRecovery: recovery)
        sampleMetricsIfDue(
            after: pending.token,
            frame: pending.unit.frameNumber.rawValue,
            isRandomAccess: pending.unit.isIDR)
    }

    private func sampleMetricsIfDue(
        after token: VideoFlightRecorder.Token,
        frame: UInt32,
        isRandomAccess: Bool
    ) {
        let forced = forcedMetricsProbes > 0
        if forced { forcedMetricsProbes -= 1 }
        guard forced || recorder.shouldSampleRenderer(after: token) else {
            return
        }
        renderer.loadVideoPerformanceMetrics { [recorder] metrics in
            if let metrics {
                recorder.recordRendererMetrics(.init(
                    totalFrames: metrics.totalNumberOfFrames,
                    droppedFrames: metrics.numberOfDroppedFrames,
                    corruptedFrames: metrics.numberOfCorruptedFrames,
                    accumulatedDelayMilliseconds:
                        metrics.totalAccumulatedFrameDelay * 1_000),
                    sampledAfterFrame: frame,
                    sampledAfterIsRandomAccess: isRandomAccess)
            }
            if let json = try? recorder.summaryJSONLine() {
                NSLog("lyte video flight: %@", json)
            }
        }
    }
}

private final class VideoRecoveryRequester: @unchecked Sendable {
    private let lock = NSLock()
    private weak var session: LyteUdpSession?

    func bind(_ session: LyteUdpSession) {
        lock.lock(); self.session = session; lock.unlock()
    }

    func request(after frame: FrameNumber, cause: VideoRecoveryCause) {
        lock.lock()
        let session = session
        lock.unlock()
        session?.requestVideoRecovery(after: frame, cause: cause)
    }

    func noteIrapEnqueued(frame: FrameNumber) {
        lock.lock()
        let session = session
        lock.unlock()
        session?.noteVideoIrapEnqueued(frame: frame)
    }
}
