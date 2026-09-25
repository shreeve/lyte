import AppKit
import ArgumentParser
@preconcurrency import AVFoundation
import Foundation
import LyteClientCore
import LyteCore
import LyteIO
import LyteClientSession
import LyteTransport
import LyteUI
import LyteWire
import Synchronization

/// The debug shell around the app's own streaming objects: the same
/// LyteUdpSession and the same VideoRendererHandoff the app's
/// ConnectionModel drives, in a bare window, with every session event and
/// a per-second stats snapshot printed. Typed teardown runs both ways:
/// 0x0A out on ⌃C, window close, or --duration; 0x0A in ends the run with
/// the host's reason.
///
/// NSApplication.run() must own the raw C main thread (Main.main hands it
/// over for this subcommand), so `run()` stays off main-thread-blocking
/// paths and lets the window live.
struct WireView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wire-view",
        abstract: "Stream from a Lyte-UDP host into a debug window, printing session events and stats.")

    @Argument(help: "UDP port to bind (0 picks a free port; also the host's listen port unless --host-port)") var port: UInt16
    @Option(name: .long, help: "Address to bind") var bind: String = "0.0.0.0"
    @Option(name: .long, help: "The host's static public key, 64 hex digits (printed by lyte-host at start). Omit it once paired — the pinned key + Keychain identity take over")
    var hostKey: String?
    @Option(name: .long, help: "The host's address or pinned name (default: the only pinned host)")
    var host: String?
    @Option(name: .long, help: "Noise mode: the host's --wire-listen port (default: the bind port)")
    var hostPort: UInt16 = 0
    @Option(name: .long, help: "Auto-exit after this many seconds (default: until the window closes)")
    var duration: Int = 0
    @Flag(name: .long, help: "Decode + play the audio channel (AVAudioEngine) and print the audio stats line")
    var audio = false
    @Option(name: .long, help: "The session-start posture for the HOST's own speakers — audible|muted. Needs capability key 9 on both ends; against a no-key-9 host the ask is refused client-side (that refusal is the evidence). Omitted = NEUTRAL: take the host's default without asking (the debug-shell posture; the app asks for muted)")
    var hostAudio: String?
    @Flag(name: .long, help: "Share the clipboard (UTF-8 text, both ways) — real NSPasteboard glue behind the sans-IO core's gates. Needs capability key 10 on both ends; against a no-key-10 host every local copy reports notNegotiated (that refusal is the evidence). Payloads are never printed — byte counts only")
    var clipboard = false
    @Flag(name: .long, help: "The images rung on top of --clipboard (the Text + images tier) — clipboard PNGs ride chan 8 as 0x22 cargo, both ways. Needs keys 10 AND 12 on both ends (a --clipboard=text host declines with abort). Byte counts only, as ever")
    var clipboardImages = false
    @Option(name: .long, help: "The chroma tier this client DECLARES — 420 (Good, the default) or 444 (Best). Declaration-as-choice: the singleton is the ask; a host without the tier answers the typed noCommonChromaMode teardown (that refusal is the harness's fallback evidence — the debug shell never auto-re-dials; the app does)")
    var chroma: String = "420"

    func validate() throws {
        if let hostAudio, Self.parseHostAudio(hostAudio) == nil {
            throw ValidationError("--host-audio wants audible|muted, got '\(hostAudio)'")
        }
        if Self.parseChroma(chroma) == nil {
            throw ValidationError("--chroma wants 420|444, got '\(chroma)'")
        }
    }

    /// The dial target: --host as given, else the one pinned host.
    private func resolvedHost() throws -> String {
        if let host { return host }
        let pinned = PinnedHostStore.load().hosts.values
        guard pinned.count == 1, let only = pinned.first else {
            throw ValidationError(pinned.isEmpty
                ? "no host: pass --host (nothing is pinned)"
                : "--host is required: \(pinned.count) hosts are pinned")
        }
        return only.address
    }

    static func parseHostAudio(_ word: String) -> HostAudioRoutingMode? {
        switch word {
        case "audible": return .hostAudible
        case "muted": return .hostMuted
        default: return nil
        }
    }

    static func parseChroma(_ word: String) -> ChromaTier? {
        switch word {
        case "420": return .good
        case "444": return .best
        default: return nil
        }
    }

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer even when piped

        // App Nap throttles a locked-screen session into garbage evidence
        // (recenter storms, nonsense delivery samples): a live media
        // session is latency-critical for exactly as long as it runs.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "wire-view live session")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let host = try resolvedHost()
        let crypto: any TransportCrypto
        if let hostKey {
            // Explicit key: a throwaway client static (a --require-paired
            // host refuses it by design).
            crypto = try NoiseTransportCrypto(
                hostAddress: host,
                hostPort: hostPort == 0 ? port : hostPort,
                hostStaticPublicKey: NoiseTransportCrypto.parseKeyHex(hostKey))
        } else {
            // No key argued: the pinned store supplies the host static and
            // the Keychain our persistent identity — plain 1-RTT Noise IK.
            // --host may name the pin; the dial goes to its address.
            guard let pinned = PinnedHostStore.load().host(address: host),
                  let key = pinned.staticPublicKey
            else {
                throw ValidationError(
                    "\(host) is not paired — run `lyte-cli wire-pair \(host) --pin <PIN>` first or pass --host-key <64-hex> for a one-off")
            }
            let identity: NoiseKeyPair
            do {
                identity = try await ClientNoiseIdentityProvider.shared.identity()
            } catch ClientNoiseIdentityError.keychain(let status) {
                throw ValidationError(
                    "Keychain refused the client identity (OSStatus \(status)) — build via Scripts/build-cli.sh (docs/MACOS-SIGNING.md)")
            }
            print("wire-view: paired host \(pinned.name) — pinned static "
                + "\(pinned.staticPublicKeyHex.prefix(8))…, client identity "
                + Hex.string(identity.publicKey.prefix(4))
                + "…")
            crypto = try NoiseTransportCrypto(
                hostAddress: pinned.address,
                hostPort: hostPort == 0 ? port : hostPort,
                hostStaticPublicKey: key,
                staticKeys: identity)
        }

        // Window + display layer first (main thread, before datagrams).
        let nsApp = NSApplication.shared
        nsApp.setActivationPolicy(.regular)

        let displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        VideoRendererHandoff.attachHostClockTimebase(to: displayLayer)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Lyte — wire-view :\(port)"
        window.collectionBehavior.insert(.fullScreenPrimary)
        let videoView = VideoLayerView(layer: displayLayer)
        window.contentView = videoView
        window.center()

        // Idempotent, and named: four paths converge here and the output
        // must say which one ended the run.
        let finished = Atomic(false)
        let finishBox = Mutex<(@Sendable (String) -> Void)?>(nil)

        // The production session object, event-printed; events fire
        // off-main. Host audio stays neutral unless --host-audio asks,
        // and --clipboard-images implies --clipboard.
        var sessionConfig = LyteUdpSession.Config(
            hostAudioRouting: hostAudio.flatMap(Self.parseHostAudio),
            shareClipboard: clipboard || clipboardImages,
            shareClipboardImages: clipboardImages,
            chroma: Self.parseChroma(chroma) ?? .good)
        sessionConfig.bindPort = port
        sessionConfig.bindAddress = bind
        // Audio playback is opt-in here so unattended gate runs stay silent.
        sessionConfig.audioPlayback = audio
        let pasteboardBox = Mutex<PasteboardSync?>(nil)
        // The app's renderer path, exactly: bounded handoff, Conductor
        // playout, recovery flush barrier, IRAP episode close.
        let recorder = VideoFlightRecorder(
            nowMicroseconds: { SystemMonotonicClock.nowMicroseconds })
        let deliveryBooks = VideoDeliveryBooks()
        let handoff = VideoRendererHandoff(
            renderer: displayLayer.sampleBufferRenderer,
            queue: DispatchQueue(label: "lyte.video.delivery", qos: .userInteractive),
            books: deliveryBooks,
            recorder: recorder)
        let session = LyteUdpSession(
            crypto: crypto,
            config: sessionConfig,
            handoff: handoff,
            onEvent: { event in
                switch event {
                case .capabilitiesAgreed(let agreed):
                    print("wire-view: capabilities AGREED — codecs \(agreed.videoCodecs), "
                        + "chroma \(agreed.chromaModes), idleSilence \(agreed.idleSilence), "
                        + "maxDatagram \(agreed.maxDatagramBytes), "
                        + "hostAudioRouting \(agreed.hostAudioRouting ? "yes (key 9)" : "no"), "
                        + "clipboard \(agreed.clipboardText ? "yes (key 10)" : "no"), "
                        + "clipImages \(agreed.clipboardImagesAgreed ? "yes (10∧12)" : "no")")
                case .capabilitiesFailed(let failure):
                    print("wire-view: capabilities FAILED (\(failure)) — typed teardown sent")
                case .capabilityUpdateAnswered(let accepted):
                    print("wire-view: capability update answered — "
                        + (accepted ? "accepted" : "rejected"))
                case .modeChanged(let mode):
                    print("wire-view: mode → \(mode == .active ? "ACTIVE" : "IDLE")")
                case .stateChanged(let state):
                    switch state {
                    case .frozen:
                        print("wire-view: PILL ON — path dark (FROZEN)")
                    case .active, .idle:
                        print("wire-view: pill off — \(state)")
                    case .recovery:
                        print("wire-view: state \(state) (unexpected for a receiver)")
                    case .closed:
                        break   // the .closed event carries the reason
                    }
                case .hostAudioRoutingStatus(let mode):
                    print("wire-view: host audio posture — "
                        + (mode == .hostMuted ? "MUTED (host speakers silent)"
                                              : "AUDIBLE (host speakers playing)")
                        + " (0x19-confirmed)")
                case .hostClipboardChanged(let text):
                    // Payloads never print — byte counts only.
                    print("wire-view: host clipboard → pasteboard "
                        + "(\(text.utf8.count) B, 0x1B)")
                    pasteboardBox.withLock { $0 }?.apply(text)
                case .hostCursorShapeChanged(let shape):
                    print("wire-view: host cursor shape "
                        + (shape.isHidden ? "HIDDEN"
                            : "\(shape.width)x\(shape.height) hotspot "
                            + "(\(shape.hotspotX),\(shape.hotspotY))")
                        + " (0x24)")
                case .hostClipboardImageChanged(let data, let mime):
                    // Sha-verified image cargo; byte count only.
                    print("wire-view: host clipboard image → pasteboard "
                        + "(\(data.count) B, \(mime), 0x22 cargo)")
                    pasteboardBox.withLock { $0 }?.apply(imageData: data)
                case .bulkMessageReceived(let message):
                    // The debug shell never offers files, so a chan-8
                    // answer is only worth a line.
                    print("wire-view: bulk message (transfer "
                        + "\(message.transferId)) — no transfer running")
                case .idleFrameReceived(let frame, let outcome):
                    print("wire-view: reliable idle frame \(frame) — \(outcome)")
                case .teardownSent(let reason):
                    print("wire-view: teardown 0x0A sent (\(reason))")
                case .orderedStreamPoisoned:
                    break   // its protocol note says which lane
                case .closed(let reason):
                    print("wire-view: session CLOSED — \(reason)")
                    finishBox.withLock { $0 }?("session closed: \(reason)")
                case .protocolNote(let note):
                    print("wire-view: \(note)")
                }
            })

        print("wire-view: Noise IK handshake → \(host):\(hostPort == 0 ? port : hostPort) …")
        do {
            try session.start()
        } catch let error as TransportCryptoError {
            switch error {
            case .invalidHostKey(let message), .handshakeFailed(let message):
                throw ValidationError("Noise: \(message)")
            case .unsealFailed(let message):
                throw ValidationError(message)
            }
        }
        guard let endpoint = session.endpoint, let core = session.core else {
            throw ValidationError("session started without endpoint/core")
        }
        print("wire-view: bound \(bind):\(endpoint.boundPort) — \(crypto.modeDescription)")
        if let noise = crypto as? NoiseTransportCrypto,
           noise.retryChallengesAnsweredSnapshot > 0 {
            print("wire-view: dial answered \(noise.retryChallengesAnsweredSnapshot) "
                + "retry challenge(s) (0x13 → 0x14, same msg1)")
        }
        print("wire-view: capability declaration sent (0x0F, first reliable word); "
            + "feedback cadence \(core.feedback.cadenceMilliseconds) ms")

        // The pasteboard watcher — the app's LyteUI glue; every verdict
        // prints. Byte counts only, never content.
        if clipboard || clipboardImages {
            let sync = PasteboardSync(onLocalChange: { [weak session] text in
                guard let session else { return }
                let outcome = session.core?.shareLocalClipboard(text)
                    ?? .sendRefused("not started")
                print("wire-view: local copy (\(text.utf8.count) B) — \(outcome)")
            })
            if clipboardImages {
                sync.onLocalImageChange = { [weak session] data in
                    guard let session else { return }
                    let outcome = session.core?.shareLocalClipboardImage(data)
                        ?? .sendRefused("not started")
                    print("wire-view: local image copy (\(data.count) B) "
                        + "— \(outcome)")
                }
                sync.setImagesEnabled(true)
            }
            sync.start()
            pasteboardBox.withLock { $0 = sync }
            print("wire-view: clipboard sharing ON"
                + (clipboardImages ? " + images" : "")
                + " — NSPasteboard poll 200 ms (key 10"
                + (clipboardImages ? "∧12" : "") + " pending agreement)")
        }

        // The renderer's own verdict is the render evidence: it goes
        // .failed if enqueued samples don't decode.
        let printer = WireViewStatsPrinter(
            session: session,
            recorder: recorder,
            deliveryBooks: deliveryBooks,
            rendererState: { handoff.rendererStateDescription })

        let ticker = DispatchSource.makeTimerSource(queue: .global())
        ticker.schedule(deadline: .now() + 1, repeating: 1)
        // @Sendable, explicitly: closures born in a @MainActor run()
        // inherit MainActor isolation, and a dispatch timer calling one
        // off-main traps (dispatch_assert_queue) at the first tick.
        ticker.setEventHandler { @Sendable in printer.printTick() }
        ticker.resume()

        let finish: @Sendable (String) -> Void = { trigger in
            // SIGINT, the window, the duration timer, and a session close
            // can race here; exactly one of them finishes.
            guard !finished.exchange(true, ordering: .relaxed) else { return }
            print("wire-view: finishing (\(trigger))")
            ticker.cancel()
            pasteboardBox.withLock { $0 }?.stop()
            // A locally-triggered end says goodbye on the wire (typed
            // 0x0A + ACK linger); a session-closed end (peer teardown,
            // liveness) has nothing left to say.
            if trigger.hasPrefix("session closed") {
                session.stop()
            } else {
                session.close(reason: .shuttingDown)
            }
            printer.printFinal()
            // exit(0) inline from windowWillClose can hang in AppKit
            // teardown; a global-queue hop exits cleanly from every path.
            DispatchQueue.global().async { Foundation.exit(0) }
        }
        finishBox.withLock { $0 = finish }

        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigint.setEventHandler { @Sendable in finish("SIGINT") }
        sigint.resume()

        let delegate = WindowCloser(onClose: {
            // close() lingers ≤500 ms for the teardown ACK — keep that
            // off the main thread AppKit is tearing the window down on.
            DispatchQueue.global().async { finish("window closed") }
        })
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
        streamRetainer.append(contentsOf: [
            delegate, ticker, sigint, session, window,
        ])
    }
}

