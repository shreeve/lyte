import AppKit
import ArgumentParser
@preconcurrency import AVFoundation
import Foundation
import LyteKit

struct Stream: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stream an app to a window (M3: HEVC video, no input/audio yet).")

    @Argument(help: "Host address (IP or name)") var address: String
    @Argument(help: "App name (e.g. Desktop) or numeric ID") var app: String = "Desktop"
    @Option(name: .long) var width: Int = 2048
    @Option(name: .long) var height: Int = 1280
    @Option(name: .long) var fps: Int = 60
    @Option(name: .long, help: "Bitrate in Kbps") var bitrate: Int = 40000
    @Option(name: .long, help: "Seconds to stream (0 = until window closes)") var duration: Int = 30

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer even when piped
        let store = ClientStore.load()
        guard let host = store.host(address), let pinned = host.serverCertDER,
              let identity = store.identity() else {
            throw ValidationError("Not paired with \(address).")
        }
        let client = HostClient(address: address, uniqueID: store.uniqueID,
                                identity: identity, pinnedServerCertDER: pinned)

        let apps = try await client.appList()
        guard let target = apps.first(where: { $0.title.caseInsensitiveCompare(app) == .orderedSame || $0.id == app }) else {
            throw ValidationError("App not found. Available: \(apps.map(\.title).joined(separator: ", "))")
        }

        let info = try await client.serverInfo(https: true)
        let context: StreamContext
        if let current = info.currentGame, current != "0", !current.isEmpty {
            print("Host busy (app \(current)) — resuming")
            context = try await client.resume(appID: target.id, width: width, height: height,
                                              fps: fps, bitrateKbps: bitrate)
        } else {
            context = try await client.launch(appID: target.id, width: width, height: height,
                                              fps: fps, bitrateKbps: bitrate)
        }
        print("launched \(target.title): \(context.rtspSessionURL)")

        // Window + display layer (main thread, before the session goes live)
        let nsApp = NSApplication.shared
        nsApp.setActivationPolicy(.regular)

        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)

        let contentRect = NSRect(x: 0, y: 0,
                                 width: CGFloat(width) / 2, height: CGFloat(height) / 2)
        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Lyte — \(target.title) on \(address)"
        window.collectionBehavior.insert(.fullScreenPrimary)   // enables Enter Full Screen
        let videoView = VideoLayerView(layer: displayLayer)
        window.contentView = videoView
        window.center()

        let session = StreamSession(context: context, displayLayer: displayLayer)
        let cleanup: @Sendable () -> Void = {
            session.stop()
            let s = session.stats()
            print("stats: \(s.packets) pkts, \(s.frames) frames, " +
                  "\(s.recovered) FEC-recovered pkts, \(s.lostFrames) lost frames")
        }

        do {
            try await session.start()
        } catch {
            cleanup()
            throw error
        }
        print("session live — streaming\(duration > 0 ? " for \(duration)s" : "") (close window to stop)")

        let delegate = WindowCloser(onClose: {
            cleanup()
            Foundation.exit(0)
        })
        window.delegate = delegate
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(videoView)
        nsApp.activate(ignoringOtherApps: true)

        let input = InputCapture(view: videoView, window: window) { packet, channel in
            session.sendInput(packet, channel: channel)
        }
        input.start()

        // Debug: LYTE_INPUT_TEST=1 sweeps the host cursor diagonally and
        // right-clicks — verifies the input wire format end-to-end (the host's
        // rendered cursor + context menu appear in the video).
        if ProcessInfo.processInfo.environment["LYTE_INPUT_TEST"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                for i in 0...20 {
                    let p = InputPacket.mouseMoveAbsolute(x: Int16(100 + i * 40), y: Int16(100 + i * 22),
                                                          width: 1024, height: 640)
                    session.sendInput(p, channel: InputPacket.channelMouse)
                    try? await Task.sleep(for: .milliseconds(40))
                }
                session.sendInput(InputPacket.mouseButton(down: true, button: .right),
                                  channel: InputPacket.channelMouse)
                try? await Task.sleep(for: .milliseconds(120))
                session.sendInput(InputPacket.mouseButton(down: false, button: .right),
                                  channel: InputPacket.channelMouse)
                print("input-test: sweep + right-click sent")
            }
        }

        // Exit timer and stats ticker live off the main queue so they fire
        // regardless of what the AppKit run loop is doing.
        if duration > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(duration)) {
                cleanup()
                Foundation.exit(0)
            }
        }
        let ticker = DispatchSource.makeTimerSource(queue: .global())
        ticker.schedule(deadline: .now() + 5, repeating: 5)
        let printStats: @Sendable () -> Void = {
            let s = session.stats()
            var line = "… \(s.frames) frames, \(s.packets) pkts, " +
                       "\(s.recovered) recovered, \(s.lostFrames) lost, " +
                       "\(session.diag.enqueued) enqueued, \(session.diag.skipped) skipped"
            if let a = session.audioStats() {
                line += " | audio: \(a.decoded) frames, \(a.recovered) FEC, " +
                        "\(a.lost) lost, \(a.underruns) underruns, \(a.queuedMs)ms buffered, " +
                        String(format: "peak %.2f", a.peak)
            }
            print(line)
        }
        ticker.setEventHandler(handler: printStats)
        ticker.resume()

        // NSApplication.run() is already live on the raw main thread (see
        // Main.main) — returning here leaves the session streaming until an
        // exit path fires (window close / duration timer). Keep strong
        // references to everything AppKit only holds weakly.
        let menu = AppMenuController(window: window, session: session, input: input,
                                     streamSize: NSSize(width: width, height: height))
        menu.install()

        streamRetainer.append(contentsOf: [delegate, ticker, session, window, input, menu])
    }
}

