// lyte-host: the direct eye (pixel observation + EGL blit + native VAAPI
// encode, HostEye) → an Annex-B file, or a Lyte-UDP session
// (`--wire-out HOST:PORT` or `--wire-listen PORT`): the Noise IK responder
// handshake, then capture → encode → VideoChannel → seal → Pacer → CNetIO.

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
    var fps: Int32 = 60
    /// Run a session to this peer instead of writing the file.
    var wireOut: (host: String, port: UInt16)?
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
    /// Debug only: false = never arm the EncoderVbvPolicy; the encoder
    /// keeps its opening posture for the whole run.
    var vbvReconfigure = true

    static func parse(_ args: [String]) throws -> Options {
        var opts = Options()
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--out":
                i += 1
                guard i < args.count else { throw HostError("--out needs a path") }
                opts.outputPath = args[i]
            case "--seconds":
                i += 1
                guard i < args.count, let v = Double(args[i]), v > 0 else {
                    throw HostError("--seconds needs a positive number")
                }
                opts.seconds = v
                opts.secondsGiven = true
            case "--wire-out":
                i += 1
                guard i < args.count else {
                    throw HostError("--wire-out needs HOST:PORT")
                }
                let parts = args[i].split(separator: ":")
                guard parts.count == 2, let port = UInt16(parts[1]), port > 0
                else {
                    throw HostError("--wire-out needs HOST:PORT (got \(args[i]))")
                }
                opts.wireOut = (String(parts[0]), port)
            case "--wire-rate-mbps":
                i += 1
                guard i < args.count, let v = Double(args[i]), v > 0 else {
                    throw HostError("--wire-rate-mbps needs a positive number")
                }
                opts.wireRateMbps = v
            case "--wire-listen":
                i += 1
                guard i < args.count, let port = UInt16(args[i]), port > 0 else {
                    throw HostError("--wire-listen needs a port")
                }
                opts.wireListen = port
            case "--no-advertise":
                opts.advertise = false
            case "--advertise-interface":
                i += 1
                guard i < args.count, !args[i].isEmpty else {
                    throw HostError("--advertise-interface needs a name")
                }
                opts.advertiseInterface = args[i]
            case "--pair":
                opts.pair = true
            case "--require-paired":
                opts.requirePaired = true
            case "--input":
                i += 1
                guard i < args.count,
                      let choice = InputBackendChoice(rawValue: args[i])
                else {
                    throw HostError("--input must be auto, uinput, or off")
                }
                opts.input = choice
            case "--no-audio":
                opts.audio = false
            case "--host-audio":
                i += 1
                guard i < args.count else {
                    throw HostError("--host-audio must be audible or muted")
                }
                switch args[i] {
                case "audible": opts.hostAudio = .hostAudible
                case "muted": opts.hostAudio = .hostMuted
                default:
                    throw HostError("--host-audio must be audible or muted")
                }
            case "--clipboard":
                opts.clipboard = true
            case "--clipboard=images":
                opts.clipboard = true
                opts.clipboardImages = true
            case let arg where arg.hasPrefix("--clipboard="):
                throw HostError("""
                    --clipboard takes no value or \
                    =images (the consent tier's third rung)
                    """)
            case "--accept-files":
                opts.acceptFiles = true
            case let arg where arg.hasPrefix("--accept-files="):
                opts.acceptFiles = true
                let dir = String(arg.dropFirst("--accept-files=".count))
                guard !dir.isEmpty else {
                    throw HostError("--accept-files= needs a directory")
                }
                opts.acceptFilesDirectory = dir
            case "--cookie-enter":
                i += 1
                guard i < args.count, let v = Int(args[i]), v >= 1 else {
                    throw HostError("--cookie-enter needs a positive integer")
                }
                opts.cookieEnter = v
            case "--cookie-exit":
                i += 1
                guard i < args.count, let v = Int(args[i]), v >= 0 else {
                    throw HostError("--cookie-exit needs a non-negative integer")
                }
                opts.cookieExit = v
            case "--no-vbv-reconfigure":
                opts.vbvReconfigure = false
            case "--audio-bitrate-kbps":
                i += 1
                guard i < args.count, let v = Int32(args[i]), v > 0 else {
                    throw HostError(
                        "--audio-bitrate-kbps needs a positive number")
                }
                opts.audioBitrate = v * 1_000
            case "--help", "-h":
                print("""
                usage: lyte-host [--out PATH] [--seconds N]
                                 [--wire-out HOST:PORT] [--wire-rate-mbps N]
                Captures the desktop with the direct eye (GPU pixel observation
                + EGL blit, needs CAP_SYS_ADMIN) and encodes native VAAPI
                HEVC — to Annex-B PATH (default /tmp/lyte-h0a.hevc) or a
                Lyte-UDP session.
                  --seconds N       bound the leg to N s and serve one
                                    session (default 5). A --wire-listen
                                    run without it is the service: it
                                    serves sessions in turn with no
                                    clock, keeping the eye, listening
                                    socket, advertisement and input
                                    devices up between them
                  --wire-out H:P    session mode: Noise IK handshake with
                                    the client at HOST:PORT, then sealed
                                    Lyte-UDP shards (packetizer + FEC +
                                    pacer + 1 Hz beacon, per-packet TOS)
                                    instead of writing the file
                  --wire-listen P   session mode, but bind port P and adopt
                                    whichever client completes message 1
                                    (advertises _lyte._udp via Avahi)
                  --wire-rate-mbps  session ceiling: pacer rate + the
                                    estimator's negotiated cap
                                    (default 50, the LAN ceiling; in
                                    session mode the encoder recipe
                                    pairs to it)
                  --no-advertise    skip the Avahi _lyte._udp advertisement
                  --advertise-interface NAME
                                    advertise on ONE interface (e.g. the
                                    Ethernet NIC) so clients never get
                                    handed the radio's address
                                    in --wire-listen mode
                  --pair            pairing mode (with --wire-listen): mint
                                    and print a 6-digit PIN, run the CPace
                                    PAKE over the sealed reliable CTRL
                                    stream, and pin the paired client's
                                    static to ~/.config/lyte/
                                    paired_clients (3 wrong guesses burn
                                    the PIN; rerun --pair for a fresh one)
                  --require-paired  only clients already in paired_clients
                                    may complete the Noise handshake
                                    (reconnects are plain 1-RTT IK)
                  --cookie-enter N  message 1s per second at which the
                                    handshake demands a stateless retry
                                    cookie (default 20)
                  --cookie-exit N   the rate at which that demand clears
                                    (default 5, below --cookie-enter)
                  --input MODE      injection backend for client input
                                    events: auto/uinput (kernel
                                    uinput, compositor-agnostic;
                                    needs the setup-host.sh udev
                                    rule), or off
                  --no-audio        skip the audio leg (default in
                                    session mode: default-sink monitor →
                                    5 ms Opus → RS 4+2 → chan 1 at
                                    DSCP 48, continuous from
                                    establishment — silence included)
                  --audio-bitrate-kbps N
                                    Opus hard-CBR bitrate (default 128)
                  --clipboard       clipboard sync (UTF-8 text, both
                                    ways, 64 KiB ceiling): client sets
                                    (0x1A) land on the host clipboard,
                                    host copies announce (0x1B).
                                    Default OFF; capability key 10 is
                                    declared only when the leaf comes
                                    up, so a plain run truthfully
                                    negotiates no clipboard
                  --clipboard=images
                                    the consent tier's third rung:
                                    text AND images (PNG, both
                                    ways, 32 MiB ceiling) as chan-8
                                    cargo. Key 12 declared only when
                                    the leaf comes up with images
                                    enabled; independent of
                                    --accept-files (file consent
                                    never couples to the clipboard)
                  --accept-files[=DIR]
                                    the standing per-host file-drop
                                    consent (client→host only in
                                    v1): incoming bulk transfers land
                                    in DIR (default ~/Downloads,
                                    created if missing) via staging +
                                    fsync + atomic rename, resumable
                                    across teardowns. Default OFF;
                                    capability key 11 is declared only
                                    when the toggle is ON and the drop
                                    directory came up, so a plain run
                                    truthfully negotiates no file
                                    transfer
                  --no-vbv-reconfigure
                                    debug: never reconfigure the
                                    encoder's rate control from the
                                    estimator's ceiling (the opening
                                    posture rides the whole run)
                  --host-audio MODE audible (default) keeps the host's
                                    speakers playing (default-sink
                                    monitor capture); muted routes the
                                    desktop's audio to a session-owned
                                    "Lyte Audio" virtual sink — only
                                    the wire hears it, and the original
                                    default sink is restored at
                                    teardown (crash paths swept on the
                                    next start)

                subcommands: lyte-host sniff --port PORT  (header dissector)
                             lyte-host advertise …        (mDNS discovery)
                """)
                exit(0)
            default:
                throw HostError("unknown argument \(args[i]) (try --help)")
            }
            i += 1
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
    let hostStatic: NoiseKeyPair
    let allowed: [[UInt8]]?
    let pairingService: PairingResponderService?
    let clipboardLeaf: MutterClipboardLeaf?
    let declared: Capabilities
    let gateConfig: HandshakeGate.Config
    /// The listening socket (nil for a wire-out run, whose wire opens
    /// its own on a kernel-assigned port).
    let listener: HostListener?
    let injector: InputInjector?
    /// Releasing it withdraws the record.
    private let advertiser: AvahiAdvertiser?
    /// Set when file drop came up at bring-up (key 11 declared on it).
    private let dropDirectory: String?
    /// The bring-up shell goes to the first session; later sessions get
    /// a fresh shell that reloads the persisted resume states.
    private var firstBulkShell: BulkReceiveShell?

    init(opts: Options, screen: DirectScreenSource) throws {
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
        hostStatic = keys
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
                let tier = opts.clipboardImages
                    ? """
                        text + images (PNG, \
                        \(ClipboardImageWire.maxImageByteCount) B image ceiling)
                        """
                    : "text only"
                print("""
                    clipboard: leaf up — RemoteDesktop-session \
                    clipboard (Mutter), \(tier), \
                    \(ClipboardWire.maxTextByteCount) B text ceiling
                    """)
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
                print("""
                    files: accepting incoming transfers → \(dropDir) \
                    (staging + fsync + atomic rename, resumable; \
                    one transfer at a time)
                    """)
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
        if EyeVaapiEncoder.probesMain444() {
            declared.chromaModes = [
                CapabilityChroma.yuv420, CapabilityChroma.yuv444,
            ]
            print("""
                chroma: Main444 probe GREEN — declaring \
                [420, 444] (Best tier open, Rext native pens)
                """)
        } else {
            print("chroma: no Main444 encode entrypoint — declaring [420] only")
        }
        self.declared = declared

        var rng = SystemRandomNumberGenerator()
        gateConfig = opts.handshakeGateConfig(using: &rng)
        print("""
            handshake: retry-cookie dial armed (require-cookie engages \
            at \(opts.cookieEnter) msg1/s, clears at \(opts.cookieExit)/s)
            """)

        // Binds once for the whole run, so the port stays bound between
        // sessions.
        listener = try opts.wireListen.map { try HostListener(port: $0) }

        // Up before the first handshake wait; the advertiser re-files
        // the record whenever it is withdrawn (`serviceOrgans`).
        var published: AvahiAdvertiser?
        if opts.advertise, let listenPort = opts.wireListen {
            do {
                published = try AvahiAdvertiser(
                    port: listenPort,
                    staticPublicKey: keys.publicKey,
                    interfaceName: opts.advertiseInterface
                )
            } catch {
                print(
                    "discovery: off (\(error)) — manual host:port still works")
            }
        }
        advertiser = published

        // Injection is ready before any client connects and stays up
        // across sessions; each session's end releases what it held.
        injector = makeInputInjector(opts.input)
        if let injector {
            injector.noteMonitorExtent(
                width: UInt32(screen.width), height: UInt32(screen.height))
            print("""
                input: injection via \(injector.name) \
                (echo tuples + lastInputSeq stamping active)
                """)
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
    lyte_stdout_linebuf()

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

    let sessionMode = opts.wireOut != nil || opts.wireListen != nil
    let peer = opts.wireOut.map { "\($0.host):\($0.port)" }
        ?? "listen :\(opts.wireListen ?? 0)"
    let destination = sessionMode
        ? "lyte-udp session (\(peer), noise)" : opts.outputPath
    print("""
        lyte-host — direct eye (GPU pixel observation + EGL blit) → \
        native VAAPI (our pens) → \(destination)
        """)
    print("""
        encoder: native VAAPI seat — rate directives ride the \
        next frame's RC buffer (no libavcodec in the video path)
        """)

    // The scanout opens first: its geometry scales the injector's
    // absolute moves. It and the eye's GL context live for the run.
    let screen = try DirectEyeLeg.openScreen(
        device: DirectEyeLeg.Config.defaultDevice)
    let eye = WarmEye(screen: screen)
    guard sessionMode else {
        try runFileLeg(opts, screen: screen, eye: eye)
        return
    }

    let host = try SessionHost(opts: opts, screen: screen)
    defer { host.stop() }
    var loop = HostServiceLoop(posture: HostServiceLoop.posture(
        listening: opts.wireListen != nil,
        secondsGiven: opts.secondsGiven,
        pairing: opts.pair,
        seconds: opts.seconds))
    if loop.posture == .service {
        print("""
            service: serving sessions in turn with no session clock — \
            the eye, listening socket, advertisement and input devices \
            stay up between sessions
            """)
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
        config: .init(seconds: opts.seconds),
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
        peer: opts.wireOut,
        rateBitsPerSecond: Int(opts.wireRateMbps * 1_000_000),
        capabilities: host.declared,
        allowedClientStatics: host.allowed,
        handshakeGateConfig: host.gateConfig,
        pairing: host.pairingService,
        onPairingEvent: handlePairingEvent
    )
    defer { w.release() }
    w.inputInjector = host.injector
    let awaitOutcome: SessionWire.ClientAwaitOutcome
    do {
        // A listening service waits forever; a wire-out run gives its
        // peer two minutes. Unattached, the clipboard leaf still serves
        // host pastes and drains host copies unread.
        awaitOutcome = try w.awaitClient(
            hostStatic: host.hostStatic,
            timeoutSeconds: opts.wireListen != nil ? nil : 120,
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
    print("""
        session: up — pacer \(opts.wireRateMbps) Mbps, per-packet TOS (video \
        0xA0 / ctrl+audio+repairs 0xC0), 1 Hz beacon on CTRL
        """)

    // The estimator's ceiling reaches the encoder as rate directives.
    // The baseline mirrors the encoder's opening posture: VBR under the
    // wire-rate cap, VBV at the unprotectable-frame guard's ceiling, so
    // a restore can never re-open the >255-shard hole.
    let guardBits = w.worstCaseProtectableFrameCeiling * 8
    if opts.vbvReconfigure {
        let rateBits = Int(opts.wireRateMbps * 1_000_000)
        // Half-rungs and exact tightens; the native seat applies rate
        // moves without a reset. The loosening sustain stays slow on
        // purpose: an eager one chases every climb into a limit cycle.
        w.armEncoderVbv(EncoderVbvConfig(
            fps: Int(opts.fps),
            baselineAverageBitsPerSecond: nil,
            baselineMaxBitsPerSecond: rateBits,
            baselineVbvBits: guardBits,
            rungsPerOctave: 2,
            exactTighten: true
        ))
    } else {
        print("""
            encoder-vbv: DISABLED (--no-vbv-reconfigure) — the \
            opening posture rides the whole run
            """)
    }

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
            w.audioRoutingHandler = { mode in
                // Runs on the janitor thread, off the session lock. The
                // stream pauses across the rebuild so two leaves never
                // overlap.
                audioWire?.stop()
                audioWire = nil
                // Stream off: stopping is the whole apply; the host's
                // speakers keep playing.
                if mode == .streamOff {
                    print("""
                        audio-routing: stream OFF — the wire carries no audio \
                        track (host speakers unaffected)
                        """)
                    return true
                }
                do {
                    let flipped = try AudioWire(
                        wire: w, bitrate: opts.audioBitrate, mode: mode
                    )
                    flipped.start(seconds: audioSeconds)
                    audioWire = flipped
                    return true
                } catch {
                    print("""
                        audio-routing: rebuild in \(mode) failed (\(error)) — \
                        trying to come back \(opts.hostAudio)
                        """)
                    if let back = try? AudioWire(
                        wire: w, bitrate: opts.audioBitrate,
                        mode: opts.hostAudio
                    ) {
                        back.start(seconds: audioSeconds)
                        audioWire = back
                    }
                    return false
                }
            }
            let capture = opts.hostAudio == .hostMuted
                ? "\"Lyte Audio\" virtual-sink capture (host MUTED)"
                : "default-sink monitor capture (host audible)"
            print("""
                audio: \(capture) → opus \(opts.audioBitrate / 1_000) kbps \
                hard CBR → 5 ms packets → RS 4+2 → chan 1 (TOS 0xC0 / DSCP 48)
                """)
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
    host.injector?.releaseHeld()
    host.clipboardLeaf?.detach()
    host.clipboardLeaf?.onLocalChange = nil
    host.clipboardLeaf?.onLocalImageChange = nil
    // Persists mid-flight resume state so the next session's re-offer
    // resumes from the gap.
    bulkShell?.teardown()

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

        done: \(leg.frames) frames encoded (direct eye), \(leg.keyframes) IDR, \
        \(leg.bytes) bytes, missed_grabs \(leg.missedGrabs), rate directives \
        applied \(leg.directivesApplied)
        """)
        print("first packet NALs: \(AnnexBCheck.summary(of: leg.firstPacket))")
        if startsStream {
            print("first packet starts with parameter sets + IDR: OK")
        }
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
    var vbvFinal = ""
    if let d = wire.lastVbvDirective {
        let avg = d.averageBitsPerSecond
            .map { " avg \($0 / 1_000) kbps," } ?? ""
        vbvFinal = """
             — final\(avg) max \(d.maxBitsPerSecond / 1_000) kbps, vbv \
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
    \(o.transientErrors)/\(wire.receiveTransientErrors), stale fresh shed \
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
    \(s.feedbackDatagrams) feedback datagrams, \
    \(s.handshakesThrottled) msg1 throttled
    handshake-flood: \(s.handshakeChallengesMinted) cookies minted \
    (0x13), \(s.handshakeCookiesVerified) verified / \
    \(s.handshakeCookiesRejected) rejected (0x14), require-cookie now \
    \(wire.handshakeCookieMode ? "ON" : "off")
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
    \(wire.serviceOnceMaxNS)/\(wire.receiveAllMaxNS) ns
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
    pre-stale); frameByteCeiling@\(opts.fps)fps \
    \(wire.frameByteCeiling(fps: Int(opts.fps))) B; borrowed ingress \
    \(wire.borrowedFrameBytesIngested) B (entry-copy bytes avoided)
    encoder-vbv: \(wire.vbvDirectivesIssued) directives, \
    \(leg.directivesApplied) applied, \
    \(wire.vbvRateMovesAbsorbed) rate moves absorbed \
    (pacer-only, no encoder reset); applied live — native seat, \
    zero reset, zero IDR by construction\(vbvFinal)
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
        // Subcommands never return: `sniff` is the Lyte-UDP header
        // dissector; `advertise` is the standalone Avahi surface.
        if arguments.count > 1, arguments[1] == "sniff" {
            sniffMain(Array(arguments.dropFirst(2)))
        }
        if arguments.count > 1, arguments[1] == "advertise" {
            lyte_stdout_linebuf() // prints must land live through an ssh pipe
            advertiseMain(Array(arguments.dropFirst(2)))
        }

        do {
            try run(arguments: arguments)
        } catch {
            FileHandle.standardError.write(
                Data("lyte-host: error: \(error)\n".utf8)
            )
            exit(1)
        }
    }
}
