import LyteIO
import LyteCore
import LyteClientCore
import SwiftUI
@preconcurrency import AVFoundation
import LyteTransport
import LyteUI
import LyteWire

/// Per-window connection state machine: pick host → (pair) → connect →
/// stream. Owns the Lyte-UDP session, display layer, and input capture.
///
/// Files: this one holds the phase machine, the session lifecycle (connect,
/// attach, detach, end), event dispatch, and the stats readout;
/// `+Roaming` the re-acquisition driver; `+Features` host audio,
/// clipboard, bulk, chroma, and the per-host preferences.
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

    let services: ConnectionServices

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
    private(set) var lifecycleGeneration: UInt64 = 0

    @discardableResult
    func advanceLifecycle() -> UInt64 {
        lifecycleGeneration &+= 1
        return lifecycleGeneration
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        generation == lifecycleGeneration
    }

    // MARK: - Session state

    /// The Lyte-UDP session; nil while connecting, roaming, or idle.
    private(set) var lyteSession: LyteUdpSession?
    /// Fences late events from detached sessions: each session built
    /// mints an epoch, and only the current epoch's events apply.
    private var sessionEpoch = 0
    /// The session machine's FROZEN pill.
    private(set) var lyteFrozen = false
    /// What the current session's capability agreement made available.
    var negotiated = NegotiatedFeatures.none
    var muted = false {
        didSet { lyteSession?.setAudioMuted(muted) }
    }
    /// The stats readout's visibility (the strip's chart toggle).
    var statsVisible = false

    private(set) var hostAddress: String?
    private(set) var hostName: String?
    /// The pinned identity hash of the streaming host — the per-host
    /// preference key.
    private(set) var hostPublicKeyHash: String?
    /// The streaming host's pinned entry, read once per connect and
    /// refreshed on every write: views and menus never touch the disk.
    var pinnedHost: PinnedHost?

    // MARK: Per-host live state (survives roaming re-dials)

    /// The 0x19-confirmed host-speaker posture, nil until the host's
    /// first status. Never set optimistically: a toggle asks and waits.
    var hostAudioPosture: HostAudioRoutingMode?
    /// The last confirmed STREAMING posture — where the audio-off toggle
    /// returns to (streamOff never lands here).
    var lastStreamingAudioPosture: HostAudioRoutingMode = .hostMuted
    /// Live clipboard consent, seeded from the per-host default at
    /// connect (default off — clipboards carry passwords). The pasteboard
    /// watcher runs only while consent and capability both hold.
    var clipboardSharing = false
    /// The images rung's live consent; images move only while text
    /// sharing is also on.
    var clipboardImageSharing = false
    var pasteboardSync: PasteboardSync?
    /// The bulk coordinator outlives the wire session (it re-offers the
    /// same transfer id into the next session — resume on reconnect) but
    /// never a host change: a file dropped for one host must not follow
    /// the user to another.
    var bulkCoordinator: BulkSendCoordinator?
    var bulkCoordinatorHostKey: String?
    /// The coordinator's snapshot, for the progress pill.
    var bulkStatus = BulkSendSnapshot.idle
    /// The transient verdict line under the pill.
    var bulkNotice: String?
    var bulkNoticeTask: Task<Void, Never>?
    /// The live chroma declaration, seeded from the per-host default at
    /// connect. A flip is a clean reconnect; the fallback path lowers
    /// this live state, never the persisted preference.
    var chromaTier: ChromaTier = .good
    /// The non-modal fallback banner.
    var chromaNotice: String?
    var chromaNoticeTask: Task<Void, Never>?

    // MARK: Roaming (driven by +Roaming)

    /// Lives for a window's whole streaming life — it IS the "can this
    /// window reconnect" verdict; its status drives the overlay banner.
    var roaming: RoamingPolicy?
    var roamingTask: Task<Void, Never>?
    var roamingStatus: RoamingStatus = .attached
    var stopPathWatch: (@MainActor () -> Void)?

    // MARK: Video

    let displayLayer = AVSampleBufferDisplayLayer()
    /// Shared by every session's handoff, so a retiring handoff's reset
    /// and renderer flush are ordered before its successor's first sample.
    private let videoDeliveryQueue = DispatchQueue(
        label: "lyte.video.delivery", qos: .userInteractive)
    private let videoDeliveryBooks = VideoDeliveryBooks()
    /// Source cadence, receive cadence, delivery queue, renderer enqueue,
    /// and Apple's decode/display books. Bounded to six seconds at 60 fps
    /// and always on — visual failures cannot depend on the stats overlay
    /// being open.
    private let videoFlightRecorder = VideoFlightRecorder(
        nowMicroseconds: { SystemMonotonicClock.nowMicroseconds })
    /// The link-health fold over the recorder's ring. Ticked at 1 Hz; its
    /// ordinal high-water mark makes overlapping scans idempotent, and a
    /// recorder reset (ordinals restart) clears it implicitly.
    private let linkHealthMeter = LinkHealthMeter()
    /// nil until streaming produces a verdict; .good renders nothing.
    private(set) var linkHealth: LinkHealthAssessment?
    /// in-fps over the delivery books' out-fps window shape, so the
    /// overlay's in/out pair compares honestly.
    private var videoInMeter = RateMeter()
    private var videoRendererHandoff: VideoRendererHandoff?
    /// The host's stream dimensions, from the first delivered sample —
    /// the input capture's coordinate space (absolute moves drop until
    /// it is known).
    private(set) var lyteVideoSize: CGSize = .zero
    var lyteInputCapture: LyteInputCapture?
    /// The stream surface, held weakly so the model can dress it with
    /// the host's announced cursor (StreamView installs it).
    weak var lyteVideoView: VideoLayerView?

    // MARK: - Derived

    /// The stream overlay's roaming banner; nil while the session is
    /// healthy (or merely FROZEN — the pill's tier).
    var roamingStatusLine: String? {
        RoamingStatusLine.line(
            for: roamingStatus,
            hostName: hostName ?? hostAddress ?? "the host")
    }

    /// Reconnect exists while a streaming window has an identity to hunt
    /// (roaming or not — a manual reconnect over a limping session is
    /// legitimate).
    var canReconnect: Bool { roaming != nil }

    /// Disconnect works during roaming too — the session object is gone
    /// but the window still hunts.
    var canEndSession: Bool { lyteSession != nil || roaming != nil }

    var windowTitle: String {
        switch phase {
        case .streaming:
            return "\(hostName ?? hostAddress ?? "host") — Lyte"
        default:
            return "Lyte"
        }
    }

    // MARK: - Connect

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
        pinnedHost = pinned
        phase = .connecting("Connecting to \(host.name) over Lyte-UDP…")
        HandshakeWitness.record("autoconnectBegin", fields: [
            "host": host.address,
            "port": String(host.port),
        ])

        let environment = ProcessInfo.processInfo.environment
        let benchmarking = environment["LYTE_BENCHMARK_RUN_ID"] != nil
        // A benchmark autoconnect has no human interaction surface. Never
        // let Security.framework wait on hidden authorization UI before the
        // first handshake byte; an ACL problem must fail bounded and loud.
        let identityAuthenticationUI:
            ClientNoiseIdentityProvider.AuthenticationUI = benchmarking ? .fail : .allow
        let identity: NoiseKeyPair
        do {
            // SecItemCopyMatching may synchronously cross securityd and
            // wait for Keychain authorization; the provider keeps that off
            // the MainActor.
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

        // The per-host preferences seed the session-start posture; the
        // strip's toggles are the live override thereafter. The images
        // default is meaningful only on top of text consent.
        let benchmarkChroma = benchmarking
            ? environment["LYTE_BENCHMARK_CHROMA_TIER"].flatMap(ChromaTier.init(rawValue:))
            : nil
        chromaTier = benchmarkChroma.flatMap { $0.isSelectable ? $0 : nil }
            ?? pinned.sessionChromaTier
        let sessionConfig = LyteUdpSession.Config(
            hostAudioRouting: pinned.sessionStartHostAudioRouting,
            shareClipboard: pinned.shareClipboard == true,
            shareClipboardImages: pinned.shareClipboard == true
                && pinned.shareClipboardImages == true,
            chroma: chromaTier)

        // The respawn-gap patience: a paired host that answered discovery
        // moments ago but is SILENT now is almost always restarting — its
        // boot takes 10–15 s while a single dial gives up in ~10. So
        // silence hunts instead of dead-ending: short dials (the roaming
        // shape, 3 × 700 ms), a 2 s re-browse between them (the reborn
        // host re-registers — follow its freshest address), inside one
        // budget. Every OTHER failure — crypto rejection, unpaired,
        // socket errors — fails immediately: patience is only for silence.
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
            let candidate = makeLyteSession(crypto: crypto, config: sessionConfig)
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
                    // Cancelled mid-dial: this session has no owner.
                    services.endSession(candidate, .goodbye)
                    return
                }
                lyte = candidate
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
        hostAudioPosture = nil
        clipboardSharing = sessionConfig.core.shareClipboard
        clipboardImageSharing = sessionConfig.core.shareClipboardImages
        attach(lyte, address: dialAddress)
        // The pinned lookup above guarantees a pkh in practice; the
        // address fallback keeps the key total.
        prepareBulkCoordinator(hostKey: host.publicKeyHash ?? host.address)
        if let pkh = host.publicKeyHash {
            startRoamingMachinery(
                publicKeyHash: pkh, address: dialAddress, port: dialPort)
        }
        phase = .streaming
        services.streamBegan()
    }

    // MARK: - Session lifecycle

    /// Builds one wire session against this window's display layer,
    /// minting a fresh event epoch — the shared leg of the first
    /// connect and every roaming re-dial.
    func makeLyteSession(
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

    /// A started session becomes the window's — the one attach path for
    /// the first connect and every roaming re-dial. The capability
    /// agreement drives the rest.
    func attach(_ lyte: LyteUdpSession, address: String) {
        lyteSession = lyte
        hostAddress = address
        lyte.setAudioMuted(muted)
        // One watcher per session, started only once key 10 agrees AND
        // sharing is on (updatePasteboardWatcher).
        pasteboardSync = makePasteboardSync(for: lyte)
    }

    /// Roaming-preserving teardown: the wire session goes away; the
    /// window and everything per-HOST stays for the re-dial — live
    /// consent, the confirmed posture (the re-dial asks for it), the
    /// input capture (its sends route through `lyteSession` live and
    /// drop while nil), and the bulk coordinator (its next
    /// `sessionReady` re-offers the same id).
    func detachWireSession(_ end: ConnectionServices.SessionEnd) {
        guard let lyte = lyteSession else { return }
        lyteSession = nil
        sessionEpoch += 1
        services.endSession(lyte, end)
        dropSessionState()
    }

    private func dropSessionState() {
        negotiated = .none
        lyteFrozen = false
        pasteboardSync?.stop()
        pasteboardSync = nil
        bulkCoordinator?.sessionEnded()
        retireRendererHandoff()
        videoFlightRecorder.reset()
        videoDeliveryBooks.reset()
        videoInMeter.reset()
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

    /// Ends the window's session for good — the session (typed goodbye,
    /// off-main), any roaming hunt, and every per-host live state.
    /// `reason` turns the end into a failure screen.
    func endLyteSession(reason: String?) {
        guard lyteSession != nil || roaming != nil else { return }
        stopRoamingMachinery()
        lyteInputCapture?.stop()
        lyteInputCapture = nil
        // Back to AppKit's own arrow — a dead session must not leave the
        // host's shape (or its hidden state) stuck on.
        lyteVideoView?.hostCursor = nil
        if lyteSession != nil {
            detachWireSession(.goodbye)
        } else {
            dropSessionState()
        }
        hostAudioPosture = nil
        clipboardSharing = false
        clipboardImageSharing = false
        chromaNoticeTask?.cancel()
        chromaNotice = nil
        linkHealth = nil
        // The sitting is over — the cumulative stall books go with it
        // (a roaming re-dial only restarts the meter's window).
        linkHealthMeter.resetSessionBooks()
        statsVisible = false
        lyteVideoSize = .zero
        services.streamEnded()
        phase = reason.map { .failed(.ordinary($0)) } ?? .pickHost
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

    // MARK: - Events

    private func handleLyteEvent(_ event: LyteUdpSessionEvent, epoch: Int) {
        // A detached session's stragglers must not touch the model.
        guard epoch == sessionEpoch else { return }
        handleLyteEvent(event)
    }

    func handleLyteEvent(_ event: LyteUdpSessionEvent) {
        switch event {
        case .capabilitiesAgreed(let agreed):
            negotiated = NegotiatedFeatures(agreed)
            updatePasteboardWatcher()
            // Attach the coordinator's chan-8 leg. A transfer the last
            // session interrupted re-offers its SAME id here.
            let session = lyteSession
            bulkCoordinator?.sessionReady(
                negotiated: agreed.bulkTransfer,
                send: { [weak session] bytes in
                    // A refused send is a teardown race — the ARQ state is
                    // dying with the session; resume covers.
                    try? session?.sendBulkMessage(bytes)
                })
        case .bulkMessageReceived(let message):
            bulkCoordinator?.ingest(message)
        case .hostAudioRoutingStatus(let mode):
            hostAudioPosture = mode
            if mode != .streamOff { lastStreamingAudioPosture = mode }
        case .hostClipboardChanged(let text):
            // Already through the core's gates; the glue just applies.
            pasteboardSync?.apply(text)
        case .hostCursorShapeChanged(let shape):
            applyHostCursor(shape)
        case .hostClipboardImageChanged(let data, _):
            // Sha-verified PNG through the core's gates; the glue applies.
            pasteboardSync?.apply(imageData: data)
        case .capabilitiesFailed(let failure):
            handleCapabilitiesFailure(failure)
        case .stateChanged(let state):
            lyteFrozen = state == .frozen
            // The FROZEN edge feeds the roaming silence clock; any other
            // state is evidence moving again.
            if state == .frozen {
                roamingInput { policy, now in policy.wentSilent(now: now) }
            } else {
                roamingInput { policy, now in policy.evidenceReturned(now: now) }
            }
        case .capabilityUpdateAnswered, .modeChanged, .idleFrameReceived,
             .teardownSent, .protocolNote:
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

    /// Wears the host's announced cursor over the stream. The scale maps
    /// host device pixels onto the video's on-glass points through the
    /// aspect-fit rect, so the worn shape matches the video's
    /// magnification; before the first sample (no video size) 0.75
    /// approximates the host's 1.333 logical scale.
    private func applyHostCursor(_ shape: CursorShape) {
        guard let view = lyteVideoView else { return }
        var scale: CGFloat = 0.75
        if lyteVideoSize.width > 0, view.bounds.width > 0 {
            let fit = AVMakeRect(aspectRatio: lyteVideoSize, insideRect: view.bounds)
            scale = fit.width / lyteVideoSize.width
        }
        view.hostCursor = HostCursorImage.cursor(from: shape, scale: scale)
    }

    // MARK: - Link health

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

    // MARK: - Window verbs (strip + Actions menu, same commands)

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    // MARK: - The stats readout

    /// 1_734_567 → "1.73M"; 41_200 → "41.2k"; small counts stay exact.
    /// Only ever used for denominators — deficits always print exact.
    nonisolated private static func compactCount(_ n: UInt64) -> String {
        switch n {
        case ..<10_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1e3)
        default: return String(format: "%.2fM", Double(n) / 1e6)
        }
    }

    /// The network row's loss clause. `lost` is the demux's per-channel
    /// `seqMissing` sum, which is already net of late (reordered) fills.
    nonisolated static func lossSummary(lost: UInt64, received: UInt64) -> String {
        let expected = received + lost
        guard lost > 0 else {
            return "lost 0 of \(compactCount(expected)) host packets"
        }
        let percent = String(
            format: "%.3f", 100 * Double(lost) / Double(max(1, expected)))
        return "lost \(lost) of \(compactCount(expected)) host packets (\(percent)%)"
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

        // Row order: session state heads the block, then user input and
        // the network, then audio and video ADJACENT (the two media rows
        // read together). Conditional rows follow.
        //
        // The net line: loss deficit-first (a success-count brags; the
        // deficit is the signal, and a percent must never round a real
        // loss into looking clean), then the clock model's honest RTT.
        let totals = endpoint.demux.snapshotTotals()
        let lost = endpoint.demux.snapshotChannels()
            .reduce(UInt64(0)) { $0 + $1.stats.seqMissing }
        var wire = Self.lossSummary(lost: lost, received: totals.datagrams)
        // roundtrip min + jitter, spelled out — "±" falsely implies a
        // symmetric spread; the stat is the floor plus upward spread
        // (p90 − min), which is what "jitter" means to every reader.
        // Window: the last 10 beacons ≈ 10 s at 1 Hz — the shortest
        // window that still feeds the p90 enough samples.
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
        // Caps-as-alarm: nominal states are lowercase so a HEALTHY
        // overlay contains zero uppercase — the glance test is "any caps
        // anywhere?". Only alarms (FROZEN, NOT CAPTURED, AWDL LOOSE)
        // shout.
        var mode = core.wireMode == .active ? "active" : "idle"
        if core.isFrozen { mode += " — FROZEN" }
        // Codec and chroma are fixed at announce (changing tiers means a
        // reconnect), so they are session state like the postures beside
        // them, not live metrics.
        if let chroma = core.streamChromaDescription {
            mode += " · hevc \(chroma)"
        }
        if negotiated.hostAudioRouting {
            switch hostAudioPosture {
            case .hostMuted: mode += " · host audio muted"
            case .hostAudible: mode += " · host audio audible"
            case .streamOff: mode += " · audio stream off"
            case nil: mode += " · host audio pending"
            }
        }
        if negotiated.clipboardText {
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

        // Unconditional: "0 events sent to host" is the datum that tells
        // a client-capture failure from a host-side one. (The transport
        // line carries a "user:" prefix; the ledger moves it into the
        // label column.)
        let userLine = core.input.snapshotStats().overlayLine()
        row("user", userLine.hasPrefix("user:")
            ? String(userLine.dropFirst(5))
                .trimmingCharacters(in: .whitespaces)
            : userLine)

        // Outbound then inbound — the directions read as a pair — then
        // the inbound media lines they frame.
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

        // The quality line — what the receive side can say about
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
            // stands bare (self-naming).
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
        if negotiated.clipboardText, clipboardActivity > 0 {
            row("clipboard", "\(clipboard.clipboardSharesSent) sent"
                + " · \(clipboard.clipboardAnnouncesReceived) recv"
                + " · \(clipboard.clipboardLoopSuppressed) suppressed")
        }

        // P-1: the image lane's books, while it has any.
        let images = core.clipboardImageCounters
        let imageActivity = images.sharesStarted + images.imagesApplied
            + images.sharesSuppressed + images.receivesRefused
        if negotiated.clipboardImages, imageActivity > 0 {
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
