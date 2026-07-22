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
/// CL-3: the mouth. The same endpoint now talks back on the socket it
/// listens on — chan=3 feedback reports on a 25–50 ms cadence
/// (FeedbackSender), beacon echoes for every CTRL ClockBeacon
/// (BeaconEchoResponder), and coalesced IDR requests when the assembler
/// writes a frame off as FEC-impossible (IdrRequester). wire-send is the
/// host stand-in that receives and logs all three until the host box returns.
///
/// AppKit rule (HANDOFF, hard-won): NSApplication.run() must own the raw
/// C main thread — Main.main treats every subcommand not on its non-UI
/// list as a UI command, so this file only has to keep its `run()` off
/// the main-thread-blocking paths and let the window live.
struct WireView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wire-view",
        abstract: "Render an incoming Lyte-UDP video stream in a window (wire-listen + eyes).")

    @Argument(help: "UDP port to bind (0 picks a free port; in Noise mode also the host's listen port unless --host-port)") var port: UInt16
    @Option(name: .long, help: "Address to bind") var bind: String = "0.0.0.0"
    @Flag(name: .long, help: "CP-3 recorded fallback: accept payloads with NO crypto")
    var insecure = false
    @Option(name: .long, help: "Noise mode: the host's static public key, 64 hex digits (printed by lyte-host at start). Omit it once paired — the pinned key + Keychain identity take over (CL-6)")
    var hostKey: String?
    @Option(name: .long, help: "Noise mode: the host's address")
    var host: String = "10.0.0.249"
    @Option(name: .long, help: "Noise mode: the host's --wire-listen port (default: the bind port)")
    var hostPort: UInt16 = 0
    @Option(name: .long, help: "Auto-exit after this many seconds (default: until the window closes)")
    var duration: Int = 0
    @Option(name: .long, help: "Debug: send one reliable CTRL ping every N seconds (0 = off) — exercises the CL-7 ARQ leg live")
    var arqPing: Int = 0

    func validate() throws {
        if insecure, hostKey != nil {
            throw ValidationError("--insecure and --host-key are mutually exclusive")
        }
    }

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffer even when piped

        let crypto: any TransportCrypto
        if insecure {
            crypto = InsecureTransportCrypto()
        } else if let hostKey {
            // Explicit key: throwaway client static, exactly as before —
            // the debug-harness posture (a --require-paired host will
            // refuse the unpinned static; that refusal is the feature).
            crypto = try NoiseTransportCrypto(
                hostAddress: host,
                hostPort: hostPort == 0 ? port : hostPort,
                hostStaticPublicKey: NoiseTransportCrypto.parseKeyHex(hostKey))
        } else {
            // CL-6, the zero-UI reconnect: no key argued, so the pinned
            // store supplies the host static and the Keychain supplies
            // OUR persistent identity — plain 1-RTT Noise IK, which a
            // --require-paired host admits because pairing pinned this
            // exact static pair on both ends.
            guard let pinned = PinnedHostStore.load().host(address: host),
                  let key = pinned.staticPublicKey
            else {
                throw ValidationError(
                    "\(host) is not paired — run `lyte-cli wire-pair \(host) --pin <PIN>` first, pass --host-key <64-hex> for a one-off, or --insecure for the recorded CP-3 fallback")
            }
            let identity: NoiseKeyPair
            do {
                identity = try ClientNoiseIdentity.loadOrCreate()
            } catch ClientNoiseIdentityError.keychain(let status) {
                throw ValidationError(
                    "Keychain refused the client identity (OSStatus \(status)) — build via Scripts/build-cli.sh (docs/MACOS-SIGNING.md)")
            }
            print("wire-view: paired host \(pinned.name) — pinned static "
                + "\(pinned.staticPublicKeyHex.prefix(8))…, client identity "
                + identity.publicKey.prefix(4).map { String(format: "%02x", $0) }.joined()
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

        // Construction order fights two reference cycles (pipeline needs
        // the IDR requester, endpoint needs the echo responder, both need
        // the sender, the sender needs the endpoint): late-bound boxes.
        let idrBox = LockedCell<IdrRequester?>(nil)
        let echoBox = LockedCell<BeaconEchoResponder?>(nil)
        let reliableBox = LockedCell<ReliableCtrlEndpoint?>(nil)
        let clientNow: @Sendable () -> ClientTimestamp = {
            ClientTimestamp(microseconds: DispatchTime.now().uptimeNanoseconds / 1000)
        }

        // The render path: assembled DecodeUnits become samples on the
        // receive thread and enqueue straight into the layer's renderer
        // (present-ASAP; the frozen stack enqueues from its receive
        // thread the same way).
        let pipeline = LyteVideoPipeline(
            onSample: { sample, _ in
                renderer.enqueue(sample)
            },
            onFecImpossible: { frame, lostData, bestParity in
                // CL-3: the seam is live — this verdict becomes a
                // (coalesced) IDR request on CTRL.
                print("wire-view: frame \(frame.rawValue) FEC-IMPOSSIBLE " +
                      "(\(lostData) data shards presumed lost, best-case parity \(bestParity)) " +
                      "— requesting IDR")
                idrBox.value?.recordFecImpossible(frame: frame, now: clientNow())
            })
        pipeline.start()

        let endpoint = UdpReceiveEndpoint(
            port: port, bindAddress: bind, crypto: crypto,
            onDatagram: { outcome, _ in
                guard case .accepted(let envelope, let payload) = outcome else { return }
                if envelope.channel == .ctrl {
                    // CL-7: the one-byte peek — a sealed CTRL payload
                    // starting with 0x07/0x08 is wholly ARQ and routes
                    // to the reliable endpoint (which also learns the
                    // conn-id from the envelope's TLV); everything else
                    // falls through to the exempt paths.
                    if reliableBox.value?.handleCtrlDatagram(
                        envelope: envelope, payload: payload) == true {
                        return
                    }
                    // t2 in the client-monotonic domain, taken here on the
                    // receive thread (the kernel stamp is wall-clock).
                    echoBox.value?.handleCtrlPayload(
                        payload,
                        arrivalMicroseconds: clientNow().microseconds)
                } else {
                    pipeline.ingest(envelope: envelope, payload: payload)
                }
            })
        if !insecure {
            print("wire-view: Noise IK handshake → \(host):\(hostPort == 0 ? port : hostPort) …")
        }
        do {
            try endpoint.start()
        } catch let error as TransportCryptoError {
            switch error {
            case .invalidHostKey(let message), .handshakeFailed(let message):
                throw ValidationError("Noise: \(message)")
            case .unsealFailed(let message):
                throw ValidationError(message)
            }
        }
        print("wire-view: bound \(bind):\(endpoint.boundPort) — \(crypto.modeDescription)")
        if insecure {
            print("wire-view: *** INSECURE MODE — payloads are neither encrypted nor authenticated ***")
        }

        // The return leg: everything client→host seals through the same
        // crypto seam and leaves from the listening socket, aimed at the
        // last datagram's source (wire-send today, the host tomorrow).
        let sender = TransportSender(crypto: crypto, transmit: { datagram in
            endpoint.sendToPeer(datagram)
        })
        // CL-10: the session's ONE host-clock model (timing pillar §2 —
        // audio rate correction and video presentation both read this
        // instance once they exist). Fed live per closed sample.
        let clockModel = HostClockModel()
        let echoResponder = BeaconEchoResponder(
            now: clientNow,
            onClockSample: { clockModel.ingest($0) },
            emit: { echo in
                _ = try? sender.send(channel: .ctrl, timestamp: clientNow(),
                                     plaintext: echo.encode())
            })
        echoBox.value = echoResponder
        // CL-7: the reliable CTRL sublayer — the client half of HS-8's
        // seam. Nothing host-side sends reliable traffic yet (W7
        // capabilities, HS-11 mode transitions are the consumers), so
        // today this delivers/acknowledges whatever arrives and carries
        // the debug ping; the wiring is what the slice lands.
        let reliable = ReliableCtrlEndpoint(
            sender: sender,
            onEvent: { event in
                switch event {
                case .message(let group, let bytes):
                    print("wire-view: reliable CTRL message group \(group.rawValue) " +
                          "(\(bytes.count) B, type 0x\(String(bytes.first ?? 0, radix: 16)))")
                case .oneShotAcknowledged(let group):
                    print("wire-view: reliable one-shot group \(group.rawValue) acknowledged")
                case .ignored:
                    break   // routine protocol weather; the stats line counts it
                }
            })
        reliable.start()
        reliableBox.value = reliable
        let idrRequester = IdrRequester(emit: { request in
            print("wire-view: IDR-REQUEST #\(request.requestSeq) → host " +
                  "(frame \(request.frame.rawValue), coalesced \(request.coalescedCount))")
            _ = try? sender.send(channel: .ctrl, timestamp: clientNow(),
                                 plaintext: request.encode())
        })
        idrBox.value = idrRequester
        let feedback = FeedbackSender(
            demux: endpoint.demux, sender: sender,
            onTick: { now in idrRequester.flushIfDue(now: now) })
        feedback.start()
        print("wire-view: feedback cadence \(feedback.cadenceMilliseconds) ms, " +
              "beacon echo + IDR-request on CTRL (NACK section empty until HS-17)")

        // The CL-7 live probe: reliable pings on the ordered stream. The
        // type byte 0x7F is a debug placeholder — unregistered, so the
        // host's dispatch only logs the delivery (which is the evidence:
        // exactly-once arrival plus the ACK that quiesces this end).
        let pinger: DispatchSourceTimer? = arqPing <= 0 ? nil : {
            let source = DispatchSource.makeTimerSource(queue: .global())
            source.schedule(deadline: .now() + .seconds(arqPing),
                            repeating: .seconds(arqPing))
            let counter = LockedCell<UInt32>(0)
            source.setEventHandler { @Sendable in
                let n = counter.value
                counter.value = n + 1
                var body: [UInt8] = [0x7F]
                withUnsafeBytes(of: n.littleEndian) { body += $0 }
                do {
                    try reliable.send(body)
                    print("wire-view: reliable ping #\(n) queued")
                } catch {
                    print("wire-view: reliable ping #\(n) refused: \(error)")
                }
            }
            source.resume()
            print("wire-view: reliable CTRL ping every \(arqPing)s (debug type 0x7f)")
            return source
        }()

        // The renderer's own verdict is the honest render evidence: it
        // goes .failed (with the VideoToolbox error) if enqueued samples
        // don't actually decode — enqueue counts alone can't lie-detect.
        let printer = WireViewStatsPrinter(
            demux: endpoint.demux, pipeline: pipeline,
            sender: sender, feedback: feedback,
            echoResponder: echoResponder, idrRequester: idrRequester,
            reliable: reliable, clockModel: clockModel,
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
            pinger?.cancel()
            feedback.stop()
            reliable.stop()
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
        streamRetainer.append(contentsOf: [
            delegate, ticker, sigint, endpoint, pipeline, window,
            sender, feedback, echoResponder, idrRequester, reliable,
        ])
        if let pinger { streamRetainer.append(pinger) }
    }
}

/// The CL-1 demux stats plus the CL-2 render stats plus the CL-3
/// return-path stats, one tick per second with new arrivals, full summary
/// at exit.
final class WireViewStatsPrinter: Sendable {
    private let demux: ReceiveDemux
    private let pipeline: LyteVideoPipeline
    private let sender: TransportSender
    private let feedback: FeedbackSender
    private let echoResponder: BeaconEchoResponder
    private let idrRequester: IdrRequester
    private let reliable: ReliableCtrlEndpoint
    private let clockModel: HostClockModel
    private let rendererState: @Sendable () -> String
    private let lastCount = LockedCell<UInt64>(0)

    init(demux: ReceiveDemux, pipeline: LyteVideoPipeline,
         sender: TransportSender, feedback: FeedbackSender,
         echoResponder: BeaconEchoResponder, idrRequester: IdrRequester,
         reliable: ReliableCtrlEndpoint, clockModel: HostClockModel,
         rendererState: @escaping @Sendable () -> String) {
        self.demux = demux
        self.pipeline = pipeline
        self.sender = sender
        self.feedback = feedback
        self.echoResponder = echoResponder
        self.idrRequester = idrRequester
        self.reliable = reliable
        self.clockModel = clockModel
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

        // The CL-3 return leg: what went back to the host.
        let out = sender.snapshotStats()
        let fb = feedback.snapshotStats()
        let echo = echoResponder.snapshotStats()
        let idr = idrRequester.snapshotStats()
        var back = "\(prefix)   sent: \(fb.reportsSent) feedback " +
                   "(\(fb.dispersionSamplesReported) dispersion samples), " +
                   "\(echo.echoesSent) echoes, \(idr.requestsSent) IDR-requests " +
                   "(\(idr.verdicts) verdicts)"
        if echo.clockSamples > 0 {
            back += ", \(echo.clockSamples) clock samples"
            if let last = echoResponder.snapshotClockSamples().last {
                // Interpolation, not %d: varargs %d truncates Int64 to 32
                // bits and boot-epoch offsets are ~10¹⁰ µs (found live —
                // the printed offset disagreed with CL-10's fit by 2·2³²).
                let sign = last.offsetMicroseconds >= 0 ? "+" : ""
                back += " (last offset \(sign)\(last.offsetMicroseconds) µs, " +
                        "rtt \(last.rttMicroseconds) µs)"
            }
        }
        if out.sendFailures > 0 { back += ", \(out.sendFailures) send-failed" }
        if out.sealFailures > 0 { back += ", \(out.sealFailures) seal-failed" }
        print(back)

        // The CL-7 reliable sublayer, when it has done anything at all.
        let arq = reliable.snapshotStats()
        if arq.messagesSent + arq.messagesDelivered + arq.datagramsSent > 0 {
            var line = "\(prefix)   arq: \(arq.messagesSent) sent, " +
                       "\(arq.messagesDelivered) delivered, " +
                       "\(arq.oneShotsAcknowledged) one-shot-acked, " +
                       "\(arq.datagramsSent) datagrams" +
                       (reliable.isQuiescent ? ", quiescent" : ", in flight")
            if arq.ingestIgnored > 0 { line += ", \(arq.ingestIgnored) ignored" }
            if arq.sendFailures > 0 { line += ", \(arq.sendFailures) send-failed" }
            print(line)
        }

        // The CL-10 model line: the T gate reads the residual here.
        if let fit = clockModel.estimate() {
            let sign = fit.offsetMicroseconds >= 0 ? "+" : ""
            print("\(prefix)   clock: offset \(sign)\(fit.offsetMicroseconds) µs, " +
                  String(format: "skew %+.1f ppm, residual rms %.1f / max %.1f µs, ",
                         fit.skewPartsPerMillion, fit.residualRmsMicroseconds,
                         fit.residualMaxMicroseconds) +
                  "\(fit.acceptedSamples)/\(fit.windowSamples) samples " +
                  "(min rtt \(fit.minRttMicroseconds) µs)")
        }
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