/// Everything that keeps an M3 session alive: RTSP handshake, control channel,
/// audio pinger, video stream → sample factory → display layer.
final class StreamSession: @unchecked Sendable {
    private let context: StreamContext
    private let displayLayer: AVSampleBufferDisplayLayer

    private var video: VideoStream?
    private var control: ControlChannel?
    private var audio: AudioStream?
    private let factory = VideoSampleFactory(codec: .hevc)
    let diag = RenderDiagnostics()

    init(context: StreamContext, displayLayer: AVSampleBufferDisplayLayer) {
        self.context = context
        self.displayLayer = displayLayer
    }

    func start() async throws {
        let renderer = displayLayer.sampleBufferRenderer
        let controlBox = ControlBox()

        // M3 is HEVC-only; force it in negotiation
        let handshake = RtspHandshake(context: context, preferredCodecs: [.hevc])
        let params = try await handshake.perform(onPortsKnown: { [self] audioPort, videoPort, audioPing, videoPing in
            // Sunshine learns our RTP address from these pings, and the video
            // ping socket is the video receive socket — so both must start
            // before PLAY.
            if let audioPing,
               let a = AudioStream(host: context.localAddress, port: audioPort,
                                   pingPayload: audioPing,
                                   riKey: context.riKey, riKeyId: context.riKeyID) {
                try? a.startPinging()   // must ping before PLAY
                audio = a
            }
            let v = VideoStream(
                host: context.localAddress, port: videoPort,
                pingPayload: videoPing ?? Data(count: 16),
                codec: .hevc, packetSize: context.packetSize,
                onDecodeUnit: { [factory, diag] du in
                    if renderer.requiresFlushToResumeDecoding {
                        diag.note("renderer required flush (status \(renderer.status.rawValue), error: \(String(describing: renderer.error)))")
                        renderer.flush()
                        controlBox.control?.requestIdrFrame()
                        return
                    }
                    do {
                        if let sample = try factory.makeSampleBuffer(from: du) {
                            renderer.enqueue(sample)
                            diag.enqueued += 1
                            if renderer.status == .failed {
                                diag.note("renderer FAILED after enqueue: \(String(describing: renderer.error))")
                            }
                        } else {
                            diag.skipped += 1
                        }
                    } catch {
                        diag.note("sample factory error: \(error)")
                    }
                },
                onRequestIdr: { controlBox.control?.requestIdrFrame() },
                onTerminate: { reason in
                    print("video: TERMINATED — \(reason)")
                    Foundation.exit(1)
                })
            try? v.start()
            video = v
        }, log: { print("rtsp: \($0)"); fflush(stdout) })

        let control = try ControlChannel(
            host: context.localAddress, port: params.controlPort,
            connectData: params.controlConnectData, riKey: context.riKey,
            encryptionEnabled: params.encryptionEnabled | SSEnc.controlV2
        ) { event in
            switch event {
            case .connected: print("control: connected")
            case .hostMessage: break
            case .terminated(let code):
                print("control: TERMINATED by host, code \(code)")
                Foundation.exit(1)
            case .disconnected: print("control: disconnected")
            }
            fflush(stdout)
        }
        try control.start()
        self.control = control
        controlBox.control = control

        // Audio playback starts once encryption negotiation is known
        if let audio {
            try audio.start(encrypted: params.encryptionEnabled & SSEnc.audio != 0)
        }
    }

    func stop() {
        video?.stop()
        control?.stop()
        audio?.stop()
    }

    func sendInput(_ packet: Data, channel: UInt8) {
        control?.sendInput(packet, channel: channel)
    }

    func requestIdr() {
        control?.requestIdrFrame()
    }

    func setAudioMuted(_ muted: Bool) {
        audio?.setMuted(muted)
    }

    func stats() -> (packets: UInt64, frames: UInt64, recovered: UInt64, lostFrames: UInt64) {
        guard let video else { return (0, 0, 0, 0) }
        return (video.packetsReceived, video.framesDelivered,
                video.packetsRecovered, video.framesLost)
    }

    func audioStats() -> (decoded: UInt64, recovered: UInt64, lost: UInt64,
                          underruns: UInt64, queuedMs: Int, peak: Float)? {
        guard let audio else { return nil }
        return (audio.framesDecoded, audio.packetsRecovered, audio.packetsLost,
                audio.underruns, audio.queuedMs, audio.peak)
    }
}

/// Control channel becomes available only after the RTSP handshake that the
/// video stream starts inside of — late-bind it.
final class ControlBox: @unchecked Sendable {
    var control: ControlChannel?
}

/// Rendering counters + de-duplicated one-shot notes (receive-thread written).
final class RenderDiagnostics: @unchecked Sendable {
    var enqueued: UInt64 = 0
    var skipped: UInt64 = 0
    private var seen = Set<String>()
    private let lock = NSLock()

    func note(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let key = String(message.prefix(40))
        guard !seen.contains(key) else { return }
        seen.insert(key)
        print("render: \(message)")
    }
}

final class VideoLayerView: NSView {
    init(layer: AVSampleBufferDisplayLayer) {
        super.init(frame: .zero)
        // Layer-hosting view: the layer MUST be set before wantsLayer,
        // otherwise AppKit treats it as layer-backed and swaps in its own.
        self.layer = layer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // Terminate key events silently: anything not consumed by InputCapture's
    // monitor (or a menu) would otherwise fall off the responder chain and
    // trigger NSBeep on every keystroke.
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
}

final class WindowCloser: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

/// Strong refs for objects whose owners (NSApp, NSWindow) hold them weakly,
/// alive for the life of the process.
@MainActor var streamRetainer: [Any] = []
