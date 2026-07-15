import Foundation
@preconcurrency import AVFoundation

/// One streaming connection: RTSP handshake → video (RTP→FEC→HEVC→display
/// layer), audio (RTP→FEC→Opus→speakers), ENet control channel, input send.
/// One instance per connection — no process-global state (PLAN §3).
///
/// UI-agnostic: renders into the AVSampleBufferDisplayLayer it is given and
/// reports everything else through `onEvent`.
public final class LyteSession: @unchecked Sendable {
    public enum Event: Sendable {
        case log(String)                    // handshake progress, diagnostics
        case connected                      // control channel established
        case terminated(reason: String)     // session ended (host or transport)
    }

    public struct Stats: Sendable {
        public var videoPackets: UInt64 = 0
        public var videoFrames: UInt64 = 0
        public var videoRecovered: UInt64 = 0
        public var videoFramesLost: UInt64 = 0
        public var framesEnqueued: UInt64 = 0
        public var framesSkipped: UInt64 = 0
        public var audioFrames: UInt64 = 0
        public var audioRecovered: UInt64 = 0
        public var audioLost: UInt64 = 0
        public var audioUnderruns: UInt64 = 0
        public var audioQueuedMs: Int = 0
        public var audioPeak: Float = 0
        public var hasAudio = false
    }

    private let context: StreamContext
    private let displayLayer: AVSampleBufferDisplayLayer
    private let codec: VideoStream.Codec
    private let onEvent: @Sendable (Event) -> Void

    private var video: VideoStream?
    private var control: ControlChannel?
    private var audio: AudioStream?
    private let factory: VideoSampleFactory

    // Render counters (receive-thread written) + de-duplicated one-shot notes
    private var enqueued: UInt64 = 0
    private var skipped: UInt64 = 0
    private var notedKeys = Set<String>()
    private let noteLock = NSLock()

    public init(context: StreamContext, displayLayer: AVSampleBufferDisplayLayer,
                codec: VideoStream.Codec = .hevc,
                onEvent: @escaping @Sendable (Event) -> Void) {
        self.context = context
        self.displayLayer = displayLayer
        self.codec = codec
        self.onEvent = onEvent
        self.factory = VideoSampleFactory(codec: codec == .hevc ? .hevc : .h264)
    }

    public func start() async throws {
        let renderer = displayLayer.sampleBufferRenderer
        let controlBox = ControlBox()

        let handshake = RtspHandshake(context: context, preferredCodecs: [codec == .hevc ? .hevc : .h264])
        let params = try await handshake.perform(onPortsKnown: { [self] audioPort, videoPort, audioPing, videoPing in
            // Sunshine learns our RTP address from these pings, and the video
            // ping socket is the video receive socket — both start before PLAY.
            if let audioPing,
               let a = AudioStream(host: context.localAddress, port: audioPort,
                                   pingPayload: audioPing,
                                   riKey: context.riKey, riKeyId: context.riKeyID) {
                try? a.startPinging()
                audio = a
            }
            let v = VideoStream(
                host: context.localAddress, port: videoPort,
                pingPayload: videoPing ?? Data(count: 16),
                codec: codec, packetSize: context.packetSize,
                onDecodeUnit: { [self] du in
                    if renderer.requiresFlushToResumeDecoding {
                        note("renderer required flush (status \(renderer.status.rawValue))")
                        renderer.flush()
                        controlBox.control?.requestIdrFrame()
                        return
                    }
                    do {
                        if let sample = try factory.makeSampleBuffer(from: du) {
                            renderer.enqueue(sample)
                            enqueued &+= 1
                            if renderer.status == .failed {
                                note("renderer FAILED after enqueue: \(String(describing: renderer.error))")
                            }
                        } else {
                            skipped &+= 1
                        }
                    } catch {
                        note("sample factory error: \(error)")
                    }
                },
                onRequestIdr: { controlBox.control?.requestIdrFrame() },
                onTerminate: { [onEvent] reason in
                    onEvent(.terminated(reason: "video: \(reason)"))
                })
            try? v.start()
            video = v
        }, log: { [onEvent] in onEvent(.log("rtsp: \($0)")) })

        let control = try ControlChannel(
            host: context.localAddress, port: params.controlPort,
            connectData: params.controlConnectData, riKey: context.riKey,
            encryptionEnabled: params.encryptionEnabled | SSEnc.controlV2
        ) { [onEvent] event in
            switch event {
            case .connected: onEvent(.connected)
            case .hostMessage: break
            case .terminated(let code): onEvent(.terminated(reason: "host ended session (code \(code))"))
            case .disconnected: onEvent(.terminated(reason: "control channel disconnected"))
            }
        }
        try control.start()
        self.control = control
        controlBox.control = control

        // Audio playback starts once encryption negotiation is known
        if let audio {
            try audio.start(encrypted: params.encryptionEnabled & SSEnc.audio != 0)
        }
    }

    public func stop() {
        video?.stop()
        control?.stop()
        audio?.stop()
    }

    // MARK: - Controls

    public func sendInput(_ packet: Data, channel: UInt8) {
        control?.sendInput(packet, channel: channel)
    }

    public func requestIdr() {
        control?.requestIdrFrame()
    }

    public func setAudioMuted(_ muted: Bool) {
        audio?.setMuted(muted)
    }

    // MARK: - Stats

    public var stats: Stats {
        var s = Stats()
        if let video {
            s.videoPackets = video.packetsReceived
            s.videoFrames = video.framesDelivered
            s.videoRecovered = video.packetsRecovered
            s.videoFramesLost = video.framesLost
        }
        s.framesEnqueued = enqueued
        s.framesSkipped = skipped
        if let audio {
            s.hasAudio = true
            s.audioFrames = audio.framesDecoded
            s.audioRecovered = audio.packetsRecovered
            s.audioLost = audio.packetsLost
            s.audioUnderruns = audio.underruns
            s.audioQueuedMs = audio.queuedMs
            s.audioPeak = audio.peak
        }
        return s
    }

    private func note(_ message: String) {
        noteLock.lock()
        let key = String(message.prefix(40))
        let fresh = notedKeys.insert(key).inserted
        noteLock.unlock()
        if fresh { onEvent(.log("render: \(message)")) }
    }
}

/// Control channel becomes available only after the RTSP handshake that the
/// video stream starts inside of — late-bind it.
final class ControlBox: @unchecked Sendable {
    var control: ControlChannel?
}
