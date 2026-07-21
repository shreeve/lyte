import AppKit
import ArgumentParser
@preconcurrency import AVFoundation
import Foundation
import LyteTransport
import LyteUI
import LyteWire

/// CL-2: wire-listen grows eyes. Binds a Lyte-UDP receive endpoint,
/// assembles the video channel through LyteVideoPipeline, and renders it
/// into an AVSampleBufferDisplayLayer window — the H0b debug harness's
/// video leg. Prints the CL-1 demux stats plus per-frame render stats.
///
/// AppKit rule (HANDOFF, hard-won): NSApplication.run() must own the raw
/// C main thread — Main.main treats every subcommand not on its non-UI
/// list as a UI command, so this file only has to keep its `run()` off
/// the main-thread-blocking paths and let the window live.
struct WireView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wire-view",
        abstract: "Render an incoming Lyte-UDP video stream in a window (wire-listen + eyes).")

    @Argument(help: "UDP port to bind (0 picks a free port)") var port: UInt16
    @Option(name: .long, help: "Address to bind") var bind: String = "0.0.0.0"
    @Flag(name: .long, help: "CP-3 recorded fallback: accept payloads with NO crypto (until W5 lands)")
    var insecure = false
    @Option(name: .long, help: "Auto-exit after this many seconds (default: until the window closes)")
    var duration: Int = 0

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer even when piped

        let crypto: any TransportCrypto = insecure
            ? InsecureTransportCrypto() : NoiseTransportCrypto()

        // Window + display layer first (main thread, before datagrams).
        let nsApp = NSApplication.shared
        nsApp.setActivationPolicy(.regular)

        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        let renderer = displayLayer.sampleBufferRenderer

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Lyte — wire-view :\(port)"
        window.collectionBehavior.insert(.fullScreenPrimary)
        let videoView = VideoLayerView(layer: displayLayer)
        window.contentView = videoView
        window.center()

        // The render path: assembled DecodeUnits become samples on the
        // receive thread and enqueue straight into the layer's renderer
        // (present-ASAP; the frozen stack enqueues from its receive
        // thread the same way).
        let pipeline = LyteVideoPipeline(
            onSample: { sample, _ in
                renderer.enqueue(sample)
            },
            onFecImpossible: { frame, lostData, bestParity in
                // CL-3's IDR-request seam — today it only testifies.
                print("wire-view: frame \(frame.rawValue) FEC-IMPOSSIBLE " +
                      "(\(lostData) data shards presumed lost, best-case parity \(bestParity)) " +
                      "— CL-3 will request an IDR here")
            })
        pipeline.start()

        let endpoint = UdpReceiveEndpoint(
            port: port, bindAddress: bind, crypto: crypto,
            onDatagram: { outcome in
                if case .accepted(let envelope, let payload) = outcome {
                    pipeline.ingest(envelope: envelope, payload: payload)
                }
            })
        do {
            try endpoint.start()
        } catch let error as TransportCryptoError {
            if case .noisePending(let message) = error {
                throw ValidationError(message)
            }
            throw error
        }
        print("wire-view: bound \(bind):\(endpoint.boundPort) — \(crypto.modeDescription)")
        if insecure {
            print("wire-view: *** INSECURE MODE — payloads are neither encrypted nor authenticated ***")
        }

        // The renderer's own verdict is the honest render evidence: it
        // goes .failed (with the VideoToolbox error) if enqueued samples
        // don't actually decode — enqueue counts alone can't lie-detect.
        let printer = WireViewStatsPrinter(
            demux: endpoint.demux, pipeline: pipeline,
            rendererState: { @Sendable in
                switch renderer.status {
                case .rendering: return "rendering"
                case .failed: return "FAILED: \(String(describing: renderer.error))"
                default: return "idle"
                }
            })

        let ticker = DispatchSource.makeTimerSource(queue: .global())
        ticker.schedule(deadline: .now() + 1, repeating: 1)
        // @Sendable, explicitly: closures born in a @MainActor run()
        // inherit MainActor isolation, and a dispatch timer calling one
        // off-main traps (dispatch_assert_queue) at the first tick.
        ticker.setEventHandler { @Sendable in printer.printTick() }
        ticker.resume()

        // Idempotent, and named: three paths converge here and the smoke
        // evidence must say which one ended the run.
        let finished = LockedCell(false)
        let finish: @Sendable (String) -> Void = { trigger in
            let already = finished.value
            finished.value = true
            guard !already else { return }
            print("wire-view: finishing (\(trigger))")
            ticker.cancel()
            endpoint.stop()
            pipeline.stop()
            printer.printFinal()
            // exit(0) inline from windowWillClose can hang in AppKit
            // teardown; a global-queue hop exits cleanly from every path.
            DispatchQueue.global().async { Foundation.exit(0) }
        }

        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler { @Sendable in finish("SIGINT") }
        sigint.resume()

        let delegate = WindowCloser(onClose: { finish("window closed") })
        window.delegate = delegate
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(videoView)
        nsApp.activate(ignoringOtherApps: true)

        if duration > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(duration)) {
                finish("duration \(duration)s elapsed")
            }
        }

        // NSApplication.run() owns the main thread (Main.main) — keep
        // strong refs to everything AppKit only holds weakly and return.
        streamRetainer.append(contentsOf: [delegate, ticker, sigint, endpoint, pipeline, window])
    }
}

