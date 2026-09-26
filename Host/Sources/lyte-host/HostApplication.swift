// lyte-host: the direct eye (pixel observation + EGL blit + native VAAPI
// encode, HostEye) → an Annex-B file, or Lyte-UDP sessions on
// `--wire-listen PORT`: the Noise IK responder handshake, then capture →
// encode → VideoChannel → seal → Pacer → CNetIO.

import CNetIO
import Foundation
import HostCore
import HostEye
import HostIO
import HostSession
import HostWire
import LyteCore
import LyteIO
import LyteWire

@main
enum HostApplication {}

// MARK: - Options

struct Options {
    var outputPath = "/tmp/lyte-h0a.hevc"
    /// The leg's wall-clock bound. Given explicitly, the run serves one
    /// session; a --wire-listen run without it is the service.
    var seconds = 5.0
    var secondsGiven = false
    /// Bind here and await a connecting client.
    var wireListen: UInt16?
    /// The session rate ceiling: the estimator moves the pacer inside
    /// [500 kbps, this]. A permission, not a promise — capped-CQ keeps an
    /// idle desktop far below it.
    var wireRateMbps = 50.0
    /// Pin the advertisement to one interface so discovery never hands
    /// clients the radio's address. Empty = all interfaces.
    var advertiseInterface = ""
    /// Advertise `_lyte._udp` via Avahi while listening; Avahi being
    /// unavailable degrades to manual host:port, never a failure.
    var advertise = true
    /// Mint and print a PIN and run the CPace responder over the reliable
    /// CTRL stream; on success the client's static is pinned.
    var pair = false
    /// Only statics already in paired_clients may complete the handshake.
    var requirePaired = false
    /// auto and uinput both mean kernel uinput; off disables input.
    var input: InputBackendChoice = .auto
    /// Desktop audio on the wire (continuous 5 ms CBR from establishment).
    var audio = true
    /// Opus hard-CBR bitrate.
    var audioBitrate: Int32 = 128_000
    /// The starting audio-routing posture: audible keeps the host's
    /// speakers (default-sink monitor); muted moves the default to the
    /// "Lyte Audio" virtual sink. A client can flip it (0x18).
    var hostAudio: HostAudioRoutingMode = .hostAudible
    /// Text clipboard sync, opt-in; key 10 is declared only when the leaf
    /// came up.
    var clipboard = false
    /// `--clipboard=images` sets both flags; key 12 is declared only when
    /// the leaf came up with images enabled.
    var clipboardImages = false
    /// The standing per-host consent for incoming files, opt-in. Off =
    /// no key 11 and any chan-8 byte is a protocol violation. The drop
    /// directory defaults to ~/Downloads, created if missing.
    var acceptFiles = false
    var acceptFilesDirectory: String?
    /// The retry-cookie dial's thresholds (message 1s per second):
    /// require-cookie mode engages at `cookieEnter` and clears at
    /// `cookieExit`, which must be lower.
    var cookieEnter = 20
    var cookieExit = 5
    /// The DRM card node whose primary plane is captured; nil captures
    /// the first card that scans out.
    var drmDevice: String?
    /// File mode's encoder chroma; a session's is the client's.
    var fileChroma: ChromaPosture = .yuv420

    static let usage = """
        usage: lyte-host --wire-listen PORT [--seconds N] [session flags]
               lyte-host [--out PATH] [--seconds N] [--chroma 420|444]
               lyte-host sniff --port PORT [--seconds N] [--count N]
          --wire-listen PORT      serve Lyte-UDP sessions on PORT; without
                                  --seconds or --pair, in turn (the service)
          --seconds N             one session, or the file leg, of N s
          --drm-device PATH       the card to capture (default: the one
                                  scanning out)
          --out PATH              file mode's Annex-B output
          --chroma 420|444        file mode's encoder chroma
        session flags:
          --wire-rate-mbps N      rate ceiling (default 50)
          --no-advertise          no Avahi _lyte._udp record
          --advertise-interface IFACE
          --pair                  mint a PIN and pair one client
          --require-paired        admit only paired clients
          --cookie-enter N        msg1/s that demands retry cookies (20)
          --cookie-exit N         msg1/s that clears the demand (5)
          --input auto|uinput|off input injection (auto = uinput)
          --no-audio              no audio leg
          --audio-bitrate-kbps N  Opus CBR bitrate, 1-512 (default 128)
          --host-audio audible|muted
          --clipboard[=images]    clipboard sync consent
          --accept-files[=DIR]    file-drop consent (default ~/Downloads)
        Details: Host/README.md.
        """

    /// Flags only file mode reads, and flags either mode reads; every
    /// other flag means nothing without --wire-listen.
    private static let fileOnlyFlags: Set<Substring> = ["--out", "--chroma"]
    private static let eitherModeFlags: Set<Substring> = [
        "--seconds", "--drm-device", "--wire-listen",
    ]

