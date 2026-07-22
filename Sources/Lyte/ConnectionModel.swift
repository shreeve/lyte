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

    private(set) var hostAddress: String?
    private(set) var hostName: String?
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

        let lastDims = VideoDimsCell()
        let lyte = LyteUdpSession(
            crypto: crypto,
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
