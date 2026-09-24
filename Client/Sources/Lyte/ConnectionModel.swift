import LyteIO
import LyteCore
import LyteClientCore
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
    enum Failure {
        case ordinary(String)
        case localNetwork(
            LocalNetworkAccessProblem,
            diagnosticDetail: String
        )

        var diagnosticDescription: String {
            switch self {
            case .ordinary(let message):
                return message
            case .localNetwork(let problem, let detail):
                return "localNetwork(\(problem)): \(detail)"
            }
        }
    }

    enum Phase {
        case pickHost
        case connecting(String)
        case streaming
        case failed(Failure)
    }

    var phase: Phase = .pickHost

    private let services: ConnectionServices

    init(services: ConnectionServices = .live) {
        self.services = services
    }

    /// Fresh-connect patience (the respawn-gap hunt in connectLyte):
    /// silence keeps re-dialing until this budget runs out. Sized to
    /// cover a full host restart and hardware initialization
    /// (10–15 s observed) with margin, not to camp forever.
    static let freshConnectBudgetMicroseconds: UInt64 = 45_000_000
    /// Advances on every lifecycle edge — a connect begins, the human
    /// disconnects, roaming starts or stops. Asynchronous work (identity
    /// lookups, dials, browses) captures it at launch and, when it no
    /// longer matches on completion, drops its result and closes any
    /// session it made: late results never reach a window that moved on.
    private var lifecycleGeneration: UInt64 = 0

    @discardableResult
    private func advanceLifecycle() -> UInt64 {
        lifecycleGeneration &+= 1
        return lifecycleGeneration
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == lifecycleGeneration
    }
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
    /// Shared by every session's handoff, so a retiring handoff's reset
    /// and renderer flush are ordered before its successor's first sample.
    private let videoDeliveryQueue = DispatchQueue(
        label: "lyte.video.delivery", qos: .userInteractive)
    private let videoDeliveryBooks = VideoDeliveryBooks()
    /// Actual-app flight recorder: source cadence, receive cadence,
    /// delivery queue, renderer enqueue, and Apple's decode/display books.
    /// Bounded to six seconds at 60 fps and always on — visual failures
    /// cannot depend on the stats overlay being open.
    private let videoFlightRecorder = VideoFlightRecorder(
        nowMicroseconds: { SystemMonotonicClock.nowMicroseconds })
    /// The link-health fold over the recorder's ring (already-measured
    /// per-frame stage timings → one user-facing verdict). Ticked at
    /// 1 Hz from the stream container; the meter's ordinal high-water
    /// mark makes overlapping scans idempotent, and a recorder reset
    /// (ordinals restart) clears it implicitly.
    private let linkHealthMeter = LinkHealthMeter()
    /// nil until streaming produces a verdict; .good renders nothing —
    /// a clean link needs no announcement.
    private(set) var linkHealth: LinkHealthAssessment?
    /// in-fps over the same ~1 s window shape as the delivery books'
    /// out-fps, so the overlay's in/out slash-pair compares honestly.
    private var videoInMeter = RateMeter()
    private var videoRendererHandoff: VideoRendererHandoff?

    // F-5: roaming/reconnect. The policy exists for the whole
    // streaming life of a window (it IS the "can this window
    // reconnect" verdict); its status drives the stream overlay's
    // banner. `sessionEpoch` fences late EVENTS from detached
    // sessions (a .closed racing the teardown, mostly);
    // `lifecycleGeneration` fences late dial and browse RESULTS.
    private var roaming: RoamingPolicy?
    private var roamingTask: Task<Void, Never>?
    private(set) var roamingStatus: RoamingStatus = .attached
    private var stopPathWatch: (@MainActor () -> Void)?
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
        let generation = advanceLifecycle()
        guard let pinned = services.loadPins().host(publicKeyHash: host.publicKeyHash),
              let hostStatic = pinned.staticPublicKey else {
            phase = .failed(.ordinary(
                "\(host.name) is not paired — use Pair… first"))
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
            identity = try await services.identity(identityAuthenticationUI)
            HandshakeWitness.record("identityLookupCompleted")
        } catch {
            HandshakeWitness.record("identityLookupFailed", fields: [
                "error": String(describing: error),
            ])
            guard isCurrent(generation) else { return }
            // The Keychain path needs the stable "Lyte Dev" signature —
            // builds via Scripts/make-app.sh (docs/MACOS-SIGNING.md).
            phase = .failed(.ordinary("client identity: \(error)"))
            return
        }
        // The human may have cancelled (or started another connect)
        // while the Keychain answered: dialing now would clobber the
        // window's renderer and event epoch.
        guard isCurrent(generation) else { return }

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
        let deadline = services.now() + Self.freshConnectBudgetMicroseconds
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
                phase = .failed(.ordinary("host key: \(error)"))
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
                try await services.startSession(candidate)
                HandshakeWitness.record("sessionStartCompleted", fields: [
                    "round": String(round),
                ])
                guard isCurrent(generation) else {
                    // The human cancelled mid-dial: this session has
                    // no owner — close it politely and walk away.
                    services.endSession(candidate, .goodbye)
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
                guard isCurrent(generation) else { return }
                guard case TransportCryptoError.handshakeFailed(let why)
                        = error, why.hasPrefix("no response"),
                      services.now() < deadline else {
                    if let endpointError = error as? TransportEndpointError,
                       let problem = LocalNetworkAccessProblem.endpointError(
                        endpointError)
                    {
                        phase = .failed(.localNetwork(
                            problem,
                            diagnosticDetail: String(describing: error)))
                    } else {
                        phase = .failed(.ordinary(
                            "Lyte-UDP connect: \(error)"))
                    }
                    return
                }
                phase = .connecting("\(host.name) isn't answering — "
                    + "it may be restarting; still trying…")
                // The quiet re-browse: if the reborn host is already
                // advertising, dial where it lives NOW.
                let sighting = await services.browse(2.0)
                    .first { $0.publicKeyHash == host.publicKeyHash }
                guard isCurrent(generation) else { return }
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
        services.streamBegan()
    }


    /// Builds one wire session against this window's display layer,
    /// minting a fresh event epoch — the shared leg of the first
    /// connect and every roaming re-dial.
    private func makeLyteSession(
        crypto: NoiseTransportCrypto, config: LyteUdpSession.Config
    ) -> LyteUdpSession {
        linkHealthMeter.resetEpochKeepingSessionBooks()
        videoFlightRecorder.reset()
        videoDeliveryBooks.reset()
        videoInMeter.reset()
        retireRendererHandoff()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        VideoRendererHandoff.attachHostClockTimebase(to: displayLayer)
        let clockModel = HostClockModel()
        let handoff = VideoRendererHandoff(
            renderer: displayLayer.sampleBufferRenderer,
            queue: videoDeliveryQueue,
            clockModel: clockModel,
            books: videoDeliveryBooks,
            recorder: videoFlightRecorder,
            onDimensionsChanged: { [weak self] width, height in
                Task { @MainActor [weak self] in
                    self?.lyteVideoSize = CGSize(
                        width: CGFloat(width), height: CGFloat(height))
                }
            })
        videoRendererHandoff = handoff
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
            videoSink: handoff,
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleLyteEvent(event, epoch: epoch)
                }
            })
        handoff.bind(session)
        return session
    }

    /// Stops the current handoff (never blocking main) and flushes the
    /// renderer behind its last possible enqueue.
    private func retireRendererHandoff() {
        if let handoff = videoRendererHandoff {
            handoff.stop(flushingRenderer: true)
            videoRendererHandoff = nil
        } else {
            displayLayer.sampleBufferRenderer.flush()
        }
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

    func handleLyteEvent(_ event: LyteUdpSessionEvent) {
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
            switch Self.closeVerdict(reason) {
            case .ignore:
                break
            case .end(let message):
                endLyteSession(reason: message)
            case .roam:
                beginRoamingAfterLoss(reason)
            }
        }
    }

    /// What a closed session means for its window.
    enum CloseVerdict: Equatable {
        /// Our own teardown; whoever closed it is already driving the end.
        case ignore
        /// Keep the window and hunt the host identity.
        case roam
        /// End the window; a message turns it into a failure screen.
        case end(String?)
    }

    /// A host restart says goodbye with `.shuttingDown` and comes back
    /// seconds later, so it roams like a lost peer; only a takeover is
    /// a decision the window must honor by ending.
    static func closeVerdict(_ reason: SessionCloseReason) -> CloseVerdict {
        switch reason {
        case .localTeardown:
            return .ignore
        case .peerTeardown(.takenOver):
            return .end("session taken over by another client")
        case .peerTeardown(.shuttingDown), .livenessTimeout:
            return .roam
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
            services.endSession(lyte, .goodbye)
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
        retireRendererHandoff()
        videoFlightRecorder.reset()
        videoDeliveryBooks.reset()
        videoInMeter.reset()
        lyteVideoSize = .zero
        services.streamEnded()
        if let reason {
            phase = .failed(.ordinary(reason))
        } else {
            phase = .pickHost
        }
    }


    /// The 1 Hz link-health tick (driven by the stream container's task
    /// loop): fold new recorder frames into their event-second buckets,
    /// then publish the exact sum of the live 60-bucket window.
    func tickLinkHealth() {
        for f in videoFlightRecorder.recentFrames() {
            let outcome: LinkHealthMeter.Outcome
            if f.rendererFailed {
                outcome = .rendererFailure
            } else if f.rendererDropped {
                outcome = .uncorrectableMiss
            } else {
                outcome = .preserved
            }
            linkHealthMeter.observe(
                ordinal: f.ordinal,
                presentationLatenessMilliseconds:
                    f.presentationLatenessMilliseconds,
                outcome: outcome,
                eventMicroseconds: f.readyMicroseconds)
        }
        linkHealth = linkHealthMeter.assessment(
            nowMicroseconds: SystemMonotonicClock.nowMicroseconds)
    }

    /// The human's exit, whatever the phase: the connecting screen's
    /// Cancel, Disconnect, ⌘W. In-flight work is invalidated first — a
    /// dial that completes afterward closes its session and walks away —
    /// then whatever stands (session, roaming hunt) ends.
    func disconnect() {
        advanceLifecycle()
        if case .connecting = phase { phase = .pickHost }
        endLyteSession(reason: nil)
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
            var store = services.loadPins()
            store.setChromaTier(publicKeyHash: pkh, tier: tier)
            try? services.savePins(store)
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
        advanceLifecycle()
        roaming = RoamingPolicy(
            targetPublicKeyHash: publicKeyHash,
            address: address, port: port)
        roamingStatus = .attached
        // The Mac hopped networks: HS-12 migration gets the policy's
        // grace to carry the session (the feedback cadence keeps
        // sending from the new source unprompted); the ladder runs
        // only if the path stays dark.
        stopPathWatch = services.watchPath { [weak self] in
            Task { @MainActor [weak self] in
                self?.roamingInput { policy, now in
                    policy.pathChanged(now: now)
                }
            }
        }
    }

    private func stopRoamingMachinery() {
        advanceLifecycle()
        roamingTask?.cancel()
        roamingTask = nil
        roaming = nil
        roamingStatus = .attached
        stopPathWatch?()
        stopPathWatch = nil
    }

    /// The peer is gone (liveness) or restarting (its goodbye): keep
    /// the window (the last frame + the roaming banner), keep everything
    /// per-host (coordinator, posture, consent), drop the wire session,
    /// hunt the identity.
    private func beginRoamingAfterLoss(_ reason: SessionCloseReason) {
        guard roaming != nil else {
            // No identity to hunt: the policy is born with a pinned
            // session, so only an unpinned window lands here.
            endLyteSession(reason: reason == .livenessTimeout
                ? "host unreachable for 30 s" : nil)
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
        retireRendererHandoff()
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
        services.endSession(lyte, goodbye ? .goodbye : .silent)
    }

    /// One policy interaction: mutate under the injected wall clock,
    /// execute the actions, mirror the status, re-arm the deadline
    /// task. The single funnel for every roaming mutation.
    private func roamingInput(
        _ mutate: (inout RoamingPolicy, UInt64) -> [RoamingAction]
    ) {
        guard var policy = roaming else { return }
        let now = services.now()
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
        let clock = services.now
        roamingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let now = clock()
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

    /// One quiet browse pass; the completion answers the policy that
    /// asked (the beginScan/scanCompleted contract) and nobody else.
    private func runRoamingScan() {
        let generation = lifecycleGeneration
        let browse = services.browse
        Task { @MainActor [weak self] in
            let hosts = await browse(2.0)
            guard let self, self.isCurrent(generation) else { return }
            let sightings = hosts.compactMap { host -> RoamingSighting? in
                guard let pkh = host.publicKeyHash else { return nil }
                return RoamingSighting(
                    publicKeyHash: pkh,
                    address: host.address, port: host.port)
            }
            self.roamingInput { policy, now in
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
              let pinned = services.loadPins().host(publicKeyHash: pkh),
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
            guard let identity = services.cachedIdentity()
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
        let generation = lifecycleGeneration
        let start = services.startSession
        let endSession = services.endSession
        Task { @MainActor [weak self] in
            do {
                try await start(lyte)
            } catch {
                guard let self, self.isCurrent(generation) else { return }
                self.roamingInput { policy, now in
                    policy.dialFailed(now: now)
                }
                return
            }
            // The window disconnected (and perhaps connected afresh)
            // while this dial ran: the session has no owner.
            guard let self, self.isCurrent(generation),
                  self.lyteSession == nil else {
                endSession(lyte, .goodbye)
                return
            }
            self.adoptReconnectedSession(
                lyte, crypto: crypto, address: address, port: port)
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
            var store = services.loadPins()
            if let pinned = store.host(publicKeyHash: pkh),
               let key = pinned.staticPublicKey {
                store.pin(
                    staticPublicKey: key, name: pinned.name,
                    address: address, port: port,
                    pairedAt: pinned.pairedAt)
                try? services.savePins(store)
            }
        }
        roamingInput { policy, now in
            policy.sessionEstablished(
                address: address, port: port, now: now)
        }
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
                  let pinned = services.loadPins().host(publicKeyHash: pkh)
            else { return true }   // the CL-18 default posture
            return pinned.startHostAudioMuted != false
        }
        set {
            guard let pkh = hostPublicKeyHash else { return }
            var store = services.loadPins()
            store.setStartHostAudioMuted(publicKeyHash: pkh, muted: newValue)
            try? services.savePins(store)
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
            return services.loadPins()
                .host(publicKeyHash: pkh)?.shareClipboard == true
        }
        set {
            guard let pkh = hostPublicKeyHash else { return }
            var store = services.loadPins()
            store.setShareClipboard(
                publicKeyHash: pkh, share: newValue ? true : nil)
            try? services.savePins(store)
        }
    }

    /// The per-host images-rung default (P-1) — the third tier step.
    var shareClipboardImagesPreference: Bool {
        get {
            guard let pkh = hostPublicKeyHash else { return false }
            return services.loadPins()
                .host(publicKeyHash: pkh)?.shareClipboardImages == true
        }
        set {
            guard let pkh = hostPublicKeyHash else { return }
            var store = services.loadPins()
            store.setShareClipboardImages(
                publicKeyHash: pkh, share: newValue ? true : nil)
            try? services.savePins(store)
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
    /// counters wire-view prints, shaped for the overlay. The overlay
    /// explicitly samples this snapshot once per second while visible.
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
        let nowMicroseconds = SystemMonotonicClock.nowMicroseconds
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
            let glass = String(
                format: "source/ready p99 %.1f/%.1f ms"
                    + " · transit %.1f ms · sample %.1f ms"
                    + " · queue/enqueue %.1f/%.1f ms",
                flight.sourceGapP99Milliseconds ?? 0,
                flight.readyGapP99Milliseconds ?? 0,
                flight.transitStretchP99Milliseconds ?? 0,
                Double(pipelineStats.sampleBuildMicroseconds.p99 ?? 0) / 1_000,
                flight.queueWaitP99Milliseconds ?? 0,
                flight.enqueueP99Milliseconds ?? 0)
            row("glass", glass)

            // The physical renderer and the Conductor describe one playout
            // verdict, but they are distinct from the path timings above.
            // Keeping them on their own stable row prevents the glass ledger
            // from turning into one viewport-dependent wrapped sentence.
            var playout: [String] = []
            if let renderer = flight.rendererMetrics {
                playout.append("render \(renderer.totalFrames)")
                if let recent = flight.recentRendererMetrics {
                    playout.append("drop total/recent "
                        + "\(renderer.droppedFrames)/\(recent.droppedFrames)")
                    playout.append("corrupt total/recent "
                        + "\(renderer.corruptedFrames)"
                        + "/\(recent.corruptedFrames)")
                } else {
                    playout.append("drop \(renderer.droppedFrames)")
                    playout.append("corrupt \(renderer.corruptedFrames)")
                }
                playout.append(String(
                    format: "delay %.1f ms",
                    renderer.accumulatedDelayMilliseconds))
            }
            // The Conductor's score-to-glass cue and the portion left after
            // this frame's measured path time. These are deliberately named
            // separately: the cue is not all reserve.
            if let cue = flight.cueMilliseconds {
                playout.append(String(format: "cue %.0f ms", cue))
            }
            if let reserve = flight.reserveMilliseconds {
                playout.append(String(format: "reserve %.0f ms", reserve))
            }
            playout.append(flight.bottleneck)
            row("playout", playout.joined(separator: " · "))
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
