import AppKit
import ArgumentParser
@preconcurrency import AVFoundation
import Foundation
import LyteKit
import LyteHelperProtocol
import LyteUI

/// Borrow the app-registered AWDL helper daemon if it's on this machine
/// (Lyte.app registers it; approval in System Settings). Silent no-op when
/// absent — the CLI falls back to Scripts/awdl-quiet.sh.
enum HelperBridge {
    nonisolated(unsafe) private static var connection: NSXPCConnection?
    static var isEngaged: Bool { connection != nil }

    static func engage() -> Bool {
        let c = NSXPCConnection(machServiceName: LyteHelper.machServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: LyteHelperCommands.self)
        c.resume()
        // XPC proxies are optimistic: they exist even when no daemon does,
        // and messages vanish silently. Demand a version() round-trip before
        // believing anything.
        let sema = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var alive = false
        guard let proxy = c.remoteObjectProxyWithErrorHandler({ _ in sema.signal() })
                as? LyteHelperCommands else {
            c.invalidate()
            return false
        }
        proxy.version { _ in
            alive = true
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 1.0)
        guard alive else {
            c.invalidate()
            return false
        }
        proxy.streamBegan()
        connection = c
        return true
    }

    static func disengage() {
        guard let c = connection else { return }
        (c.remoteObjectProxy as? LyteHelperCommands)?.streamEnded()
        c.invalidate()
        connection = nil
    }
}

struct Stream: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stream an app to a window — video, audio, and input (the default subcommand: `lyte-cli pop` streams pop's desktop).")

    @Argument(help: "Host: Bonjour name, hostname, or IP") var host: String
    @Argument(help: "App on the host (default: the desktop)") var app: String = "Desktop"
    @Option(name: .long) var width: Int = 2048
    @Option(name: .long) var height: Int = 1280
    @Option(name: .long) var fps: Int = 60
    @Option(name: .long, help: "Bitrate in Kbps") var bitrate: Int = 40000
    @Option(name: .long, help: "Auto-quit after this many seconds (default: stream until the window closes)") var duration: Int = 0

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer even when piped
        let address = await HostAddress.resolve(host)
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

        let session = LyteSession(context: context, displayLayer: displayLayer) { event in
            switch event {
            case .log(let line): print(line); fflush(stdout)
            case .connected: print("control: connected"); fflush(stdout)
            case .terminated(let reason):
                print("session TERMINATED — \(reason)"); fflush(stdout)
                Foundation.exit(1)
            }
        }
        let cleanup: @Sendable () -> Void = {
            HelperBridge.disengage()
            session.stop()
            let s = session.stats
            print("stats: \(s.videoPackets) pkts, \(s.videoFrames) frames, " +
                  "\(s.videoRecovered) FEC-recovered pkts, \(s.videoFramesLost) lost frames")
        }

        do {
            try await session.start()
        } catch {
            cleanup()
            throw error
        }
        print("session live — streaming\(duration > 0 ? " for \(duration)s" : "") (close window to stop)")
        if HelperBridge.engage() {
            print("awdl: helper engaged — radio quiet for this stream")
        }

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
        let doctor = Doctor()
        let lastHeadline = Locked("")
        let printStats: @Sendable () -> Void = {
            let diagnosis = doctor.sample(session.stats, helperEngaged: HelperBridge.isEngaged)
            if diagnosis.headline != lastHeadline.value, diagnosis.headline != "Measuring…" {
                lastHeadline.value = diagnosis.headline
                print("doctor: \(diagnosis.headline)")
                diagnosis.evidence.forEach { print("        · \($0)") }
                diagnosis.fixes.forEach { print("        → \($0)") }
            }
            let s = session.stats
            var line = "… \(s.videoFrames) frames, \(s.videoPackets) pkts, " +
                       "\(s.videoRecovered) recovered, \(s.videoFramesLost) lost, " +
                       "\(s.framesEnqueued) enqueued, \(s.framesSkipped) skipped"
            if s.hasAudio {
                line += " | audio: \(s.audioFrames) frames, \(s.audioRecovered) FEC, " +
                        "\(s.audioLost) lost, \(s.audioUnderruns) underruns, \(s.audioQueuedMs)ms buffered" +
                        " | radio gaps: \(s.audioGapsOver20ms)>20ms \(s.audioGapsOver50ms)>50ms max \(s.audioMaxGapMs)ms"
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


/// Tiny lock-boxed value for cross-queue closures.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class WindowCloser: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

/// Strong refs for objects whose owners (NSApp, NSWindow) hold them weakly,
/// alive for the life of the process.
@MainActor var streamRetainer: [Any] = []