/// The CL-1 demux stats plus the CL-2 render stats, one tick per second
/// with new arrivals, full summary at exit.
final class WireViewStatsPrinter: Sendable {
    private let demux: ReceiveDemux
    private let pipeline: LyteVideoPipeline
    private let rendererState: @Sendable () -> String
    private let lastCount = LockedCell<UInt64>(0)

    init(demux: ReceiveDemux, pipeline: LyteVideoPipeline,
         rendererState: @escaping @Sendable () -> String) {
        self.demux = demux
        self.pipeline = pipeline
        self.rendererState = rendererState
    }

    func printTick() {
        let totals = demux.snapshotTotals()
        guard totals.datagrams != lastCount.value else { return }
        lastCount.value = totals.datagrams
        printSnapshot(prefix: "…", totals: totals)
    }

    func printFinal() {
        print("wire-view: final")
        printSnapshot(prefix: "  ", totals: demux.snapshotTotals())
    }

    private func printSnapshot(prefix: String, totals: DemuxTotals) {
        var line = "\(prefix) total \(totals.datagrams) datagrams: \(totals.accepted) ok"
        if totals.malformed > 0 { line += ", \(totals.malformed) malformed" }
        if totals.reservedDropped > 0 { line += ", \(totals.reservedDropped) reserved-dropped" }
        if totals.unsealFailures > 0 { line += ", \(totals.unsealFailures) unseal-failed" }
        print(line)
        if let video = demux.stats(forChannel: pipeline.channel.rawValue) {
            print("\(prefix)   wire: \(video.datagrams) dg, \(video.payloadBytes) B, " +
                  "\(video.seqMissing) missing, \(video.seqDuplicates) dup")
        }
        let s = pipeline.snapshotStats()
        var render = "\(prefix)   render: \(s.framesDecoded) decoded, \(s.framesSkipped) skipped, " +
                     "\(s.samplesDelivered) enqueued"
        if s.samplesWithheld > 0 { render += ", \(s.samplesWithheld) withheld (pre-IDR)" }
        if s.sampleFailures > 0 { render += ", \(s.sampleFailures) sample-failed" }
        if s.fecImpossibleCount > 0 { render += ", \(s.fecImpossibleCount) fec-impossible" }
        if s.evictions > 0 { render += ", \(s.evictions) evicted" }
        if s.shardsDropped > 0 { render += ", \(s.shardsDropped) shards dropped" }
        if let first = s.firstSampleMicroseconds {
            render += String(format: " | first frame %.1fms", Double(first) / 1000)
        }
        render += " | layer \(rendererState())"
        print(render)
    }
}

/// Lock-boxed value for cross-queue state (WireListen's LockedBox
/// sibling; file-private types don't travel between files).
final class LockedCell<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
