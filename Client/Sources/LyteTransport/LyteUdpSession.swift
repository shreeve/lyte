// LyteUdpSession: the production shell behind the app's ConnectionModel and
// `lyte-cli wire-view`. It binds the socket, runs the Noise IK handshake
// (answering a retry challenge with the verbatim message 1), publishes a
// LyteUdpSessionCore, starts the receive thread and timers, and runs audio
// playout. Session state and feature calls go through `core`.

import LyteIO
import Dispatch
import Foundation
import LyteWire
import Synchronization

public final class LyteUdpSession: @unchecked Sendable {
    public struct Config: Sendable {
        /// The local bind (0 = kernel-assigned).
        public var bindPort: UInt16 = 0
        public var bindAddress: String = "0.0.0.0"
        public var core = LyteUdpSessionCoreConfig()
        /// How long `close()` waits for the teardown segment's ACK
        /// before tearing the socket down anyway.
        public var teardownLingerMilliseconds = 500
        /// Decode and play the audio channel.
        public var audioPlayback = true

        public init() {}
    }

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
    /// Audio engine start/stop runs here: AVAudioEngine.start() can block
    /// on the HAL, which would wedge a main-actor caller.
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

    /// Bind → handshake (blocking) → core published → capability
    /// declaration → receive thread → timers. Throws TransportCryptoError
    /// or TransportEndpointError when the dial never became a session.
    ///
    /// The core is published and the declaration sent before the receive
    /// thread starts, so the host's first datagrams wait in the kernel
    /// buffer and nothing they provoke precedes the declaration.
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
        try core.open()
        endpoint.startReceiving()
        core.startTimers()

        // A refused audio device is never fatal; the engine spin-up goes
        // to the audio queue.
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

    /// Playback keeps consuming; only the mixer goes quiet.
    public func setAudioMuted(_ muted: Bool) {
        audioPlayer?.muted = muted
    }

    /// Orderly close: the typed 0x0A, a linger for its ACK, then
    /// teardown. Blocking.
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

    /// UI input funnel: returns immediately; one serial sender keeps order
    /// off MainActor, and jobs check `closing` first.
    public func enqueueInput(_ body: InputEvent.Body) {
        orderedInput.enqueue(body)
    }

    /// Hard stop, no wire goodbye (after a peer teardown or liveness close).
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

/// The renderer handoff binds the shell before `start()` publishes a core,
/// so the shell is the recovery peer and routes to the core once it exists.
extension LyteUdpSession: VideoRecoveryPeer {
    /// Joins the same coalesced IDR recovery as FEC/repair failures.
    public func requestVideoRecovery(
        after frame: FrameNumber,
        cause: VideoRecoveryCause
    ) {
        core?.requestVideoRecovery(after: frame, cause: cause)
    }

    public func noteVideoIrapEnqueued(frame: FrameNumber) {
        core?.noteVideoIrapEnqueued(frame: frame)
    }
}
