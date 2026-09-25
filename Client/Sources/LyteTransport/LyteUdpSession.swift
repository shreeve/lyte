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

public final class LyteUdpSession: Sendable {
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

    /// What start() publishes and stopParts() retires, under one lock: once
    /// `stopped` is set nothing new starts, so a stop that races a dial
    /// never misses a thread, a timer or a socket.
    private struct Parts {
        var stopped = false
        var endpoint: UdpReceiveEndpoint?
        var audioPlayer: LyteAudioPlayer?
    }
    private let parts = Mutex(Parts())
    /// Shared with the input sender, which outlives no session.
    private final class CoreBox: Sendable {
        let core = Mutex<LyteUdpSessionCore?>(nil)
    }
    private let coreBox = CoreBox()

    /// The socket; published before the blocking handshake so a stop can
    /// cancel the dial.
    public var endpoint: UdpReceiveEndpoint? {
        parts.withLock { $0.endpoint }
    }
    public var core: LyteUdpSessionCore? {
        coreBox.core.withLock { $0 }
    }
    /// The playback unit, present when `config.audioPlayback`
    /// and the audio device came up.
    public var audioPlayer: LyteAudioPlayer? {
        parts.withLock { $0.audioPlayer }
    }

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
    private let orderedInput: OrderedInputSender

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
        self.orderedInput = OrderedInputSender { [coreBox] body, captured in
            guard let core = coreBox.core.withLock({ $0 }) else {
                throw TransportEndpointError.notStarted
            }
            _ = try core.sendInput(body, captured: captured)
        }
    }

    /// Bind → handshake (blocking) → core published → capability
    /// declaration → receive thread → timers. Throws HandshakeExhausted,
    /// TransportCryptoError or TransportEndpointError when the dial never
    /// became a session (`.cancelled` when stop() or close() ended it).
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
        guard parts.withLock({ parts in
            guard !parts.stopped else { return false }
            parts.endpoint = endpoint
            return true
        }) else { throw TransportEndpointError.cancelled }

        let core: LyteUdpSessionCore
        do {
            try endpoint.bindAndHandshake()
            let sender = TransportSender(crypto: crypto, transmit: {
                [weak endpoint] datagram in
                endpoint?.sendToPeer(datagram) ?? false
            })
            core = LyteUdpSessionCore(
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
            coreBox.core.withLock { $0 = core }
            try core.open()
        } catch {
            endpoint.stop()
            throw error
        }
        guard parts.withLock({ parts in
            guard !parts.stopped else { return false }
            endpoint.startReceiving()
            core.startTimers()
            return true
        }) else {
            endpoint.stop()
            throw TransportEndpointError.cancelled
        }

        // A refused audio device is never fatal; the engine spin-up goes
        // to the audio queue.
        if config.audioPlayback {
            do {
                let player = try LyteAudioPlayer(receiver: core.audio)
                guard parts.withLock({ parts in
                    guard !parts.stopped else { return false }
                    parts.audioPlayer = player
                    return true
                }) else { return }
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
        let (endpoint, player) = parts.withLock { parts in
            parts.stopped = true
            defer { parts.audioPlayer = nil }
            return (parts.endpoint, parts.audioPlayer)
        }
        if let player {
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

    public func noteVideoIrapEnqueued(
        frame: FrameNumber, closesRecovery: Bool
    ) {
        core?.noteVideoIrapEnqueued(
            frame: frame, closesRecovery: closesRecovery)
    }

    public func ensureVideoRecoveryOpen(
        after frame: FrameNumber, cause: VideoRecoveryCause
    ) {
        core?.ensureVideoRecoveryOpen(after: frame, cause: cause)
    }
}

extension LyteUdpSession {
    /// A session rendering through `handoff`, bound as its recovery peer,
    /// with its recovery trace in the handoff's flight recorder.
    public convenience init(
        crypto: any TransportCrypto, config: Config,
        handoff: VideoRendererHandoff,
        onEvent: @escaping @Sendable (LyteUdpSessionEvent) -> Void
    ) {
        self.init(
            crypto: crypto, config: config, clockModel: handoff.clockModel,
            onVideoRecoveryDemand: { [weak handoff] cause, frame in
                handoff?.beginRecovery(cause: cause, after: frame)
            },
            onVideoRecoveryTrace: { [recorder = handoff.recorder] event in
                recorder.recordRecoveryLifecycle(
                    kind: event.kind, frame: event.frame.rawValue,
                    cause: event.cause, isRandomAccess: event.isRandomAccess)
            },
            videoSink: handoff, onEvent: onEvent)
        handoff.bind(self)
    }
}
