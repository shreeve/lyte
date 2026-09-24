// LyteUdpSession: the production shell behind the app's ConnectionModel and
// `lyte-cli wire-view`. It binds the socket, runs the Noise IK handshake
// (answering a retry challenge with the verbatim message 1), publishes a
// LyteUdpSessionCore, starts the receive thread and timers, and runs audio
// playout. Most session state is read through `core`.

import LyteIO
import Dispatch
import Foundation
import LyteWire
import Synchronization

public final class LyteUdpSession: @unchecked Sendable {
    public struct Config: Sendable {
        /// The local bind (0 = kernel-assigned; wire-view binds its
        /// argued port for tcpdump-friendly runs).
        public var bindPort: UInt16 = 0
        public var bindAddress: String = "0.0.0.0"
        public var core = LyteUdpSessionCoreConfig()
        /// How long `close()` waits for the teardown segment's ACK
        /// before tearing the socket down anyway.
        public var teardownLingerMilliseconds = 500
        /// decode + play the audio channel (AVAudioEngine).
        /// Default on — audio just plays; the receiver's stats exist
        /// either way. wire-view surfaces this as --audio.
        public var audioPlayback = true

        public init() {}
    }

    /// The crypto seam, prepared by the caller: NoiseTransportCrypto
    /// with persistent identity for the app's paired path or a throwaway
    /// identity for the --host-key debug posture.
    public let crypto: any TransportCrypto
    public let config: Config
    public private(set) var endpoint: UdpReceiveEndpoint?
    private let coreStorage = Mutex<LyteUdpSessionCore?>(nil)
    public var core: LyteUdpSessionCore? {
        coreStorage.withLock { $0 }
    }
    /// The playback unit, present when `config.audioPlayback`
    /// and the audio device came up.
    public private(set) var audioPlayer: LyteAudioPlayer?

    private let videoSink: any VideoSink
    private let onEvent: @Sendable (LyteUdpSessionEvent) -> Void
    private let onVideoRecoveryDemand:
        @Sendable (VideoRecoveryCause, FrameNumber) -> Void
    private let onVideoRecoveryTrace:
        @Sendable (VideoRecoveryTraceEvent) -> Void
    private let closing = Atomic<Bool>(false)
    public let clockModel: HostClockModel
    /// CoreAudio engine start/stop runs here, never on the caller's
    /// thread: AVAudioEngine.start() can block on HAL/device arbitration,
    /// which would wedge a main-actor caller. One serial queue keeps
    /// start/stop ordered.
    private let audioQueue = DispatchQueue(
        label: "lyte.audio.engine", qos: .userInitiated)
    private lazy var orderedInput = OrderedInputSender {
        [weak self] body, captured in
        guard let self, let core = self.core else {
            throw TransportEndpointError.notStarted
        }
        _ = try core.sendInput(body, captured: captured)
    }

    public init(
        crypto: any TransportCrypto,
        config: Config = Config(),
        clockModel: HostClockModel = HostClockModel(),
        onVideoRecoveryDemand: @escaping @Sendable (
            VideoRecoveryCause, FrameNumber
        ) -> Void = { _, _ in },
        onVideoRecoveryTrace: @escaping @Sendable (
            VideoRecoveryTraceEvent
        ) -> Void = { _ in },
        videoSink: any VideoSink,
        onEvent: @escaping @Sendable (LyteUdpSessionEvent) -> Void
    ) {
        self.crypto = crypto
        self.config = config
        self.clockModel = clockModel
        self.onVideoRecoveryDemand = onVideoRecoveryDemand
        self.onVideoRecoveryTrace = onVideoRecoveryTrace
        self.videoSink = videoSink
        self.onEvent = onEvent
    }