/// The session's books for a human reading a terminal: demux totals, the
/// overlay's rows (SessionStatsFormatter, the same text the app shows),
/// then every engineering book as `name=value` over its non-zero fields.
/// One tick per second with new arrivals (prefixed `…`), a full summary
/// at exit. Nothing parses this output.
final class WireViewStatsPrinter: Sendable {
    private let session: LyteUdpSession
    private let recorder: VideoFlightRecorder
    private let deliveryBooks: VideoDeliveryBooks
    private let rendererState: @Sendable () -> String
    private let lastCount = Atomic<UInt64>(0)

    init(session: LyteUdpSession,
         recorder: VideoFlightRecorder,
         deliveryBooks: VideoDeliveryBooks,
         rendererState: @escaping @Sendable () -> String) {
        self.session = session
        self.recorder = recorder
        self.deliveryBooks = deliveryBooks
        self.rendererState = rendererState
    }

    func printTick() {
        guard let endpoint = session.endpoint else { return }
        let totals = endpoint.demux.snapshotTotals()
        guard lastCount.exchange(totals.datagrams, ordering: .relaxed)
            != totals.datagrams else { return }
        printSnapshot(prefix: "…", totals: totals)
    }

    func printFinal() {
        guard let endpoint = session.endpoint else { return }
        print("wire-view: final")
        printSnapshot(prefix: "  ", totals: endpoint.demux.snapshotTotals())
    }

