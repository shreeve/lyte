import SwiftUI
@preconcurrency import AVFoundation
import LyteKit
import LyteTransport
import LyteUI
import LyteWire

/// Per-window connection state machine: pick host → (pair) → pick app →
/// connect → stream. Owns the session, display layer, and input capture.
@MainActor
@Observable
final class ConnectionModel {
    enum Phase {
        case pickHost
        case pairing(address: String, pin: String)
        case apps(address: String, hostName: String, apps: [NvApp])
        case connecting(String)
        case streaming
        case failed(String)
    }

    var phase: Phase = .pickHost
    var mode: StreamMode = .work
    var muted = false { didSet { session?.setAudioMuted(muted) } }
    var statusLine = ""

    private(set) var hostAddress: String?
    private(set) var hostName: String?
    private(set) var appTitle: String?
    private(set) var session: LyteSession?
    private(set) var policy: PolicyOutput?
    let displayLayer = AVSampleBufferDisplayLayer()

    // The Lyte-UDP path (CL-8): a paired discovered host streams through
    // LyteUdpSession instead of the frozen GameStream stack. Mode/pill
    // mirror the session's mediaReceiver machine for the stream overlay.
    private(set) var lyteSession: LyteUdpSession?
    private(set) var lyteWireMode: SessionWireMode = .active
    private(set) var lyteFrozen = false

    private var client: HostClient?
    var inputCapture: InputCapture?

    // The doctor: sampled every 3 s while streaming (PLAN §5.5). Silent by
    // design — adjustments just happen; the panel appears only on request
    // (Actions → Network Doctor).
    private let doctor = Doctor()
    private var doctorTask: Task<Void, Never>?
    var diagnosis: Diagnosis?
    var showDoctor = false
    /// Set when the doctor sees FEC-exceeded loss this session; teaches
    /// HostHeadroom a lower ceiling at session end.
    private var sessionSawLoss = false

    var windowTitle: String {
        switch phase {
        case .streaming:
            return "\(appTitle ?? "Stream") on \(hostName ?? hostAddress ?? "host")"
        default:
            return "Lyte"
        }
    }

    // MARK: - Host selection & pairing

    func selectHost(_ address: String, name: String?) async {
        var store = ClientStore.load()
        hostAddress = address
        hostName = name ?? store.host(address)?.name ?? address

        if let host = store.host(address), host.serverCertDER != nil, store.identity() != nil {
            await loadApps(address: address)
            return
        }

        // Not paired — run the PIN dance (client shows PIN; user types it
        // into the Sunshine web UI).
        let identity: ClientIdentity
        do {
            if let existing = store.identity() {
                identity = existing
            } else {
                identity = try ClientIdentity.create()
                store.clientCertPEM = identity.certificatePEM
                try store.save()
            }
        } catch {
            phase = .failed("identity: \(error.localizedDescription)")
            return
        }

        let pin = PairingSession.generatePIN()
        phase = .pairing(address: address, pin: pin)
        do {
            let client = HostClient(address: address, uniqueID: store.uniqueID)
            let result = try await PairingSession(client: client, identity: identity).pair(pin: pin)
            let paired = HostClient(address: address, uniqueID: store.uniqueID,
                                    identity: identity, pinnedServerCertDER: result.serverCertDER)
            let info = try await paired.serverInfo(https: true)
            store.upsert(ClientStore.Host(name: info.hostname, address: address,
                                          serverCertPEM: result.serverCertPEM, mac: info.mac),
                         key: address)
            try store.save()
            hostName = info.hostname
            await loadApps(address: address)
        } catch {
            phase = .failed("pairing: \(error.localizedDescription)")
        }
    }

    private func loadApps(address: String) async {
        let store = ClientStore.load()
        guard let host = store.host(address), let pinned = host.serverCertDER,
              let identity = store.identity() else {
            phase = .failed("not paired with \(address)")
            return
        }
        let client = HostClient(address: address, uniqueID: store.uniqueID,
                                identity: identity, pinnedServerCertDER: pinned)
        self.client = client
        do {
            let apps = try await client.appList()
            phase = .apps(address: address, hostName: hostName ?? address, apps: apps)
        } catch {
            phase = .failed("app list: \(error.localizedDescription)")
        }
    }

    // MARK: - Streaming