    /// Bind → Noise handshake (blocking, retry timer inside; answers a
    /// retry challenge with the verbatim msg1) → core published →
    /// receive thread → capability declaration as the first reliable
    /// word → timers. Throws TransportCryptoError / TransportEndpointError
    /// on a dial that never became a session.
    ///
    /// The core is built after the handshake (its lifecycle clocks start
    /// at construction) and published before the receive thread starts,
    /// so the host's first datagrams — its declaration and session-start
    /// beacon, sent the moment the session establishes — wait in the
    /// kernel buffer instead of reaching a nil core.
    public func start() throws {
        let endpoint = UdpReceiveEndpoint(
            port: config.bindPort,
            bindAddress: config.bindAddress,
            crypto: crypto,
            onDatagram: { [weak self] outcome, arrivalMicroseconds in
                self?.core?.handleDatagram(
                    outcome, arrivalMicroseconds: arrivalMicroseconds)
            })
        try endpoint.bindAndHandshake()
        self.endpoint = endpoint

        let sender = TransportSender(crypto: crypto, transmit: {
            [weak endpoint] datagram in
            endpoint?.sendToPeer(datagram) ?? false
        })
        let core = LyteUdpSessionCore(
            demux: endpoint.demux,
            sender: sender,
            config: config.core,
            clockModel: clockModel,
            asynchronousVideoBuild: true,
            onVideoRecoveryDemand: onVideoRecoveryDemand,
            onVideoRecoveryTrace: onVideoRecoveryTrace,
            videoSink: videoSink,
            onEvent: onEvent
        )
        coreStorage.withLock { $0 = core }
        endpoint.startReceiving()
        try core.open()
        core.startTimers()

        // Audio out: a refused device is weather, never fatal —
        // the screen must stream even when audio cannot (the host's
        // rule, mirrored). Construction is cheap and synchronous; the
        // engine spin-up goes to the audio queue (see its comment).
        if config.audioPlayback {
            do {
                let player = try LyteAudioPlayer(receiver: core.audio)
                audioPlayer = player
                let onEvent = onEvent
                audioQueue.async {
                    do {
                        try player.start()
                    } catch {
                        onEvent(.protocolNote(
                            "audio playback unavailable (\(error)) — video-only"))
                    }
                }
            } catch {
                onEvent(.protocolNote(
                    "audio playback unavailable (\(error)) — video-only"))
            }
        }
    }

    /// The stream window's mute toggle: playback keeps
    /// consuming (buffer discipline unaffected); only the mixer goes
    /// quiet.
    public func setAudioMuted(_ muted: Bool) {
        audioPlayer?.muted = muted
    }

    /// The strip's host-mute override: asks the host to flip
    /// its OWN speakers. Throws `AudioRoutingAskError.notNegotiated`
    /// when key 9 never survived intersection — the button gating
    /// means the app never hits that; wire-view's flag can.
    public func requestHostAudioRouting(_ mode: HostAudioRoutingMode) throws {
        guard let core else { throw TransportEndpointError.notStarted }
        try core.requestHostAudioRouting(mode)
    }

    /// True when key 9 survived intersection.
    public var hostAudioRoutingNegotiated: Bool {
        core?.hostAudioRoutingNegotiated ?? false
    }

    /// The 0x19-confirmed host-speaker posture, nil before the first
    /// status.
    public var hostAudioRoutingPosture: HostAudioRoutingMode? {
        core?.hostAudioRoutingPosture
    }

    /// True when key 10 survived intersection — the strip's
    /// clipboard toggle exists exactly when this is true.
    public var clipboardNegotiated: Bool {
        core?.clipboardNegotiated ?? false
    }

    /// True when key 11 survived intersection — the host's
    /// standing consent toggle is on; the drop target offers exactly
    /// when this is true.
    public var bulkTransferNegotiated: Bool {
        core?.bulkTransferNegotiated ?? false
    }

    /// The BulkSendCoordinator's chan-8 send leg. Throws
    /// `BulkChannelError.notNegotiated` against a key-11-less host —
    /// the coordinator's own gate means the app never hits that.
    public func sendBulkMessage(_ message: [UInt8]) throws {
        guard let core else { throw TransportEndpointError.notStarted }
        try core.sendBulkMessage(message)
    }

    /// The live clipboard-sharing toggle.
    public var clipboardSharingEnabled: Bool {
        core?.clipboardSharingEnabled ?? false
    }

