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
    /// in-fps over the same ~1 s window shape as the delivery books'
    /// out-fps, so the overlay's in/out slash-pair compares honestly.
    private let videoInMeter = RateMeter()

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
        chromaTier = pinned.sessionChromaTier
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
                try await Task.detached { try candidate.start() }.value
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
        lyteWireMode = .active
        lyteFrozen = false
        hostAudioNegotiated = false
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
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        let renderer = displayLayer.sampleBufferRenderer
        let lastDims = VideoDimsCell()
        sessionEpoch += 1
        let epoch = sessionEpoch
        return LyteUdpSession(
            crypto: crypto,
            config: config,
            onSample: { [weak self, videoDeliveryQueue, videoDeliveryBooks] sample, _ in
                // True ownership transfer: the receive thread hands the
                // buffer to the delivery queue and never touches it
                // again (CMSampleBuffer is CF-immutable here; the
                // Sendable annotation just can't say so).
                nonisolated(unsafe) let transferred = sample
                let dispatched = DispatchTime.now().uptimeNanoseconds
                videoDeliveryQueue.async {
                    renderer.enqueue(transferred)
                    videoDeliveryBooks.record(hopMilliseconds:
                        Double(DispatchTime.now().uptimeNanoseconds
                            &- dispatched) / 1e6)
                }
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
    }

    private func handleLyteEvent(_ event: LyteUdpSessionEvent, epoch: Int) {
        // A detached session's stragglers must not touch the model —
        // the epoch fence (F-5): only the CURRENT session speaks.
        guard epoch == sessionEpoch else { return }
        handleLyteEvent(event)
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
        case .hostClipboardChanged(let text):
            // Already through the core's gates (negotiated + sharing
            // on, book pre-armed); the glue just applies.
            pasteboardSync?.apply(text)
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
        statsVisible = false
        lyteInputCapture?.stop()
        lyteInputCapture = nil
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
        lyteFrozen = false
        hostAudioNegotiated = false
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
        let identity: NoiseKeyPair
        let crypto: NoiseTransportCrypto
        do {
            identity = try ClientNoiseIdentity.loadOrCreate()
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
    func statsLines() -> [String] {
        guard let session = lyteSession,
              let endpoint = session.endpoint,
              let core = session.core else { return [] }
        var lines: [String] = []

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
            ? "inbound:  lost 0 of \(Self.compactCount(expected)) host packets"
            : String(format: "inbound:  lost %d of %@ host packets (%.3f%%)",
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
        var mode = "stream:   \(core.wireMode == .active ? "active" : "idle")"
        if core.isFrozen { mode += " — FROZEN" }
        // Chroma lives HERE (owner catch, round three): it is fixed at
        // ANNOUNCE — changing tiers means a reconnect — so it is a
        // session state like the postures beside it, not a live metric.
        if let chroma = core.streamChromaDescription {
            mode += " · \(chroma)"
        }
        if hostAudioNegotiated {
            switch hostAudioPosture {
            case .hostMuted: mode += " · host audio muted"
            case .hostAudible: mode += " · host audio audible"
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
        lines.append(mode)

        // Unconditional (CL-16): "input  sent 0 events" is the datum
        // that tells a client-capture failure from a host-side one.
        lines.append(core.input.snapshotStats().overlayLine())

        let audio = core.audio.snapshotStats()
        if audio.depacketizer.datagramsIngested > 0 {
            var parts: [String] = []
            // Buffer depth in ms, not packets (exact: 5 ms hard-CBR
            // packets) — "15/40 ms of cushion" needs no decoder ring.
            if let p50 = audio.bufferDepthPackets.p50,
               let p99 = audio.bufferDepthPackets.p99 {
                parts.append("buffer p50/p99 \(p50 * 5)/\(p99 * 5) ms")
            }
            // Each concealment papered over one missing-audio gap — a
            // potential tiny audible artifact; the count IS the story.
            parts.append("gaps concealed \(audio.jitter.plcInvocations)")
            if audio.depacketizer.packetsRebuilt > 0 {
                parts.append("repaired \(audio.depacketizer.packetsRebuilt)")
            }
            lines.append("audio:    " + parts.joined(separator: " · "))
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
            // slash-pair is honest because BOTH ride the same ~1 s
            // meter window (RateMeter) — a widening split is a
            // glass-side stall, not a network one. Mbps leads and
            // stands bare (self-naming); chroma moved to the stream
            // line (session state, not live metric).
            var video = String(format: "video:    %.1f Mbps",
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
            lines.append(video)
        }

        // The wire-health footer closes the standing block.
        lines.append(wire)

        let clipboard = core.snapshotCounters()
        let clipboardActivity = clipboard.clipboardSharesSent
            + clipboard.clipboardAnnouncesReceived
            + clipboard.clipboardLoopSuppressed
        if clipboardNegotiated, clipboardActivity > 0 {
            lines.append("clipboard \(clipboard.clipboardSharesSent) sent"
                + " · \(clipboard.clipboardAnnouncesReceived) recv"
                + " · \(clipboard.clipboardLoopSuppressed) suppressed")
        }

        // P-1: the image lane's books, while it has any.
        let images = core.clipboardImageCounters
        let imageActivity = images.sharesStarted + images.imagesApplied
            + images.sharesSuppressed + images.receivesRefused
        if clipboardImagesNegotiated, imageActivity > 0 {
            lines.append("clip images \(images.sharesCompleted)"
                + "/\(images.sharesStarted) sent"
                + " · \(images.imagesApplied) applied"
                + " · \(images.sharesSuppressed) suppressed")
        }

        // F-4: the bulk channel's books, while it has any.
        if clipboard.bulkMessagesSent + clipboard.bulkMessagesReceived > 0 {
            var line = "bulk \(clipboard.bulkMessagesSent) sent"
                + " · \(clipboard.bulkMessagesReceived) recv"
            if let progress = bulkStatus.progress,
               progress.totalByteCount > 0 {
                line += String(format: " · %.0f%%", progress.fraction * 100)
            }
            lines.append(line)
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
