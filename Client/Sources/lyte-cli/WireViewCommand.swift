import AppKit
import ArgumentParser
@preconcurrency import AVFoundation
import Foundation
import LyteCore
import LyteIO
import LyteClientSession
import LyteTransport
import LyteUI
import LyteWire

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
    @Option(name: .long, help: "Forcing surface: prime the adaptive jitter target at N packets (~N×5 ms of initial depth) — the percentile controller then decays and WSOLA accelerate drains the surplus; the audio line's depth/accel books are the evidence. 0 = off")
    var audioPrime: Int = 0
    @Option(name: .long, help: "The session-start posture for the HOST's own speakers — audible|muted. Needs capability key 9 on both ends; against a no-key-9 host the ask is refused client-side (that refusal is the evidence). Omitted = NEUTRAL: take the host's default without asking (the debug-shell posture; the app asks for muted)")
    var hostAudio: String?
    @Flag(name: .long, help: "Share the clipboard (UTF-8 text, both ways) — real NSPasteboard glue behind the sans-IO core's gates. Needs capability key 10 on both ends; against a no-key-10 host every local copy reports notNegotiated (that refusal is the evidence). Payloads are never printed — byte counts only")
    var clipboard = false
    @Flag(name: .long, help: "The images rung on top of --clipboard (the Text + images tier) — clipboard PNGs ride chan 8 as 0x22 cargo, both ways. Needs keys 10 AND 12 on both ends (a --clipboard=text host declines with abort). Byte counts only, as ever")
    var clipboardImages = false
    @Option(name: .long, help: "The chroma tier this client DECLARES — 420 (Good, the default) or 444 (Best). Declaration-as-choice: the singleton is the ask; a host without the tier answers the typed noCommonChromaMode teardown (that refusal is the harness's fallback evidence — the debug shell never auto-re-dials; the app does)")
    var chroma: String = "420"
    @Option(name: .long, help: """
        Scripted synthetic input, semicolon-separated \
        "<at_ms> <kind> <args>" entries sent on the reliable stream. Kinds: \
        `move X Y` (host pixels), `rel DX DY`, `key CODE down|up` (evdev), \
        `button CODE down|up`, `axis DX DY [finish]`. \
        Example: --input-script "500 move 120 1150; 1500 key 30 down; 1550 key 30 up"
        """)
    var inputScript: String?

    func validate() throws {
        if let inputScript {
            _ = try InputScript.parse(inputScript)   // fail before the dial
        }
        if let hostAudio, Self.parseHostAudio(hostAudio) == nil {
            throw ValidationError("--host-audio wants audible|muted, got '\(hostAudio)'")
        }
        if audioPrime != 0, !(5...60).contains(audioPrime) {
            throw ValidationError("--audio-prime wants 5…60 packets (25…300 ms), got \(audioPrime)")
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
            // Explicit key: throwaway client static, exactly as before —
            // the debug-harness posture (a --require-paired host will
            // refuse the unpinned static; that refusal is the feature).
            crypto = try NoiseTransportCrypto(
                hostAddress: host,
                hostPort: hostPort == 0 ? port : hostPort,
                hostStaticPublicKey: NoiseTransportCrypto.parseKeyHex(hostKey))
        } else {
            // The zero-UI reconnect: no key argued, so the pinned
            // store supplies the host static and the Keychain supplies
            // OUR persistent identity — plain 1-RTT Noise IK, which a
            // --require-paired host admits because pairing pinned this
            // exact static pair on both ends.
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
                hostAddress: host,
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

        // Idempotent, and named: four paths converge here and the smoke
        // evidence must say which one ended the run. Late-bound because
        // the session's event hook needs it and finish needs the session.
        let finished = LockedCell(false)
        let finishBox = LockedCell<(@Sendable (String) -> Void)?>(nil)

        // The production session object, event-printed. Every event
        // fires off-main (receive/timer threads) — printing is safe.
        //
        // Debug-shell posture: host audio stays NEUTRAL unless
        // --host-audio asks (the app asks for muted), --clipboard-images
        // implies --clipboard (images never move without text consent),
        // and --chroma is the declaration.
        var sessionConfig = LyteUdpSession.Config(
            hostAudioRouting: hostAudio.flatMap(Self.parseHostAudio),
            shareClipboard: clipboard || clipboardImages,
            shareClipboardImages: clipboardImages,
            chroma: Self.parseChroma(chroma) ?? .good)
        sessionConfig.bindPort = port
        sessionConfig.bindAddress = bind
        // Audio playback is opt-in here so unattended gate runs stay silent.
        sessionConfig.audioPlayback = audio
        // --audio-prime forces the drain scenario: playout waits for N
        // packets, so the pipe opens ~N×5 ms deep and the controller and
        // accelerate earn their way back down on the live wire.
        if audioPrime > 0 {
            sessionConfig.core.audioJitter.initialTargetPackets = audioPrime
            sessionConfig.core.audioJitter.maxTargetPackets = max(
                sessionConfig.core.audioJitter.maxTargetPackets, audioPrime)
        }
        let pasteboardBox = LockedCell<PasteboardSync?>(nil)
        // The app's renderer path, exactly: bounded handoff, Conductor
        // playout, recovery flush barrier, IRAP episode close.
        let clockModel = HostClockModel()
        let recorder = VideoFlightRecorder(
            nowMicroseconds: { SystemMonotonicClock.nowMicroseconds })
        let handoff = VideoRendererHandoff(
            renderer: displayLayer.sampleBufferRenderer,
            queue: DispatchQueue(label: "lyte.video.delivery", qos: .userInteractive),
            clockModel: clockModel,
            books: VideoDeliveryBooks(),
            recorder: recorder)
        let session = LyteUdpSession(
            crypto: crypto,
            config: sessionConfig,
            clockModel: clockModel,
            onVideoRecoveryDemand: { [weak handoff] cause, frame in
                handoff?.beginRecovery(cause: cause, after: frame)
            },
            onVideoRecoveryTrace: { event in
                recorder.recordRecoveryLifecycle(
                    kind: event.kind,
                    frame: event.frame.rawValue,
                    cause: event.cause,
                    isRandomAccess: event.isRandomAccess)
            },
            videoSink: handoff,
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
                    // Payloads never print — the byte count is the
                    // live-leg evidence.
                    print("wire-view: host clipboard → pasteboard "
                        + "(\(text.utf8.count) B, 0x1B)")
                    pasteboardBox.value?.apply(text)
                case .hostCursorShapeChanged(let shape):
                    // E3: the dev CLI has no cursor to dress — the
                    // print IS the live-leg evidence.
                    print("wire-view: host cursor shape "
                        + (shape.isHidden ? "HIDDEN"
                            : "\(shape.width)x\(shape.height) hotspot "
                            + "(\(shape.hotspotX),\(shape.hotspotY))")
                        + " (0x24)")
                case .hostClipboardImageChanged(let data, let mime):
                    // Sha-verified image cargo off chan 8. Byte
                    // count only, same rule.
                    print("wire-view: host clipboard image → pasteboard "
                        + "(\(data.count) B, \(mime), 0x22 cargo)")
                    pasteboardBox.value?.apply(imageData: data)
                case .bulkMessageReceived(let message):
                    // F-4: the debug shell never offers files (the app
                    // owns the drop UX), so a chan-8 answer here is
                    // weather worth a line, nothing more.
                    print("wire-view: bulk message (transfer "
                        + "\(message.transferId)) — no transfer running")
                case .idleFrameReceived(let frame, let outcome):
                    print("wire-view: reliable idle frame \(frame) — \(outcome)")
                case .teardownSent(let reason):
                    print("wire-view: teardown 0x0A sent (\(reason))")
                case .closed(let reason):
                    print("wire-view: session CLOSED — \(reason)")
                    finishBox.value?("session closed: \(reason)")
                case .protocolNote(let note):
                    print("wire-view: \(note)")
                }
            })
        handoff.bind(session)

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

        // The pasteboard watcher — the same LyteUI glue the app
        // runs; every local copy funnels through the core's gates
        // (negotiated → enabled → sync book → ceiling), and every
        // verdict prints as evidence. Byte counts only, never content.
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
            pasteboardBox.value = sync
            print("wire-view: clipboard sharing ON"
                + (clipboardImages ? " + images" : "")
                + " — NSPasteboard poll 200 ms (key 10"
                + (clipboardImages ? "∧12" : "") + " pending agreement)")
        }

        // Scripted synthetic input through the
        // production sendInput path (seq, capture stamp, reliable
        // stream) — the same bytes the app's NSEvent capture sends.
        if let inputScript {
            let entries = try InputScript.parse(inputScript)
            print("wire-view: input script armed — \(entries.count) event(s), "
                + "first at +\(entries.first!.atMilliseconds) ms")
            for entry in entries {
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .milliseconds(entry.atMilliseconds)
                ) {
                    do {
                        let seq = try core.sendInput(entry.body)
                        print("wire-view: input seq \(seq) sent — \(entry.label)")
                    } catch {
                        print("wire-view: input '\(entry.label)' refused: \(error)")
                    }
                }
            }
        }

        // The renderer's own verdict is the honest render evidence: it
        // goes .failed (with the VideoToolbox error) if enqueued samples
        // don't actually decode — enqueue counts alone can't lie-detect.
        let printer = WireViewStatsPrinter(
            session: session,
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
            guard !finished.exchange(true) else { return }
            print("wire-view: finishing (\(trigger))")
            ticker.cancel()
            pasteboardBox.value?.stop()
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
        finishBox.value = finish

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

/// The session's books for a human reading a terminal: demux totals,
/// render, quality, session state, the return path, repair, the reliable
/// sublayer, the clock model, audio, and input — one tick per second with
/// new arrivals (prefixed `…`), a full summary at exit. Nothing parses
/// this output; the app's overlay has its own, terser rows.
final class WireViewStatsPrinter: Sendable {
    private let session: LyteUdpSession
    private let rendererState: @Sendable () -> String
    private let lastCount = LockedCell<UInt64>(0)

    init(session: LyteUdpSession,
         rendererState: @escaping @Sendable () -> String) {
        self.session = session
        self.rendererState = rendererState
    }

    func printTick() {
        guard let endpoint = session.endpoint else { return }
        let totals = endpoint.demux.snapshotTotals()
        guard totals.datagrams != lastCount.value else { return }
        lastCount.value = totals.datagrams
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
        var line = "\(prefix) total \(totals.datagrams) datagrams: \(totals.accepted) ok"
        if totals.malformed > 0 { line += ", \(totals.malformed) malformed" }
        if totals.reservedDropped > 0 { line += ", \(totals.reservedDropped) reserved-dropped" }
        if totals.unsealFailures > 0 { line += ", \(totals.unsealFailures) unseal-failed" }
        print(line)
        if let video = endpoint.demux.stats(forChannel: core.pipeline.channel.rawValue) {
            print("\(prefix)   wire: \(video.datagrams) dg, \(video.payloadBytes) B, " +
                  "\(video.seqMissing) missing, \(video.seqDuplicates) dup")
        }
        let s = core.pipeline.snapshotStats()
        var render = "\(prefix)   render: \(s.framesDecoded) decoded, \(s.framesSkipped) skipped, " +
                     "\(s.samplesDelivered) enqueued"
        if s.samplesWithheld > 0 { render += ", \(s.samplesWithheld) withheld (pre-IDR)" }
        if s.sampleFailures > 0 { render += ", \(s.sampleFailures) sample-failed" }
        if s.fecImpossibleCount > 0 { render += ", \(s.fecImpossibleCount) fec-impossible" }
        if s.repairShardsAccepted > 0 { render += ", \(s.repairShardsAccepted) repair-shards" }
        if s.evictions > 0 { render += ", \(s.evictions) evicted" }
        if s.shardsDropped > 0 { render += ", \(s.shardsDropped) shards dropped" }
        if s.reliableFramesRendered + s.reliableFramesDeduplicated > 0 {
            render += ", \(s.reliableFramesRendered) idle-rendered"
            if s.reliableFramesDeduplicated > 0 {
                render += "/\(s.reliableFramesDeduplicated) idle-deduped"
            }
        }
        if let first = s.firstSampleMicroseconds {
            render += String(format: " | first frame %.1fms", Double(first) / 1000)
        }
        render += " | layer \(rendererState())"
        print(render)

        // The quality line: the receive-side derivation of the
        // host's per-second `quality:` books — frame cadence, video
        // bitrate, frame-size percentiles over the last ~5 s. Host QP
        // and the encoder's reconfigured posture stay host-log truth
        // (no wire vocabulary carries them; read the two side by side).
        if let q = s.quality {
            print("\(prefix)   quality: " +
                  String(format: "%.0f fps, %.1f Mbps",
                         q.framesPerSecond,
                         Double(q.bitsPerSecond) / 1e6) +
                  ", frame p50 \(q.frameBytesP50) B / p95 " +
                  "\(q.frameBytesP95) B / max \(q.frameBytesMax) B")
        }

        // The session line: the machine's verdicts.
        let counters = core.snapshotCounters()
        var sess = "\(prefix)   session: mode \(core.wireMode == .active ? "ACTIVE" : "IDLE")"
        sess += core.isFrozen ? ", PILL (frozen)" : ""
        if core.state == .closed { sess += ", CLOSED" }
        sess += ", caps \(core.agreedCapabilities != nil ? "agreed" : "pending")"
        // What the wire actually carries (SPS-parsed off IDRs) —
        // the live leg's negotiated-posture evidence.
        if let chroma = core.streamChromaDescription {
            sess += ", stream chroma \(chroma)"
        }
        // The host-speaker posture — key 9 + the 0x19-confirmed
        // truth (never optimistic; "pending" between agreement and the
        // host's first status).
        if core.hostAudioRoutingNegotiated {
            switch core.hostAudioRoutingPosture {
            case .hostMuted: sess += ", host-audio MUTED"
            case .hostAudible: sess += ", host-audio audible"
            case .streamOff: sess += ", audio stream OFF"
            case nil: sess += ", host-audio pending"
            }
        } else if core.agreedCapabilities != nil {
            sess += ", host-audio unnegotiated"
        }
        if counters.modeTransitionsReceived > 0 {
            sess += ", \(counters.modeTransitionsReceived) mode msgs"
        }
        if counters.idleFramesReceived > 0 {
            sess += ", \(counters.idleFramesReceived) idle frames"
        }
        if counters.unknownReliableTypes > 0 {
            sess += ", \(counters.unknownReliableTypes) unknown-reliable"
        }
        if counters.malformedReliableMessages > 0 {
            sess += ", \(counters.malformedReliableMessages) malformed-reliable"
        }
        if counters.audioRoutingRequestsSent
            + counters.audioRoutingStatusesReceived > 0 {
            sess += ", routing \(counters.audioRoutingRequestsSent) asks/"
                + "\(counters.audioRoutingStatusesReceived) statuses"
        }
        if counters.audioRoutingDropsLoud > 0 {
            sess += ", \(counters.audioRoutingDropsLoud) routing-drops"
        }
        // The clipboard state + books (byte counts and verdicts
        // only — payloads never print).
        if core.clipboardNegotiated {
            sess += ", clipboard \(core.clipboardSharingEnabled ? "ON" : "off")"
            if counters.clipboardSharesSent
                + counters.clipboardAnnouncesReceived > 0 {
                sess += " (\(counters.clipboardSharesSent) sent/"
                    + "\(counters.clipboardAnnouncesReceived) recv)"
            }
            if counters.clipboardLoopSuppressed > 0 {
                sess += ", \(counters.clipboardLoopSuppressed) clip-suppressed"
            }
            if counters.clipboardIgnoredDisabled > 0 {
                sess += ", \(counters.clipboardIgnoredDisabled) clip-ignored"
            }
        } else if core.agreedCapabilities != nil {
            sess += ", clipboard unnegotiated"
        }
        if counters.clipboardDropsLoud > 0 {
            sess += ", \(counters.clipboardDropsLoud) clip-drops"
        }
        // The image lane's books, while it has any.
        let images = core.clipboardImageCounters
        let imageActivity = images.sharesStarted + images.imagesApplied
            + images.sharesSuppressed + images.receivesRefused
        if imageActivity > 0 {
            sess += ", clipImages \(images.sharesCompleted)/"
                + "\(images.sharesStarted) sent"
                + " \(images.imagesApplied) applied"
                + " \(images.sharesSuppressed) suppressed"
        }
        print(sess)

        // The return leg: what went back to the host.
        let fb = core.feedback.snapshotStats()
        let echo = core.echoResponder.snapshotStats()
        let idr = core.idrRequester.snapshotStats()
        var back = "\(prefix)   sent: \(fb.reportsSent) feedback " +
                   "(\(fb.dispersionSamplesReported) dispersion samples), " +
                   "\(echo.echoesSent) echoes, \(idr.requestsSent) IDR-requests " +
                   "(\(idr.verdicts) verdicts)"
        if echo.clockSamples > 0 {
            back += ", \(echo.clockSamples) clock samples"
            if let last = core.clockModel.recentSamples(1).last {
                // Interpolation, not %d: varargs %d truncates Int64 to 32
                // bits and boot-epoch offsets are ~10¹⁰ µs (found live —
                // the printed offset disagreed with the clock fit by 2·2³²).
                let sign = last.offsetMicroseconds >= 0 ? "+" : ""
                back += " (last offset \(sign)\(last.offsetMicroseconds) µs, " +
                        "rtt \(last.rttMicroseconds) µs)"
            }
        }
        print(back)

        // The targeted-repair line, whenever the policy stirred:
        // asks out, repairs back, frames healed, staleness → IDR.
        let nack = core.nackPolicy.snapshotStats()
        if nack.pastParityFrames + nack.repairShardsReceived
            + nack.whollyLostEscalations > 0 {
            var line = "\(prefix)   nack: \(nack.pastParityFrames) past-parity, " +
                       "\(nack.nackEntriesEmitted) asks (\(nack.shardsAsked) shards), " +
                       "\(nack.repairShardsReceived) repairs rx, " +
                       "\(nack.framesCompletedByRepair) frames repaired"
            if nack.asksSuppressedStale > 0 {
                line += ", \(nack.asksSuppressedStale) stale-suppressed"
            }
            if nack.framesEscalatedToIdr > 0 {
                line += ", \(nack.framesEscalatedToIdr) expired→IDR"
            }
            if nack.whollyLostEscalations > 0 {
                line += ", \(nack.whollyLostEscalations) whole-loss→IDR"
            }
            // Explicit host refusals — acted asks skip the
            // 250 ms deadline entirely.
            if nack.refusalsReceived > 0 {
                line += ", \(nack.refusalsReceived) refusals rx " +
                        "(\(nack.refusalsActedOn) acted→IDR" +
                        (nack.refusalsIgnored > 0
                            ? ", \(nack.refusalsIgnored) ignored)"
                            : ")")
            }
            if nack.fecImpossibleDeferred > 0 {
                line += ", \(nack.fecImpossibleDeferred) idr-deferred"
            }
            // Answers the frame no longer needed — the live-books
            // reconciliation against the host's repair ledger.
            if nack.repairsLate + nack.repairsDuplicate
                + nack.repairsSuperseded > 0 {
                line += ", answers unneeded \(nack.repairsLate) late/" +
                        "\(nack.repairsDuplicate) dup/" +
                        "\(nack.repairsSuperseded) superseded"
            }
            print(line)
        }

        // The reliable sublayer, when it has done anything at all.
        let arq = core.reliable.snapshotStats()
        if arq.messagesSent + arq.messagesDelivered + arq.datagramsSent > 0 {
            var line = "\(prefix)   arq: \(arq.messagesSent) sent, " +
                       "\(arq.messagesDelivered) delivered, " +
                       "\(arq.oneShotsAcknowledged) one-shot-acked, " +
                       "\(arq.datagramsSent) datagrams" +
                       (core.reliable.isQuiescent ? ", quiescent" : ", in flight")
            if arq.ingestIgnored > 0 { line += ", \(arq.ingestIgnored) ignored" }
            if arq.sendFailures > 0 { line += ", \(arq.sendFailures) send-failed" }
            print(line)
        }

        // The clock model line: the T gate reads the residual here.
        if let fit = core.clockModel.estimate() {
            let sign = fit.offsetMicroseconds >= 0 ? "+" : ""
            print("\(prefix)   clock: offset \(sign)\(fit.offsetMicroseconds) µs, " +
                  String(format: "skew %+.1f ppm, residual rms %.1f / max %.1f µs, ",
                         fit.skewPartsPerMillion, fit.residualRmsMicroseconds,
                         fit.residualMaxMicroseconds) +
                  "\(fit.acceptedSamples)/\(fit.windowSamples) samples " +
                  "(min rtt \(fit.minRttMicroseconds) µs)")
        }

        // The audio line: depacketizer/FEC + jitter buffer +
        // playback evidence, whenever the channel carried anything.
        let audio = core.audio.snapshotStats()
        if audio.depacketizer.datagramsIngested > 0 {
            let d = audio.depacketizer
            let j = audio.jitter
            var line = "\(prefix)   audio: \(d.datagramsIngested) dg → " +
                       "\(d.packetsEmitted) pkts"
            if d.packetsRebuilt > 0 {
                line += " (\(d.packetsRebuilt) rebuilt/" +
                        "\(d.groupsRecovered) groups)"
            }
            if d.packetsUnrecoverable > 0 {
                line += ", \(d.packetsUnrecoverable) fec-impossible"
            }
            line += ", plc \(j.plcInvocations)"
            if j.latePacketsDropped > 0 { line += ", \(j.latePacketsDropped) late" }
            if j.recenterEvents > 0 {
                line += ", \(j.recenterEvents) recenter" +
                        "(-\(j.packetsDroppedInRecenter) pkts)"
            }
            if let p50 = audio.bufferDepthPackets.p50,
               let p99 = audio.bufferDepthPackets.p99 {
                line += ", depth p50/p99 \(p50)/\(p99) pkts"
            }
            line += " (target \(j.targetPackets))"
            line += String(format: ", jitter σ %.0f µs",
                           j.interArrivalStdDevMicroseconds)
            if j.skewPartsPerMillion != 0 {
                line += String(format: ", skew %+.0f ppm",
                               j.skewPartsPerMillion)
            }
            // Above-floor: capture→render minus the session's fastest
            // observed path (graph-clock epoch is unmappable; the
            // beacon min-RTT bounds the floor itself).
            line += Self.latency(" | pipe", audio.captureToRender)
            if let player = session.audioPlayer {
                let p = player.snapshotStats()
                line += ", ring \(p.ringDepthFrames * 1000 / 48_000) ms"
                if p.underrunFrames > 0 {
                    line += ", underrun \(p.underrunFrames) frames"
                }
                // The accelerate books: WSOLA ops + backlog drained, the
                // engage count, and route-change survivals.
                if p.accelerate.removalOps > 0
                    || audio.accelerateEngagements > 0 {
                    line += ", accel \(p.accelerate.removalOps) ops "
                        + "(−\(p.accelerate.millisecondsDrained) ms, "
                        + "\(audio.accelerateEngagements) engage)"
                }
                if p.routeChangesHandled + p.routeChangeFailures > 0 {
                    line += ", route \(p.routeChangesHandled) rebuilt"
                    if p.routeChangeFailures > 0 {
                        line += "/\(p.routeChangeFailures) failed"
                    }
                }
                if p.lastWindowRmsDbfs > -120 {
                    line += String(format: ", sig %.1f dBFS ~%.0f Hz",
                                   p.lastWindowRmsDbfs,
                                   p.lastWindowZeroCrossingHz)
                }
            }
            print(line)
        }

        // The input line: sender books + both latency loops, when
        // any input rode this session.
        let input = core.input.snapshotStats()
        if input.eventsSent > 0 || input.echoTuplesReceived > 0 {
            var line = "\(prefix)   input: \(input.eventsSent) sent, " +
                       "\(input.echoTuplesReceived) echoes"
            if core.input.pendingEchoCount > 0 {
                line += " (\(core.input.pendingEchoCount) pending)"
            }
            if input.sendFailures > 0 { line += ", \(input.sendFailures) send-failed" }
            if input.unmatchedEchoTuples > 0 {
                line += ", \(input.unmatchedEchoTuples) unmatched"
            }
            if input.echoesWithoutClockFit > 0 {
                line += ", \(input.echoesWithoutClockFit) no-clock-fit"
            }
            if input.malformedFrameStamps > 0 {
                line += ", \(input.malformedFrameStamps) bad-stamps"
            }
            if let stamp = input.lastStampSeen {
                line += ", frame stamp \(stamp)"
            }
            line += Self.latency(" | inject", input.inputToInject)
            line += Self.latency(", photon", input.inputToPhoton)
            line += Self.latency(", host rx→inject", input.hostReceiveToInject)
            print(line)
        }
    }

    /// "label p50/p99 A/B ms" for one recorded edge; empty pre-samples.
    private static func latency(
        _ label: String, _ hist: Histogram<UInt64>
    ) -> String {
        guard let p50 = hist.p50, let p99 = hist.p99 else { return "" }
        return String(format: "%@ p50/p99 %.1f/%.1f ms",
                      label, Double(p50) / 1000, Double(p99) / 1000)
    }
}

/// The --input-script DSL (the synthetic input surface): semicolon-
/// separated "<at_ms> <kind> <args>" entries. Parsed up front so a typo
/// fails the command, never a mid-run surprise.
enum InputScript {
    struct Entry {
        let atMilliseconds: Int
        let body: InputEvent.Body
        let label: String
    }

    static func parse(_ script: String) throws -> [Entry] {
        var entries: [Entry] = []
        for raw in script.split(separator: ";") {
            let words = raw.split(separator: " ").map(String.init)
            guard words.count >= 2, let at = Int(words[0]), at >= 0 else {
                throw ValidationError(
                    "input-script entry '\(raw.trimmingCharacters(in: .whitespaces))' — want '<at_ms> <kind> <args>'")
            }
            let body: InputEvent.Body
            switch (words[1], words.count) {
            case ("move", 4):
                body = .pointerMotionAbsolute(
                    x: try double(words[2], in: raw),
                    y: try double(words[3], in: raw))
            case ("rel", 4):
                body = .pointerMotionRelative(
                    dx: try double(words[2], in: raw),
                    dy: try double(words[3], in: raw))
            case ("key", 4):
                body = .keyKeycode(
                    keycode: try code(words[2], in: raw),
                    pressed: try pressed(words[3], in: raw))
            case ("button", 4):
                body = .pointerButton(
                    button: try code(words[2], in: raw),
                    pressed: try pressed(words[3], in: raw))
            case ("axis", 4), ("axis", 5):
                body = .pointerAxis(
                    dx: try double(words[2], in: raw),
                    dy: try double(words[3], in: raw),
                    finish: words.count == 5 && words[4] == "finish")
            default:
                throw ValidationError(
                    "input-script entry '\(raw.trimmingCharacters(in: .whitespaces))' — unknown kind/arity")
            }
            entries.append(Entry(
                atMilliseconds: at, body: body,
                label: words.dropFirst().joined(separator: " ")))
        }
        guard !entries.isEmpty else {
            throw ValidationError("input-script parsed to zero entries")
        }
        return entries.sorted { $0.atMilliseconds < $1.atMilliseconds }
    }

    private static func double(_ word: String, in entry: Substring) throws -> Double {
        guard let value = Double(word) else {
            throw ValidationError("input-script '\(entry)': '\(word)' is not a number")
        }
        return value
    }

    private static func code(_ word: String, in entry: Substring) throws -> UInt32 {
        let value = word.hasPrefix("0x")
            ? UInt32(word.dropFirst(2), radix: 16)
            : UInt32(word)
        guard let value else {
            throw ValidationError("input-script '\(entry)': '\(word)' is not a keycode")
        }
        return value
    }

    private static func pressed(_ word: String, in entry: Substring) throws -> Bool {
        switch word {
        case "down": return true
        case "up": return false
        default:
            throw ValidationError("input-script '\(entry)': want down|up, got '\(word)'")
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

/// Lock-boxed value for cross-queue state.
final class LockedCell<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Stores `new` and returns the previous value, atomically.
    func exchange(_ new: T) -> T {
        lock.withLock {
            defer { stored = new }
            return stored
        }
    }
}