    public func setClipboardSharing(_ enabled: Bool) {
        core?.setClipboardSharing(enabled)
    }

    /// The pasteboard watcher's funnel: one local clipboard
    /// change through the core's gates. Safe before start (`.sendRefused`).
    @discardableResult
    public func shareLocalClipboard(_ text: String) -> ClipboardShareOutcome {
        core?.shareLocalClipboard(text) ?? .sendRefused("not started")
    }

    /// True when keys 10 and 12 both survived intersection — the
    /// images rung of the consent tier exists exactly when this is.
    public var clipboardImagesNegotiated: Bool {
        core?.clipboardImagesNegotiated ?? false
    }

    /// The images rung's live state (sharing on AND images on).
    public var clipboardImageSharingEnabled: Bool {
        core?.clipboardImageSharingEnabled ?? false
    }

    public func setClipboardImageSharing(_ enabled: Bool) {
        core?.setClipboardImageSharing(enabled)
    }

    /// The pasteboard watcher's image funnel: one local image
    /// copy (PNG bytes) through the core's gates. Safe before start.
    @discardableResult
    public func shareLocalClipboardImage(
        _ data: [UInt8]
    ) -> ClipboardShareOutcome {
        core?.shareLocalClipboardImage(data)
            ?? .sendRefused("not started")
    }

    /// Orderly close: the typed 0x0A on the ordered stream, a linger
    /// for its ACK (≤ the configured window), then teardown. Blocking —
    /// call off the main thread.
    public func close(reason: SessionTeardownReason = .shuttingDown) {
        guard !closing.exchange(true, ordering: .relaxed) else { return }
        orderedInput.finishAndDrain()
        if let core {
            core.beginTeardown(reason: reason)
            let deadline = SystemMonotonicClock.nowNanoseconds
                + UInt64(config.teardownLingerMilliseconds) * 1_000_000
            while !core.isReliableQuiescent,
                  SystemMonotonicClock.nowNanoseconds < deadline
            {
                usleep(20_000)
            }
        }
        stopParts()
    }

    /// The shell's input leg: captured events straight onto the
    /// reliable stream. A refused send (teardown races, mostly) is the
    /// caller's weather — count it, never crash the capture monitor.
    @discardableResult
    public func sendInput(_ body: InputEvent.Body) throws -> UInt32 {
        guard let core else { throw TransportEndpointError.notStarted }
        return try core.sendInput(body)
    }

    /// Renderer-side broken-reference seam. It joins the same coalescing
    /// episode as FEC/repair failures: one immediate 0x10, slow retries,
    /// and no second episode until a usable IRAP reaches the pipeline.
    public func requestVideoRecovery(
        after frame: FrameNumber,
        cause: VideoRecoveryCause = .rendererFailure
    ) {
        core?.requestVideoRecovery(after: frame, cause: cause)
    }

    public func noteVideoIrapEnqueued(
        frame: FrameNumber = FrameNumber(rawValue: 0)
    ) {
        core?.noteVideoIrapEnqueued(frame: frame)
    }

    /// Production UI funnel: capture returns immediately; one dedicated
    /// serial sender preserves event order while ARQ, sealing, and sendto
    /// execute away from MainActor. Jobs observe `closing` before touching
    /// session state, so teardown cannot resurrect a dead sender.
    public func enqueueInput(_ body: InputEvent.Body) {
        orderedInput.enqueue(body)
    }

    public var inputSendTimingSnapshot: InputSendTiming.Snapshot {
        orderedInput.snapshot
    }

    /// Hard stop, no wire goodbye — the path after a peer teardown or
    /// liveness close (the machine is already closed; there is nothing
    /// to say and possibly nobody to say it to).
    public func stop() {
        guard !closing.exchange(true, ordering: .relaxed) else { return }
        stopParts()
    }

    private func stopParts() {
        orderedInput.stop()
        if let player = audioPlayer {
            audioPlayer = nil
            // Serialized behind the async start; never blocks teardown.
            audioQueue.async { player.stop() }
        }
        core?.stopTimers()
        endpoint?.stop()
    }
}