    static func parse(_ args: [String]) throws -> Options {
        var opts = Options()
        var fileFlags: [Substring] = []
        var sessionFlags: [Substring] = []
        var cursor = ArgumentCursor(args.dropFirst())
        while let flag = cursor.next() {
            switch flag {
            case "--out":
                opts.outputPath = try cursor.value(flag, "a path") { $0 }
            case "--chroma":
                opts.fileChroma = try cursor.value(flag, "420 or 444") {
                    ["420": .yuv420, "444": .yuv444][$0]
                }
            case "--seconds":
                opts.seconds = try cursor.positive(flag)
                opts.secondsGiven = true
            case "--drm-device":
                opts.drmDevice = try cursor.value(
                    flag, "an absolute card path") { $0.hasPrefix("/") ? $0 : nil }
            case "--wire-listen":
                opts.wireListen = try cursor.port(flag)
            case "--wire-rate-mbps":
                opts.wireRateMbps = try cursor.positive(flag)
            case "--no-advertise":
                opts.advertise = false
            case "--advertise-interface":
                opts.advertiseInterface = try cursor.value(flag, "a name") {
                    $0.isEmpty ? nil : $0
                }
            case "--pair":
                opts.pair = true
            case "--require-paired":
                opts.requirePaired = true
            case "--input":
                opts.input = try cursor.value(flag, "auto, uinput or off") {
                    InputBackendChoice(rawValue: $0)
                }
            case "--no-audio":
                opts.audio = false
            case "--audio-bitrate-kbps":
                opts.audioBitrate = try cursor.value(flag, "1 to 512") {
                    Int32($0).flatMap { (1...512).contains($0) ? $0 * 1_000 : nil }
                }
            case "--host-audio":
                opts.hostAudio = try cursor.value(flag, "audible or muted") {
                    ["audible": .hostAudible, "muted": .hostMuted][$0]
                }
            case "--clipboard":
                opts.clipboard = true
            case "--clipboard=images":
                opts.clipboard = true
                opts.clipboardImages = true
            case "--accept-files":
                opts.acceptFiles = true
            case let arg where arg.hasPrefix("--accept-files="):
                let dir = String(arg.dropFirst("--accept-files=".count))
                guard !dir.isEmpty else {
                    throw HostError("--accept-files= needs a directory")
                }
                opts.acceptFiles = true
                opts.acceptFilesDirectory = dir
            case "--cookie-enter":
                opts.cookieEnter = try cursor.value(flag, "a positive integer") {
                    Int($0).flatMap { $0 >= 1 ? $0 : nil }
                }
            case "--cookie-exit":
                opts.cookieExit = try cursor.value(
                    flag, "a non-negative integer") {
                    Int($0).flatMap { $0 >= 0 ? $0 : nil }
                }
            case "--help", "-h":
                Swift.print(usage)
                exit(0)
            default:
                throw HostError("unknown argument \(flag) (try --help)")
            }
            let name = flag.prefix { $0 != "=" }
            if fileOnlyFlags.contains(name) {
                fileFlags.append(name)
            } else if !eitherModeFlags.contains(name) {
                sessionFlags.append(name)
            }
        }
        if opts.wireListen == nil, let flag = sessionFlags.first {
            throw HostError("\(flag) needs --wire-listen")
        }
        if opts.wireListen != nil, let flag = fileFlags.first {
            throw HostError("\(flag) is file mode's; drop --wire-listen")
        }
        guard opts.cookieExit < opts.cookieEnter else {
            throw HostError("""
                --cookie-exit (\(opts.cookieExit)) must be below \
                --cookie-enter (\(opts.cookieEnter))
                """)
        }
        return opts
    }

    /// The handshake gate every run arms. The retry-cookie dial is always
    /// armed: it costs nothing until a message-1 flood crosses the enter
    /// threshold, and without it a spoofed flood starves every honest dial
    /// from the shared token bucket. The secret is process-random: the
    /// host both mints and verifies, and no cookie outlives the process.
    func handshakeGateConfig(
        using rng: inout some RandomNumberGenerator
    ) -> HandshakeGate.Config {
        var secret = [UInt8](repeating: 0, count: RetryCookie.secretByteCount)
        for i in secret.indices {
            secret[i] = UInt8.random(in: 0...255, using: &rng)
        }
        return HandshakeGate.Config(
            cookieSecret: secret,
            cookieEnterThreshold: cookieEnter,
            cookieExitThreshold: cookieExit)
    }
}

// MARK: - Pairing surface

/// `.paired` is the keystore write; everything else is a console line.
func handlePairingEvent(_ event: PairingResponderService.Event) {
    switch event {
    case .attemptOpened(let attempt, let of):
        print("pairing: attempt \(attempt)/\(of) — share B sent")
    case .paired(let key):
        let hex = Hex.string(key)
        do {
            let paths = try HostPaths.current()
            var store = try PairedClients.load(paths: paths)
            if store.pin(key, note: """
                paired \(ISO8601DateFormatter().string(from: Date()))
                """) {
                try PairedClients.save(store, paths: paths)
                print("""
                    pairing: PAIRED — client static \(hex) pinned → \
                    \(try PairedClients.path(paths: paths))
                    """)
            } else {
                print(
                    "pairing: PAIRED — client static \(hex) was already pinned")
            }
        } catch {
            // Only persistence failed: loud, not fatal to the session.
            print("""
                pairing: PAIRED but the keystore write FAILED \
                (\(error)) — pin \(hex) by hand
                """)
        }
    case .rejected(let reason, let remaining):
        print("""
            pairing: REJECTED (\(reason)) — \(remaining) attempt(s) \
            remain on this PIN
            """)
    case .clientAborted(let reason):
        print("""
            pairing: client aborted (\(reason)) — its PIN entry \
            disagreed with ours
            """)
    case .throttled:
        print("pairing: attempt inside the 1 s throttle window — dropped")
    case .pinBurned:
        print("""
            pairing: PIN BURNED — guess budget spent; pairing stays \
            silent until a rerun of --pair mints a fresh PIN
            """)
    case .malformed:
        print("pairing: malformed pairing bytes dropped")
    }
}

// MARK: - Main