    private func printSnapshot(prefix: String, totals: DemuxTotals) {
        guard let endpoint = session.endpoint,
              let core = session.core else { return }
        print("\(prefix) total " + Self.fields(totals).joined(separator: " "))
        var context = SessionStatsContext()
        context.delivery = deliveryBooks.snapshot(
            nowMicroseconds: SystemMonotonicClock.nowMicroseconds)
        context.flight = recorder.snapshot()
        for row in SessionStatsFormatter.rows(session: session, context: context) {
            print("\(prefix)   \(row.label): \(row.value)")
        }
        let books: [(String, Any?)] = [
            ("wire", endpoint.demux.stats(forChannel: core.pipeline.channel.rawValue)),
            ("render", core.pipeline.snapshotStats()),
            ("control", core.snapshotCounters()),
            ("feedback", core.feedback.snapshotStats()),
            ("echo", core.echoResponder.snapshotStats()),
            ("idr", core.idrStats),
            ("nack", core.nackStats),
            ("arq", core.reliable.snapshotStats()),
            ("audio", core.audio.snapshotStats()),
            ("player", session.audioPlayer?.snapshotStats()),
            ("input", core.input.snapshotStats()),
        ]
        for case let (label, book?) in books {
            let fields = Self.fields(book)
            if !fields.isEmpty {
                print("\(prefix)   \(label): " + fields.joined(separator: " "))
            }
        }
        print("\(prefix)   layer: \(rendererState())")
        if let fit = core.clockModel.estimate() {
            let sign = fit.offsetMicroseconds >= 0 ? "+" : ""
            print("\(prefix)   clock: offset \(sign)\(fit.offsetMicroseconds) µs, " +
                  String(format: "skew %+.1f ppm, residual rms %.1f / max %.1f µs, ",
                         fit.skewPartsPerMillion, fit.residualRmsMicroseconds,
                         fit.residualMaxMicroseconds) +
                  "\(fit.acceptedSamples)/\(fit.windowSamples) samples " +
                  "(min rtt \(fit.minRttMicroseconds) µs)")
        }
    }

    /// `name=value` for each non-zero scalar of a stats snapshot, nested
    /// books as `outer.inner=value`, latency histograms as p50/p99 ms.
    static func fields(_ book: Any, prefix: String = "") -> [String] {
        let mirror = Mirror(reflecting: book)
        if mirror.displayStyle == .optional {
            return mirror.children.first.map { fields($0.value, prefix: prefix) } ?? []
        }
        return mirror.children.flatMap { child -> [String] in
            guard let label = child.label, label != "config" else { return [] }
            let name = prefix + label
            switch child.value {
            case let histogram as Histogram<UInt64>:
                guard let p50 = histogram.p50, let p99 = histogram.p99 else { return [] }
                return [String(format: "%@=%.1f/%.1fms",
                               name, Double(p50) / 1000, Double(p99) / 1000)]
            case let number as any BinaryInteger:
                return Int64(truncatingIfNeeded: number) == 0 ? [] : ["\(name)=\(number)"]
            case let number as Double:
                return number == 0 || !number.isFinite
                    ? [] : [String(format: "%@=%.1f", name, number)]
            case let flag as Bool:
                return flag ? [name] : []
            default:
                return fields(child.value, prefix: name + ".")
            }
        }
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