    func connect(app: NvApp) async {
        guard let client, let address = hostAddress else { return }
        appTitle = app.title

        // Desktop ⇒ Work, anything game-like ⇒ Play (auto-intent, dismissible later)
        mode = app.title.localizedCaseInsensitiveContains("desktop") ? .work : .play

        let panel = NSScreen.main.map {
            (width: Int($0.frame.width * $0.backingScaleFactor),
             height: Int($0.frame.height * $0.backingScaleFactor))
        }
        let derived = Policy.derive(PolicyInput(mode: mode, clientPanel: panel,
                                                bitrateCeilingKbps: HostHeadroom.ceiling(for: address)))
        policy = derived
        sessionSawLoss = false
        phase = .connecting("Launching \(app.title)…")

        do {
            let info = try await client.serverInfo(https: true)
            let context: StreamContext
            if let current = info.currentGame, current != "0", !current.isEmpty {
                context = try await client.resume(appID: app.id, width: derived.width,
                                                  height: derived.height, fps: derived.fps,
                                                  bitrateKbps: derived.bitrateKbps)
            } else {
                context = try await client.launch(appID: app.id, width: derived.width,
                                                  height: derived.height, fps: derived.fps,
                                                  bitrateKbps: derived.bitrateKbps)
            }

            displayLayer.videoGravity = .resizeAspect
            displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)

            let session = LyteSession(context: context, displayLayer: displayLayer) { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch event {
                    case .log(let line): self.statusLine = line
                    case .connected: break
                    case .terminated(let reason): self.endSession(reason: reason)
                    }
                }
            }
            self.session = session
            try await session.start()
            phase = .streaming
            AgentState.shared.streamBegan()
            RecentConnections.remember(address: address, app: app.title)
            if let hint = HelperClient.shared.streamBegan() {
                statusLine = hint
            }
            doctorTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, let session = self.session else { return }
                    self.diagnosis = self.doctor.sample(session.stats,
                                                        helperEngaged: HelperClient.shared.engaged)
                    if self.diagnosis?.lossy == true { self.sessionSawLoss = true }
                }
            }
        } catch {
            // Never reached .streaming: drop the session here so endSession's
            // accounting (agent stream count, headroom learning) can't run
            // for a stream that never was.
            session?.stop()
            session = nil
            phase = .failed("connect: \(error.localizedDescription)")
        }
    }

    // MARK: - Lyte-UDP streaming (CL-8)

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
        appTitle = "Desktop"
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

        let lyte = LyteUdpSession(
            crypto: crypto,
            onSample: { sample, _ in
                renderer.enqueue(sample)
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
        mode = .work
        phase = .streaming
        statusLine = crypto.modeDescription
        AgentState.shared.streamBegan()
    }

    private func handleLyteEvent(_ event: LyteUdpSessionEvent) {
        switch event {
        case .capabilitiesAgreed(let agreed):
            statusLine = "capabilities agreed — idle silence "
                + (agreed.idleSilence ? "on" : "off")
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

    /// Relaunch-reconnect (D6): host → apps → the remembered app, no clicks.
    func reconnect(address: String, appTitle: String) async {
        await selectHost(address, name: nil)
        if case .apps(_, _, let apps) = phase,
           let app = apps.first(where: { $0.title == appTitle }) {
            await connect(app: app)
        }
    }

    func endSession(reason: String?) {
        if lyteSession != nil {
            endLyteSession(reason: reason)
            return
        }
        doctorTask?.cancel()
        doctorTask = nil
        diagnosis = nil
        HelperClient.shared.streamEnded()
        inputCapture?.stop()
        inputCapture = nil
        if session != nil {
            AgentState.shared.streamEnded()
            // Headroom learning (D2): loss teaches a lower ceiling; a clean
            // session earns a little back.
            if let address = hostAddress {
                if sessionSawLoss, let bitrate = policy?.bitrateKbps {
                    HostHeadroom.recordLoss(address: address, atKbps: bitrate)
                } else {
                    HostHeadroom.recordClean(address: address)
                }
            }
        }
        session?.stop()
        session = nil
        if let reason {
            phase = .failed(reason)
        } else {
            phase = .pickHost
        }
    }

    func disconnect() {
        endSession(reason: nil)
    }
}

/// Measured per-host bitrate ceilings (the M5.5 seed): a session that hit
/// FEC-exceeded loss pulls the next connect's bitrate to 70% of what dropped;
/// each clean session earns 10% back, so the policy re-probes upward over
/// time instead of pinning the host low forever. Keyed by address.
enum HostHeadroom {
    private static let key = "hostBitrateCeilingsKbps"

    static func ceiling(for address: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int])?[address]
    }

    static func recordLoss(address: String, atKbps bitrate: Int) {
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        let cut = max(5_000, (Int(Double(bitrate) * 0.7) + 500) / 1000 * 1000)
        map[address] = min(map[address] ?? .max, cut)
        UserDefaults.standard.set(map, forKey: key)
    }

    static func recordClean(address: String) {
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        guard let current = map[address] else { return }
        map[address] = min((Int(Double(current) * 1.1) + 500) / 1000 * 1000, 100_000)
        UserDefaults.standard.set(map, forKey: key)
    }
}

/// Recents, persisted in UserDefaults ("address|app" strings, most recent first).
enum RecentConnections {
    private static let key = "recentConnections"

    static func remember(address: String, app: String) {
        var entries = load().filter { !($0.address == address && $0.app == app) }
        entries.insert((address, app), at: 0)
        UserDefaults.standard.set(entries.prefix(6).map { "\($0.address)|\($0.app)" }, forKey: key)
    }

    static func load() -> [(address: String, app: String)] {
        var seen = Set<String>()
        return (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap {
            let parts = $0.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return nil }
            // Dedup on read too — stale duplicates from older builds or an
            // address/name mismatch must never surface twice.
            let key = "\(parts[0].lowercased())|\(parts[1].lowercased())"
            guard seen.insert(key).inserted else { return nil }
            return (parts[0], parts[1])
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