/// The organs of a session-mode run that outlive any one session. Each
/// session gets a fresh SessionWire, audio leaf, capture leg and
/// file-drop shell.
final class SessionHost {
    let opts: Options
    let pairingService: PairingResponderService?
    let clipboardLeaf: MutterClipboardLeaf?
    let declared: Capabilities
    /// The listening socket and handshake admission, one for the run.
    let listener: HostListener
    let injector: InputInjector?
    /// Releasing it withdraws the record.
    private let advertiser: AvahiAdvertiser?
    /// Set when file drop came up at bring-up (key 11 declared on it).
    private let dropDirectory: String?
    /// The bring-up shell goes to the first session; later sessions get
    /// a fresh shell that reloads the persisted resume states.
    private var firstBulkShell: BulkReceiveShell?

    init(opts: Options, port: UInt16, screen: DirectScreenSource) throws {
        self.opts = opts
        if opts.pair, opts.requirePaired {
            throw HostError("""
                --pair admits a not-yet-paired client; \
                --require-paired contradicts it
                """)
        }
        if !opts.audio, opts.hostAudio == .hostMuted {
            throw HostError("""
                --host-audio muted routes audio to the wire \
                instead of the speakers; --no-audio contradicts it
                """)
        }

        // Before the socket exists, so a bad keystore fails the run
        // instead of a live session.
        let paths = try HostPaths.current()
        let keys = try HostStaticKey.loadOrCreate(paths: paths)
        let allowed: [[UInt8]]?
        if opts.requirePaired {
            let store = try PairedClients.load(paths: paths)
            guard !store.entries.isEmpty else {
                throw HostError("""
                    --require-paired with an empty keystore would lock every \
                    client out — run --pair once first
                    """)
            }
            allowed = store.publicKeys
            print("""
                pairing: enforcing \(store.entries.count) paired \
                client static(s) from \(try PairedClients.path(paths: paths))
                """)
        } else {
            allowed = nil
        }
        if opts.pair {
            var rng = SystemRandomNumberGenerator()
            let pin = PairingResponderService.mintPin(using: &rng)
            pairingService = PairingResponderService(
                pin: Array(pin.utf8),
                hostStaticPublicKey: keys.publicKey
            )
            print("""
                pairing: PIN \(pin) — enter it on the client (3 wrong guesses \
                burn it; rerun --pair for a fresh one)
                """)
        } else {
            pairingService = nil
        }

        // Restore a default sink a killed previous run stranded, and arm
        // the SIGINT/SIGTERM flag so an interrupted run still restores.
        AudioWire.sweepLeftoverRouting()
        lyteInstallTerminationHandlers()

        // The leaf comes up before the declaration: key 10 follows the
        // leaf, never the flag alone.
        var leafUp: MutterClipboardLeaf?
        if opts.clipboard {
            do {
                let leaf = try MutterClipboardLeaf(
                    imagesEnabled: opts.clipboardImages
                )
                try leaf.start()
                leafUp = leaf
                let tier = opts.clipboardImages ? "text + images" : "text only"
                print("clipboard: leaf up — \(tier)")
            } catch {
                print("""
                    clipboard: leaf unavailable (\(error)) — \
                    clipboard sync OFF this run, key 10 not declared
                    """)
            }
        }
        clipboardLeaf = leafUp

        // Likewise key 11 follows the toggle and a usable directory.
        // Consent is this standing toggle; Wire never sees it.
        var drop: String?
        if opts.acceptFiles {
            let dropDir = opts.acceptFilesDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads").path
            do {
                firstBulkShell = try BulkReceiveShell(directoryPath: dropDir)
                drop = dropDir
                print("files: accepting incoming transfers → \(dropDir)")
            } catch {
                print("""
                    files: drop directory unavailable (\(error)) — \
                    file drop OFF this run, key 11 not declared
                    """)
            }
        }
        dropDirectory = drop

        // Declare only what this run can honor: keys 9, 14 and 15 with
        // the audio leg, 10 and 12 with the clipboard leaf, 11 with the
        // drop directory.
        var declared = opts.audio
            ? Capabilities.wireDefault.declaringHostAudioRouting()
                .declaringAudioStreamOff()
                .declaringAudioQuietPosture()
            : .wireDefault
        if leafUp != nil {
            declared = declared.declaringClipboardText()
            // Key 12 is independent of key 11's file consent.
            if opts.clipboardImages {
                declared = declared.declaringClipboardImages()
            }
        }
        if drop != nil {
            declared = declared.declaringBulkTransfer()
        }
        // The cursor plane travels as metadata, never composited.
        declared = declared.declaringCursorShape()
        declared = declared.declaringVideoQuietPosture()

        // Chroma is declared on proof: only a Main444 encode entrypoint
        // declares the Best tier. The client's singleton declaration
        // picks the session's posture.
        if EyeVaapiEncoder.probesMain444(renderNode: screen.renderNode) {
            declared.chromaModes = [
                CapabilityChroma.yuv420, CapabilityChroma.yuv444,
            ]
            print("chroma: declaring [420, 444]")
        } else {
            print("chroma: no Main444 encode entrypoint — declaring [420]")
        }
        self.declared = declared

        var rng = SystemRandomNumberGenerator()
        listener = try HostListener(
            port: port,
            acceptor: HandshakeAcceptor.Config(
                hostStatic: keys,
                gate: opts.handshakeGateConfig(using: &rng),
                allowedClientStaticPublicKeys: allowed))

        // Up before the first handshake wait; the advertiser re-files
        // the record whenever it is withdrawn (`serviceOrgans`).
        advertiser = opts.advertise
            ? AvahiAdvertiser(
                port: port,
                staticPublicKey: keys.publicKey,
                interfaceName: opts.advertiseInterface)
            : nil

        // Injection is ready before any client connects and stays up
        // across sessions; each session's end releases what it held.
        injector = makeInputInjector(opts.input)
        if let injector {
            injector.noteMonitorExtent(
                width: UInt32(screen.width), height: UInt32(screen.height))
            print("input: injection via \(injector.name)")
        }
    }

    /// The file-drop shell for the next session; nil when file drop is
    /// off, or when the directory stopped being usable.
    func takeBulkShell() -> BulkReceiveShell? {
        if let shell = firstBulkShell {
            firstBulkShell = nil
            return shell
        }
        guard let dropDirectory else { return nil }
        do {
            return try BulkReceiveShell(directoryPath: dropDirectory)
        } catch {
            print("""
                files: drop directory unavailable (\(error)) — \
                file drop OFF this session
                """)
            return nil
        }
    }

    /// Runs on the handshake wait's idle pass between sessions and on a
    /// session's janitor during one — never both at once.
    func serviceOrgans() {
        clipboardLeaf?.service()
        advertiser?.service()
    }

    /// Destroys the input devices (releasing anything held) and closes
    /// the clipboard leaf's RemoteDesktop session.
    func stop() {
        injector?.stop()
        clipboardLeaf?.stop()
    }
}

/// One served session's end and its leg's stream evidence.
struct ServedSession {
    var end: HostServiceLoop.SessionEnd
    var leg: HostServiceLoop.LegEvidence
}

private extension HostApplication {
static func run(arguments: [String]) throws {
    let opts = try Options.parse(arguments)
    // The cap_sys_admin file capability clears the dumpable flag at
    // exec; re-arm it for crash forensics. /proc/self/exe stays
    // ptrace-guarded regardless (the capability-subset rule).
    if lyte_set_dumpable() != 0 {
        print("""
            host: WARNING — could not restore dumpability \
            (coredumps stay disabled)
            """)
    }

    let destination = opts.wireListen
        .map { "lyte-udp sessions on :\($0) (noise)" } ?? opts.outputPath
    print("lyte-host — direct eye → native VAAPI → \(destination)")

    // The scanout opens first: its geometry scales the injector's
    // absolute moves. It and the eye's GL context live for the run.
    let screen = try DirectEyeLeg.openScreen(
        device: opts.drmDevice)
    let eye = WarmEye(screen: screen)
    guard let port = opts.wireListen else {
        try runFileLeg(opts, screen: screen, eye: eye)
        return
    }

    let host = try SessionHost(opts: opts, port: port, screen: screen)
    defer { host.stop() }
    var loop = HostServiceLoop(posture: HostServiceLoop.posture(
        secondsGiven: opts.secondsGiven,
        pairing: opts.pair,
        seconds: opts.seconds))
    if loop.posture == .service {
        print("service: serving sessions in turn")
    }
    while true {
        let served = try serveSession(
            host, eye: eye, screen: screen,
            sessionSeconds: loop.sessionSeconds)
        switch loop.sessionEnded(served.end, leg: served.leg) {
        case .serveAnother:
            print("""
                service: session \(loop.sessionsServed) closed \
                (\(served.end)) — awaiting the next client
                """)
            HostLogBound.check()
        case .exit(failure: nil):
            return
        case .exit(failure: let failure?):
            throw HostError(failure)
        }
    }
}

/// The probe mode: one leg into an Annex-B file.
static func runFileLeg(
    _ opts: Options, screen: DirectScreenSource, eye: WarmEye
) throws {
    guard let file = fopen(opts.outputPath, "wb") else {
        throw HostError("cannot open \(opts.outputPath) for writing")
    }
    let leg = DirectEyeLeg(
        config: .init(seconds: opts.seconds, fileChroma: opts.fileChroma),
        screen: screen, eye: eye, wire: nil, file: file)
    leg.run()
    fclose(file)
    let evidence = printLegSummary(leg)
    print("output: \(opts.outputPath)")
    var loop = HostServiceLoop(posture: .singleSession(seconds: opts.seconds))
    if case .exit(failure: let failure?) = loop.sessionEnded(
        leg.end, leg: evidence) {
        throw HostError(failure)
    }
}

/// One session, from the handshake wait to the books. The wire, the
/// audio leaf, the leg and the file-drop shell are this session's and
/// are released before it returns; the host's organs stay up.
static func serveSession(
    _ host: SessionHost, eye: WarmEye, screen: DirectScreenSource,
    sessionSeconds: Double
) throws -> ServedSession {
    let opts = host.opts
    // The session comes up before capture, so the first encoded frame
    // is the session's first IDR.
    let w = try SessionWire(
        listener: host.listener,
        rateBitsPerSecond: Int(opts.wireRateMbps * 1_000_000),
        capabilities: host.declared,
        pairing: host.pairingService,
        onPairingEvent: handlePairingEvent
    )
    defer { w.release() }
    w.inputInjector = host.injector
    let awaitOutcome: SessionWire.ClientAwaitOutcome
    do {
        // Unattached, the clipboard leaf still serves host pastes and
        // drains host copies unread.
        awaitOutcome = try w.awaitClient(
            timeoutSeconds: nil,
            stopRequested: { lyteTerminationRequested != 0 },
            idle: { host.serviceOrgans() })
    } catch {
        w.shutdown(reason: .shuttingDown, lingerSeconds: 0)
        throw error
    }
    if awaitOutcome == .terminationRequested {
        print("session: termination requested before handshake — clean stop")
        w.shutdown(reason: .shuttingDown, lingerSeconds: 0)
        return ServedSession(
            end: .terminatedBeforeHandshake,
            leg: .init(frames: 0, firstPacketStartsStream: false))
    }
    print("session: up — pacer ceiling \(opts.wireRateMbps) Mbps")

    // The estimator's ceiling reaches the encoder as rate directives.
    // The baseline mirrors the encoder's opening posture: VBR under the
    // wire-rate cap, VBV at the unprotectable-frame guard's ceiling, so
    // a restore can never re-open the >255-shard hole.
    let guardBits = w.worstCaseProtectableFrameCeiling * 8
    // The native seat applies rate moves without a reset.
    w.armEncoderVbv(EncoderVbvConfig(
        fps: DirectEyeLeg.fps,
        baselineMaxBitsPerSecond: Int(opts.wireRateMbps * 1_000_000),
        baselineVbvBits: guardBits
    ))

    w.shellServiceHook = { [weak host] in
        host?.serviceOrgans()
    }
    // Client sets apply through the leaf; leaf-observed changes (echoes
    // included — the session's book suppresses them) flow back. Attach
    // drains what changed while no session was live, unread.
    if let leaf = host.clipboardLeaf {
        leaf.attach()
        w.clipboardApplyHandler = { [weak leaf] text in
            leaf?.apply(text: text)
        }
        leaf.onLocalChange = { [weak w] text in
            w?.noteHostClipboardChanged(text)
        }
        // Images ride the same seams.
        if opts.clipboardImages {
            w.clipboardImageApplyHandler = { [weak leaf] data in
                leaf?.apply(imageData: data)
            }
            leaf.onLocalImageChange = { [weak w] data in
                w?.noteHostClipboardImageChanged(data)
            }
        }
    }

    let bulkShell = host.takeBulkShell()
    w.bulkShell = bulkShell

    // Audio runs on its own thread, continuous 5 ms CBR from
    // establishment, silence included. Failure degrades to a warning:
    // the screen must stream even if audio cannot. The loop deadline is
    // only a backstop behind stop() (a year for a service session).
    let audioSeconds = sessionSeconds.isFinite
        ? sessionSeconds + 20.0 : 366 * 86_400
    var audioWire: AudioWire?
    if opts.audio {
        do {
            let audio = try AudioWire(
                wire: w, bitrate: opts.audioBitrate, mode: opts.hostAudio
            )
            audio.start(seconds: audioSeconds)
            audioWire = audio
            w.setInitialAudioRouting(opts.hostAudio)
            w.audioRoutingHandler = { requested, standing in
                // Runs on the janitor thread, off the session lock. The
                // stream pauses across the rebuild so two leaves never
                // overlap.
                audioWire?.stop()
                audioWire = nil
                let running = AudioRoutingFlip.apply(
                    requested: requested, standing: standing
                ) { mode in
                    do {
                        let leaf = try AudioWire(
                            wire: w, bitrate: opts.audioBitrate, mode: mode)
                        leaf.start(seconds: audioSeconds)
                        audioWire = leaf
                        return true
                    } catch {
                        print("audio-routing: rebuild in \(mode) failed (\(error))")
                        return false
                    }
                }
                if running == .streamOff {
                    print("""
                        audio-routing: stream OFF — the wire carries no audio \
                        track (host speakers unaffected)
                        """)
                }
                return running
            }
            let capture = opts.hostAudio == .hostMuted
                ? "\"Lyte Audio\" sink (host muted)"
                : "default-sink monitor (host audible)"
            print("audio: \(capture) → opus \(opts.audioBitrate / 1_000) kbps")
        } catch {
            print("audio: unavailable (\(error)) — video-only session")
        }
    }

    let leg = DirectEyeLeg(
        config: .init(
            seconds: sessionSeconds,
            bitrateBitsPerSecond: Int64(opts.wireRateMbps * 1_000_000),
            vbvBits: guardBits),
        screen: screen, eye: eye, wire: w, file: nil)
    leg.run()

    // Audio stops before the teardown so its last shards leave ahead of
    // the 0x0A. The routing handler can no longer run (the janitor has
    // stopped with the leg).
    let finalAudio = audioWire
    finalAudio?.stop()
    audioWire = nil

    w.shutdown(reason: .shuttingDown)
    // The devices and the leaf outlive the session: nothing its client
    // held may stay pressed, and the leaf stops reporting into it.
    if let released = host.injector?.releaseHeld(.everything), released > 0 {
        print("input: released \(released) held key(s) at session end")
    }
    host.clipboardLeaf?.detach()
    host.clipboardLeaf?.onLocalChange = nil
    host.clipboardLeaf?.onLocalImageChange = nil
    // Persists mid-flight resume state so the next session's re-offer
    // resumes from the gap.
    bulkShell?.teardown()

    w.endPairing()
    let evidence = printLegSummary(leg)
    printSessionBooks(
        wire: w, leg: leg, audio: finalAudio, host: host,
        bulkShell: bulkShell)
    if let pairing = host.pairingService {
        if let key = pairing.pairedClientStaticPublicKey {
            print("pairing: result — PAIRED, client \(Hex.string(key))")
        } else if pairing.isBurned {
            print("pairing: result — PIN burned, nothing pinned")
        } else {
            print("pairing: result — no client paired this run")
        }
    }
    return ServedSession(end: leg.end, leg: evidence)
}

/// The leg's closing lines; returns the evidence the service loop
/// judges. The first packet must carry VPS/SPS/PPS + IRAP or the client
/// can never join.
static func printLegSummary(
    _ leg: DirectEyeLeg
) -> HostServiceLoop.LegEvidence {
    let startsStream = AnnexBCheck.startsWithParameterSetsAndIrap(
        leg.firstPacket)
    if leg.frames > 0 {
        print("""
            first packet NALs: \(AnnexBCheck.summary(of: leg.firstPacket))\
            \(startsStream ? " — parameter sets + IDR: OK" : "")
            """)
    }
    return HostServiceLoop.LegEvidence(
        frames: leg.frames, firstPacketStartsStream: startsStream)
}

static func printSessionBooks(
    wire: SessionWire, leg: DirectEyeLeg, audio: AudioWire?,
    host: SessionHost, bulkShell: BulkReceiveShell?
) {
    let opts = host.opts
    let clipboardLeaf = host.clipboardLeaf
    let t = wire.pacerTelemetry
    let c = wire.counters
    let s = wire.sessionCounters
    let o = wire.outboxCounters
    let h = host.listener.acceptor.counters
    var vbvFinal = ""
    if let d = wire.lastVbvDirective {
        vbvFinal = """
             — final max \(d.maxBitsPerSecond / 1_000) kbps, vbv \
            \(d.vbvBits / 8) B (ceiling \(d.frameByteCeiling) B)
            """
    }
    var bulkShellStats = ""
    if let shell = bulkShell {
        let b = shell.counters
        bulkShellStats = " (shell: \(b.offersAccepted) accepted"
        bulkShellStats += ", \(b.chunksStored) chunks"
        bulkShellStats += " / \(b.bytesStored) B stored"
        bulkShellStats += ", \(b.filesCompleted) completed"
        bulkShellStats += ", \(b.transfersAborted) aborted"
        bulkShellStats += ", \(b.offersRefusedBusy) busy"
        bulkShellStats += ", \(b.storageFailures) storage failures"
        bulkShellStats += ", \(b.resumeStatesLoaded) resumes loaded)"
    }
    var clipboardLeafStats = ""
    if let leaf = clipboardLeaf {
        clipboardLeafStats = " (leaf: \(leaf.appliesTaken) applies"
        clipboardLeafStats += ", \(leaf.changesReported) changes reported"
        clipboardLeafStats += ", \(leaf.imageAppliesTaken) image applies"
        clipboardLeafStats += ", \(leaf.imageChangesReported) image changes"
        clipboardLeafStats += ", \(leaf.transfersServed) transfers served"
        clipboardLeafStats += ", \(leaf.transfersFailed) failed"
        clipboardLeafStats += ", \(leaf.readsAbandoned) reads abandoned"
        clipboardLeafStats += ", \(leaf.nonTextChangesIgnored) non-text ignored"
        clipboardLeafStats += ", \(leaf.baselineReplaysSkipped) baseline skipped"
        clipboardLeafStats += ", \(leaf.changesOutsideSessionSkipped) outside a session)"
    }
    print("""
    session: \(c.framesIngested) frames → \(c.shardsEnqueued) shards → \
    \(o.datagramsSent) datagrams (\(o.bytesSent) B) in \
    \(t.batches) paced batches; max batch wire time \
    \(t.maxBatchWireTimeNS) ns (quantum 1000000); freshVideo max queue \
    delay \(t[.freshVideo].maxQueueDelayNS) ns
    socket: \(o.wouldBlockCount) would-block retries, pending max \
    \(o.pendingMaxDatagrams) datagrams / \
    \(o.pendingMaxBytes) B; audio blocked \
    \(o.audioWouldBlockCount) times, outbox max \
    \(o.audioOutboxMaxNS) ns at seq \
    \(o.audioWorstSeq.map(String.init) ?? "—") \
    (enqueued/accepted \
    \(o.audioWorstEnqueuedAtNS.map(String.init) ?? "—")/\
    \(o.audioWorstAcceptedAtNS.map(String.init) ?? "—"), \
    behind video \(o.audioWorstBlockedByVideo)); kernel sndbuf \
    \(wire.socketSendBufferBytes) B, outq max \
    \(wire.socketOutqMaxBytes) B; latency lane sndbuf \
    \(wire.latencySocketSendBufferBytes) B, outq max \
    \(wire.latencySocketOutqMaxBytes) B; ENOBUFS \
    \(o.noBufferCount), outq query failures \
    \(wire.socketOutqQueryFailures); pressure \
    \(wire.kernelPressureState), video debt \
    \(wire.kernelVideoServiceDebtNS) ns, EAGAIN video/latency \
    \(o.videoWouldBlockCount)/\
    \(o.latencyWouldBlockCount), ENOBUFS video/latency \
    \(o.videoNoBufferCount)/\
    \(o.latencyNoBufferCount), transient send/receive errors \
    \(o.transientErrors)/\(wire.receiveTransientErrors), ICMP refusals \
    ignored on a live path \(wire.refusalsWhileLive) and off the \
    primary \(wire.offPrimaryRefusals), stale fresh shed \
    \(o.freshVideoShedDatagrams) datagrams / \
    \(o.freshVideoShedBytes) B
    session: \(s.beaconsSent) beacons, \(s.beaconEchoes) echoes \
    (last offset \(wire.clock.lastOffsetMicroseconds.map(String.init) ?? "—") µs, \
    min rtt \(wire.clock.minRttMicroseconds.map(String.init) ?? "—") µs), \
    \(s.idrRequests) IDR requests \
    (\(s.idrRequestsSupersededByKeyframe) superseded retries), \
    \(s.unsealFailures) unseal failures, \
    \(s.ctrlQueueFullRefusals)/\(s.bulkQueueFullRefusals) ctrl/bulk \
    arq queue-full refusals, \
    \(s.feedbackDatagrams) feedback datagrams
    handshake-flood (since start): \(h.throttled) msg1 throttled, \
    \(h.answeredBefore) answered before, \(h.challengesMinted) cookies \
    minted (0x13), \(h.cookiesVerified) verified / \(h.cookiesRejected) \
    rejected (0x14), require-cookie now \
    \(host.listener.acceptor.cookieMode ? "ON" : "off")
    lifecycle: \(s.modeTransitionsSent) mode transitions, \
    \(s.videoFramesSuppressed) frames suppressed (FROZEN/closed), \
    \(s.videoFramesUnprotectable) dropped unprotectable \
    (ceiling \(wire.protectableFrameCeiling) B), \
    final state \(wire.lifecycleState.map { "\($0)" } ?? "—") \
    (wire mode \(wire.currentWireMode.map { "\($0)" } ?? "—"))
    chroma: agreed \(wire.agreedChromaModes.map { "\($0)" } ?? "— (no declaration)"), \
    encoder \(leg.chroma444Active ? "4:4:4 (Rext)" : "4:2:0") (native VAAPI)
    input: \(s.inputEventsReceived) events received, \
    \(wire.inputInjected) injected \
    (\(wire.inputInjectFailures) failed), \
    \(s.inputEchoTuplesSent) echo tuples sent; receive→inject \
    p50 \(wire.inputLatency.p50.map(String.init) ?? "—") µs / \
    p99 \(wire.inputLatency.p99.map(String.init) ?? "—") µs / \
    max \(wire.inputLatency.maxValue.map(String.init) ?? "—") µs\
    \(Self.windowNote(wire.inputLatency, SessionWire.inputLatencyWindow))
    audio: \(s.audioPacketsIngested) packets → \
    \(s.audioDatagramsEnqueued) datagrams \
    (\(s.audioGroupsCompleted) RS 4+2 groups, \
    \(s.audioGroupsAbandoned) abandoned), \
    \(s.audioPacketsSuppressed) suppressed, \
    \(wire.audioSendFailures) send failures, \
    \(wire.audioPacketsDroppedPreSession) dropped pre-session; \
    max audio queue delay \(t[.audio].maxQueueDelayNS) ns; \
    mailbox depth max \(wire.audioMailboxMaxDepth), \
    dwell p99 \(wire.audioMailboxDwell.p99.map(String.init) ?? "—") ns / \
    max \(wire.audioMailboxMaxDwellNS) ns\
    \(Self.windowNote(
        wire.audioMailboxDwell, SessionWire.audioMailboxDwellWindow
    )), \
    overflows \(wire.audioMailboxOverflows)
    session-lock: video prepare max \(wire.videoPrepareMaxNS) ns off-lock, \
    commit wait/hold max \(wire.videoCommitLockWaitMaxNS)/\
    \(wire.videoCommitLockHoldMaxNS) ns, service/receive max \
    \(wire.serviceOnceMaxNS)/\(wire.receiveAllMaxNS) ns; \(wire.drainPasses) \
    sender passes, \(wire.receiveCalls) recvmmsg calls, \(wire.outqQueries) \
    SIOCOUTQ queries
    audio-routing: final \(wire.currentAudioRouting), \
    \(s.audioRoutingRequestsReceived) flip requests, \
    \(s.audioRoutingStatusesSent) statuses sent
    clipboard: leaf \(clipboardLeaf != nil ? "ACTIVE" : "none"), \
    \(s.clipboardSetsReceived) sets received, \
    \(s.clipboardAnnouncesSent) announces sent, \
    \(s.clipboardAnnouncesSuppressed) suppressed\(clipboardLeafStats)
    cursor: \(s.cursorShapesSent) shapes sent (0x24), \
    \(s.cursorShapesSuppressed) suppressed
    clipboard-images: tier \(opts.clipboardImages ? "ON" : "off"), \
    \(wire.clipboardImageCounters.sharesCompleted)/\
    \(wire.clipboardImageCounters.sharesStarted) shares completed, \
    \(wire.clipboardImageCounters.imagesApplied) applied, \
    \(wire.clipboardImageCounters.sharesSuppressed) suppressed, \
    \(wire.clipboardImageCounters.receivesRefused) refused, \
    \(wire.clipboardImageCounters.sharesAborted)+\
    \(wire.clipboardImageCounters.receivesAborted) aborted
    files: \(bulkShell != nil ? "ACCEPTING" : "off"), \
    \(s.bulkMessagesReceived) bulk messages received, \
    \(s.bulkArqDatagramsSent) chan-8 datagrams sent\(bulkShellStats)
    estimator: rate \(wire.estimatedRate / 1_000) kbps \
    (pacer \(wire.pacerRate / 1_000) kbps, ceiling \
    \(Int(opts.wireRateMbps * 1_000)) kbps), delivery \
    \(wire.measuredDeliveryRate.map { "\($0 / 1_000) kbps" } ?? "—") \
    (burst max \(wire.deliveryRate.map { "\($0 / 1_000)" } ?? "—"), \
    belief \(wire.capacityBelief.map { "\($0 / 1_000)" } ?? "—")), \
    queuing delay \(wire.queuingDelayMicros.map { "\($0) µs" } ?? "—"); \
    \(wire.estimatorStats.reportsIngested) reports \
    (\(s.feedbackReportsParsed) parsed, \
    \(s.feedbackReportsMalformed) malformed), \
    \(wire.estimatorStats.deliverySamples) delivery samples \
    (\(wire.estimatorStats.dispersionSamplesMatched) matched / \
    \(wire.estimatorStats.dispersionSamplesUnmatched) unmatched; \
    \(wire.estimatorStats.honestSamples) honest / \
    \(wire.estimatorStats.censoredSamples) censored full trains \
    (\(wire.estimatorStats.stretchedTrainsRecused) hole-recused, \
    \(wire.estimatorStats.burstGeometryTrainsRecused) burst-recused), \
    \(wire.estimatorStats.beliefRaises) belief raises / \
    \(wire.estimatorStats.beliefDemotions) demotions), \
    \(wire.estimatorStats.downshifts) downshifts \
    (\(wire.estimatorStats.lossDownshifts) loss, \
    \(wire.estimatorStats.overuseVerdicts) overuse verdicts, \
    \(wire.estimatorStats.selfReferenceHolds) self-ref holds, \
    \(wire.estimatorStats.stallHolds) stall holds, \
    \(wire.estimatorStats.fallDeferrals) dwell deferrals, \
    \(wire.estimatorStats.sparseEvidenceHolds) sparse holds), \
    \(wire.estimatorStats.upshifts) upshifts \
    (\(wire.estimatorStats.upshiftsDamped) probe-damped, \
    \(wire.estimatorStats.upshiftsCadenceHeld) cadence-held), \
    \(s.rateChanges) pacer moves, \
    \(s.fallPurges) fall purges (\(s.fallPurgedVideoBytes) B dropped \
    pre-stale); frameByteCeiling@\(DirectEyeLeg.fps)fps \
    \(wire.frameByteCeiling(fps: DirectEyeLeg.fps)) B; borrowed ingress \
    \(wire.borrowedFrameBytesIngested) B
    encoder-vbv: \(wire.vbvDirectivesIssued) directives, \
    \(leg.directivesApplied) applied, \
    \(wire.vbvRateMovesAbsorbed) rate moves absorbed (pacer-only)\(vbvFinal)
    idr-demand: \(wire.freshKeyframeDemandCounts.demands) consumed \
    (path \(wire.freshKeyframeDemandCounts.pathPromotions), \
    client \(wire.freshKeyframeDemandCounts.clientRequests), \
    wake \(wire.freshKeyframeDemandCounts.machineWakes), \
    recovery \(wire.freshKeyframeDemandCounts.machineRecoveries), \
    unprotectable \(wire.freshKeyframeDemandCounts.unprotectableDrops), \
    fall-purge \(wire.freshKeyframeDemandCounts.fallPurges))
    repair: \(s.nackEntriesReceived) NACK entries \
    (\(s.nacksHonored) honored → \(s.repairDatagramsEnqueued) repair \
    datagrams, \(s.nacksJudgedStale) stale, \
    \(s.repairRefusalsSent) refusals sent, \
    \(s.openingExemptRepairsHonored) opening-exempt, \
    client-owned recovery; budget \(wire.repairBudgetMS) ms), \
    \(wire.estimatorStats.nackShardsCounted) post-FEC shards counted \
    (\(wire.estimatorStats.nackShardsRecused) recused as self-drain), \
    \(wire.estimatorStats.postFecDownshifts) rung-3 downshifts, \
    \(s.fecRegimeSteps) regime steps (final \(wire.fecRegime.rawValue)); \
    srtt \(wire.srttMicros.map { "\($0) µs" } ?? "—"), \
    store \(wire.repairStoreBytes) B
    """)
    if let audio {
        let trip = audio.tripwireCounters
        let negotiated = audio.negotiated.map {
            ", negotiated F32 \($0.rate) Hz \($0.channels)ch"
        } ?? ", no buffers arrived"
        let tripwire = trip.quietEntries > 0 ? """
            ; tripwire \(trip.quietEntries) quiet, \(trip.wakes) wakes, \
            \(trip.packetsGated) gated, \(trip.preRollShipped) pre-roll shipped
            """ : ""
        let negotiationError = audio.negotiationError.map {
            "; ERROR \($0)"
        } ?? ""
        let runError = audio.runError.map { "; run error \($0)" } ?? ""
        print("""
            audio: \(audio.packetsEncoded) packets encoded \
            (\(audio.encodeFailures) encode failures)\(negotiated)\
            \(tripwire)\(negotiationError)\(runError)
            """)
    }
}

/// Names a rolling histogram's window once it has dropped samples: the
/// percentiles before it then describe only the newest `window` samples.
static func windowNote(_ histogram: Histogram<UInt64>, _ window: Int) -> String {
    histogram.saturated
        ? " (last \(window) of \(histogram.count))"
        : ""
}
}

/// The Linux host application's one composition root. It selects the command,
/// constructs every concrete platform organ, and owns process-level failure.
extension HostApplication {
    static func main() {
        main(arguments: CommandLine.arguments)
    }

    static func main(arguments: [String]) {
        lyteIgnoreBrokenPipes()
        lyte_stdout_linebuf()
        do {
            if arguments.count > 1, arguments[1] == "sniff" {
                try sniff(Array(arguments.dropFirst(2)))
            } else {
                try run(arguments: arguments)
            }
        } catch {
            FileHandle.standardError.write(
                Data("lyte-host: error: \(error)\n".utf8)
            )
            exit(1)
        }
    }
}
