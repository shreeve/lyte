// lyte-host: the direct eye (KMS doorbell + EGL blit + native VAAPI
// encode — HostEye) → Annex-B file, or the Lyte-UDP session (HS-7):
// `--wire-out HOST:PORT` (or `--wire-listen PORT`) runs
// HostWire.Session — Noise IK responder handshake against a connecting
// client (default) or the `--insecure` CP-3 passthrough — then capture
// → encode → VideoChannel → seal → Pacer → CNetIO, with 1 Hz beacons,
// conn-id TLVs, and inbound handling (echoes, IDR requests, path
// challenges) on the same loop.
// E5: the portal/mutter ScreenCast backends, PipeWire video, and the
// libav encoder seat are demolished — the direct eye is the only
// capture organ, and every muscle above the drivers is ours.

import CNetIO
import Foundation
import HostCore
import HostWire
import LyteWire

// MARK: - Options

struct Options {
    var outputPath = "/tmp/lyte-h0a.hevc"
    var seconds = 5.0
    var fps: Int32 = 60
    /// Accepted-and-ignored since E5: the portal-era quality-ratchet
    /// prototype died with its backend. The flag survives parsing so
    /// standing loop scripts keep working; ratchet-style refinement on
    /// the direct leg is the filed follow-up.
    var ratchet = false
    /// HS-5/HS-7: run a session to this peer instead of writing the file.
    var wireOut: (host: String, port: UInt16)?
    /// HS-7: bind here and await a connecting client (Noise mode).
    var wireListen: UInt16?
    /// The session rate ceiling for the wire mode. HS-16's estimator
    /// starts here and moves the live pacer rate inside
    /// [500 kbps, this] on feedback evidence. 50 is the owner-ruled
    /// LAN ceiling (HS-23/R2): permission, not a promise — the
    /// estimator still governs below it, and capped-CQ means an idle
    /// desktop at a 50 Mbps cap still costs ~0.4 Mbps.
    var wireRateMbps = 50.0
    /// CP-3 fallback (§4.1): passthrough seal, stream to the fixed peer
    /// without a handshake. The default is real Noise.
    var insecure = false
    /// Pin the advertisement to one interface (e.g. the Ethernet NIC
    /// on a wired+wireless host) so discovery never hands clients the
    /// radio's address. Empty = all interfaces.
    var advertiseInterface = ""
    /// HS-10: advertise `_lyte._udp` via Avahi while listening. On by
    /// default in `--wire-listen` Noise mode; Avahi being unavailable
    /// degrades to manual host:port, never a failure.
    var advertise = true
    /// HS-9 pairing mode: mint a 6-digit PIN, print it, and run the
    /// CPace responder over the session's reliable CTRL stream; on
    /// success the client's static is pinned to paired_clients.
    var pair = false
    /// HS-9 enforcement: only statics already in paired_clients may
    /// complete the handshake (the "1-RTT reconnect" half of the gate).
    var requirePaired = false
    /// HS-13 injection backend: auto = Mutter RemoteDesktop, falling
    /// back to uinput; off disables input for the run.
    var input: InputBackendChoice = .auto
    /// HS-15: desktop audio on the wire (default ON in session mode —
    /// the H2 posture: continuous 5 ms CBR audio starts at
    /// establishment). `--no-audio` opts out.
    var audio = true
    /// Opus hard-CBR bitrate (the dialect default).
    var audioBitrate: Int32 = 128_000
    /// HS-18: the session's starting audio-routing posture. audible =
    /// HS-14's default-sink monitor (the host's speakers keep
    /// playing); muted = the "Lyte Audio" virtual sink takes the
    /// default and the physical output goes silent for the session.
    /// A capability-negotiated client can flip it mid-session (0x18).
    var hostAudio: HostAudioRoutingMode = .hostAudible
    /// HS-19: clipboard sync (CL-15's v1, UTF-8 text both ways).
    /// Default OFF — the consent posture: the host operator opts in,
    /// and capability key 10 is declared only when the leaf actually
    /// came up (the key-9/--no-audio precedent).
    var clipboard = false
    /// P-1: the images rung of the consent tier (LYTE-PLAN §8's
    /// Off / Text only / Text + images). `--clipboard=images` sets
    /// both flags; key 12 is declared only when the leaf came up
    /// with images enabled — a text-only run truthfully never
    /// promises the image dialect.
    var clipboardImages = false
    /// F-3: the STANDING PER-HOST consent toggle for incoming file
    /// transfer (H3 §0 owner decision 1). Default OFF — a plain run
    /// declares no key 11 and any chan-8 byte is a protocol
    /// violation; `--accept-files[=DIR]` opts in and names the drop
    /// directory (default ~/Downloads, created if missing).
    var acceptFiles = false
    var acceptFilesDirectory: String?
    /// HS-21: arm the W8 retry-cookie dial. Off = the pure HS-9
    /// token-bucket posture (nil secret). On = a random cookie secret is
    /// minted and require-cookie mode engages when the msg1 arrival rate
    /// crosses the enter threshold, clearing at the exit threshold.
    var requireCookie = false
    var cookieEnter = 20
    var cookieExit = 5
    /// HS-22 isolation lever: false = never arm the EncoderVbvPolicy —
    /// the encoder keeps its opening posture for the whole run (the
    /// pre-HS-20 posture, everything else identical). Debug only.
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
            case "--backend":
                i += 1
                // E5: the portal and mutter ScreenCast backends are
                // demolished — the direct eye is the only capture
                // organ. The flag survives as a no-op so holds/scripts
                // keep working; asking for a dead backend fails loudly.
                guard i < args.count, args[i] == "direct" else {
                    let asked = i < args.count ? args[i] : "(missing)"
                    throw HostError("--backend \(asked): the portal and "
                        + "mutter ScreenCast backends were demolished "
                        + "after first-light — the direct eye is the "
                        + "only backend (--backend direct is an "
                        + "accepted no-op)")
                }
            case "--encoder":
                i += 1
                // The libav seat was demolished after first-light:
                // native VAAPI is the direct eye's only encoder. The
                // flag survives as a no-op so holds/scripts keep
                // working; asking for the dead seat fails loudly.
                guard i < args.count, args[i] == "native" else {
                    throw HostError("--encoder libav was demolished "
                        + "after first-light — the native VAAPI seat "
                        + "is the direct eye's only encoder "
                        + "(--encoder native is an accepted no-op)")
                }
            case "--ratchet":
                opts.ratchet = true
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
            case "--insecure":
                opts.insecure = true
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
                    throw HostError(
                        "--input must be auto, mutter, uinput, or off")
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
                throw HostError("--clipboard takes no value or "
                    + "=images (the consent tier's third rung)")
            case "--accept-files":
                opts.acceptFiles = true
            case let arg where arg.hasPrefix("--accept-files="):
                opts.acceptFiles = true
                let dir = String(arg.dropFirst("--accept-files=".count))
                guard !dir.isEmpty else {
                    throw HostError("--accept-files= needs a directory")
                }
                opts.acceptFilesDirectory = dir
            case "--require-cookie":
                opts.requireCookie = true
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
                    throw HostError("--audio-bitrate-kbps needs a "
                        + "positive number")
                }
                opts.audioBitrate = v * 1_000
            case "--help", "-h":
                print("""
                usage: lyte-host [--out PATH] [--seconds N]
                                 [--wire-out HOST:PORT] [--wire-rate-mbps N]
                Captures the desktop with the direct eye (KMS doorbell +
                EGL blit, needs CAP_SYS_ADMIN) and encodes native VAAPI
                HEVC — to Annex-B PATH (default /tmp/lyte-h0a.hevc) or a
                Lyte-UDP session.
                  --backend direct  accepted no-op: the direct eye is the
                                    only backend (portal and mutter were
                                    demolished after first-light)
                  --encoder native  accepted no-op: the native VAAPI
                                    seat is the direct eye's only
                                    encoder (the libav seat was
                                    demolished after first-light)
                  --ratchet         accepted-and-ignored: the portal-era
                                    ratchet prototype died in the E5
                                    demolition (direct-leg quality
                                    refinement is the filed follow-up)
                  --wire-out H:P    session mode: Noise IK handshake with
                                    the client at HOST:PORT, then sealed
                                    Lyte-UDP shards (packetizer + FEC +
                                    pacer + 1 Hz beacon, per-packet TOS)
                                    instead of writing the file
                  --wire-listen P   session mode, but bind port P and adopt
                                    whichever client completes message 1
                                    (advertises _lyte._udp via Avahi)
                  --insecure        CP-3 fallback: no handshake, passthrough
                                    seal, stream to the --wire-out peer
                                    immediately (re-gate with Noise later)
                  --wire-rate-mbps  session ceiling: pacer rate + the
                                    estimator's negotiated cap
                                    (default 50 — the owner-ruled LAN
                                    ceiling; in session mode the
                                    encoder recipe pairs to it unless
                                    --bitrate-mbps splits them)
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
                                    static to ~/.config/lyte-host/
                                    paired_clients (3 wrong guesses burn
                                    the PIN; rerun --pair for a fresh one)
                  --require-paired  only clients already in paired_clients
                                    may complete the Noise handshake
                                    (reconnects are plain 1-RTT IK)
                  --input MODE      injection backend for client input
                                    events (HS-13): auto (default —
                                    Mutter RemoteDesktop, uinput
                                    fallback), mutter, uinput, off
                  --no-audio        skip the HS-15 audio leg (default in
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
                                    the consent tier's third rung
                                    (P-1): text AND images (PNG, both
                                    ways, 32 MiB ceiling) as chan-8
                                    cargo. Key 12 declared only when
                                    the leaf comes up with images
                                    enabled; independent of
                                    --accept-files (file consent
                                    never couples to the clipboard)
                  --accept-files[=DIR]
                                    the standing per-host file-drop
                                    consent (F-3, client→host only in
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
                                    estimator's ceiling (HS-22's
                                    isolation lever — the opening
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
                             lyte-host advertise …        (HS-10 discovery)
                """)
                exit(0)
            default:
                throw HostError("unknown argument \(args[i]) (try --help)")
            }
            i += 1
        }
        return opts
    }
}

// MARK: - Pairing surface (HS-9)

/// The H1-era PIN surface is this console line: 6 CSPRNG digits,
/// zero-padded (10⁶ space; with the service's 3-guess budget an online
/// attacker has 3-in-a-million odds per displayed PIN, and CPace makes
/// the PIN untestable offline).
func mintPairingPin() -> String {
    var rng = SystemRandomNumberGenerator()
    return String(format: "%06d", rng.next(upperBound: UInt32(1_000_000)))
}

/// The pairing service's events, executed: `.paired` is the keystore
/// write; everything else is the gate's loud console evidence.
func handlePairingEvent(_ event: PairingResponderService.Event) {
    switch event {
    case .attemptOpened(let attempt, let of):
        print("pairing: attempt \(attempt)/\(of) — share B sent")
    case .paired(let key):
        let hex = HostStaticKey.hex(key)
        do {
            var store = try PairedClients.load()
            if store.pin(key, note: "paired "
                + ISO8601DateFormatter().string(from: Date())) {
                try PairedClients.save(store)
                print("pairing: PAIRED — client static \(hex) pinned → "
                    + PairedClients.path.path)
            } else {
                print("pairing: PAIRED — client static \(hex) was "
                    + "already pinned")
            }
        } catch {
            // The trust decision is made; only the persistence failed.
            // Loud enough to pin by hand, not fatal to the session.
            print("pairing: PAIRED but the keystore write FAILED "
                + "(\(error)) — pin \(hex) by hand")
        }
    case .rejected(let reason, let remaining):
        print("pairing: REJECTED (\(reason)) — \(remaining) attempt(s) "
            + "remain on this PIN")
    case .clientAborted(let reason):
        print("pairing: client aborted (\(reason)) — its PIN entry "
            + "disagreed with ours")
    case .throttled:
        print("pairing: attempt inside the 1 s throttle window — dropped")
    case .pinBurned:
        print("pairing: PIN BURNED — guess budget spent; pairing stays "
            + "silent until a rerun of --pair mints a fresh PIN")
    case .malformed:
        print("pairing: malformed pairing bytes dropped")
    }
}

/// Decodes a NUL-terminated C error buffer.
func errString(_ buf: [CChar]) -> String {
    let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

func monotonicNow() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

// MARK: - Main

func run() throws {
    lyte_stdout_linebuf()

    let opts = try Options.parse(CommandLine.arguments)
    // The cap_sys_admin file capability (the direct eye's DRM ticket)
    // clears the dumpable flag at exec — re-arm dumpability for crash
    // forensics (owner-machine threat model; E4's packaging owns the
    // real answer). NOTE /proc/self/exe stays ptrace-guarded regardless
    // (the kernel's capability-subset rule) — the benchmark rig reads
    // its provenance witness via sudo.
    if lyte_set_dumpable() != 0 {
        print("host: WARNING — could not restore dumpability "
            + "(coredumps stay disabled)")
    }

    let sessionMode = opts.wireOut != nil || opts.wireListen != nil
    let destination = sessionMode
        ? "lyte-udp session ("
            + (opts.wireOut.map { "\($0.host):\($0.port)" }
                ?? "listen :\(opts.wireListen!)")
            + (opts.insecure ? ", INSECURE" : ", noise") + ")"
        : opts.outputPath
    print("lyte-host — direct eye (KMS doorbell + EGL blit) → "
        + "native VAAPI (our pens) → \(destination)")
    // E6b: libavcodec is out of the video path entirely — rate
    // moves are RC misc buffers on the next frame, by construction.
    print("encoder: native VAAPI seat — rate directives ride the "
        + "next frame's RC buffer (no libavcodec in the video path)")
    if opts.ratchet {
        print("note: --ratchet accepted-and-ignored — the portal-era "
            + "ratchet prototype died in the E5 demolition (direct-leg "
            + "quality refinement is the filed follow-up)")
    }

    // The session comes up BEFORE capture: in Noise mode the host blocks
    // here for the client's handshake (printing the static public key the
    // client must hold), so no frames are encoded for nobody and the
    // first encoded frame is the session's first IDR.
    var wire: SessionWire?
    var advertiser: AvahiAdvertiser?
    var pairingService: PairingResponderService?
    var clipboardLeaf: MutterClipboardLeaf?
    var bulkShell: BulkReceiveShell?
    if sessionMode {
        if opts.insecure, opts.wireOut == nil {
            throw HostError("--insecure streams to a fixed peer; "
                + "give --wire-out HOST:PORT")
        }
        if opts.insecure, opts.pair || opts.requirePaired {
            throw HostError("pairing binds to the Noise session that "
                + "carries it — drop --insecure")
        }
        if opts.pair, opts.requirePaired {
            throw HostError("--pair admits a not-yet-paired client; "
                + "--require-paired contradicts it")
        }
        if !opts.audio, opts.hostAudio == .hostMuted {
            throw HostError("--host-audio muted routes audio to the wire "
                + "instead of the speakers; --no-audio contradicts it")
        }

        // HS-9 setup happens before the socket exists so a bad keystore
        // fails the run instead of a live session.
        var hostStatic: NoiseKeyPair?
        var allowed: [[UInt8]]?
        if !opts.insecure {
            let keys = try HostStaticKey.loadOrCreate()
            hostStatic = keys
            if opts.requirePaired {
                let store = try PairedClients.load()
                guard !store.entries.isEmpty else {
                    throw HostError("--require-paired with an empty "
                        + "keystore would lock every client out — run "
                        + "--pair once first")
                }
                allowed = store.publicKeys
                print("pairing: enforcing \(store.entries.count) paired "
                    + "client static(s) from \(PairedClients.path.path)")
            }
            if opts.pair {
                let pin = mintPairingPin()
                pairingService = PairingResponderService(
                    pin: Array(pin.utf8),
                    hostStaticPublicKey: keys.publicKey
                )
                print("pairing: PIN \(pin) — enter it on the client "
                    + "(3 wrong guesses burn it; rerun --pair for a "
                    + "fresh one)")
            }
        }

        // HS-18 housekeeping before any session traffic: put back a
        // default sink a SIGKILLed previous run stranded (no-op when
        // the previous shutdown was clean), and arm the SIGINT/SIGTERM
        // flag so an interrupted run still walks the restore path.
        AudioWire.sweepLeftoverRouting()
        lyteInstallTerminationHandlers()

        // HS-19: the clipboard leaf comes up BEFORE the declaration is
        // built — key 10 follows the leaf, never the flag alone (a
        // refused Mutter session must not leave the host promising a
        // dialect it cannot speak).
        if opts.clipboard {
            do {
                let leaf = try MutterClipboardLeaf(
                    imagesEnabled: opts.clipboardImages
                )
                try leaf.start()
                clipboardLeaf = leaf
                let tier = opts.clipboardImages
                    ? "text + images (PNG, "
                        + "\(ClipboardImageWire.maxImageByteCount) B "
                        + "image ceiling)"
                    : "text only"
                print("clipboard: leaf up — RemoteDesktop-session "
                    + "clipboard (Mutter), \(tier), "
                    + "\(ClipboardWire.maxTextByteCount) B text ceiling")
            } catch {
                print("clipboard: leaf unavailable (\(error)) — "
                    + "clipboard sync OFF this run, key 10 not declared")
            }
        }

        // F-3: the file-drop shell comes up BEFORE the declaration is
        // built — key 11 follows the toggle AND the directory, never
        // the flag alone (the key-10/leaf precedent: an uncreatable
        // drop directory must not leave the host promising a dialect
        // it cannot land bytes for). Consent is this standing toggle;
        // the shell existing IS the yes, and Wire never sees it.
        if opts.acceptFiles {
            let dropDir = opts.acceptFilesDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads").path
            do {
                let shell = try BulkReceiveShell(directoryPath: dropDir)
                bulkShell = shell
                print("files: accepting incoming transfers → \(dropDir) "
                    + "(staging + fsync + atomic rename, resumable; "
                    + "one transfer at a time)")
            } catch {
                print("files: drop directory unavailable (\(error)) — "
                    + "file drop OFF this run, key 11 not declared")
            }
        }

        // The W7 declaration: key 9 (hostAudioRouting, the HS-18
        // virtual-sink mute) rides the forward-compat spine whenever
        // the audio leg exists — the client's control strip gates its
        // mute button on the intersection, so a --no-audio host
        // truthfully never declares it. Key 10 (clipboardText, CL-15)
        // rides the same spine whenever the clipboard leaf is up, and
        // key 11 (bulkTransfer, F-3) whenever the file-drop shell is.
        // Key 14 (audioStreamOff, postures design) rides with key 9:
        // an audio-capable host can always honor "send me nothing".
        // Key 15 (audioQuietPosture, the tripwire) rides the same
        // gate: an audio-capable host can always gate its silence.
        var declared = opts.audio
            ? Capabilities.wireDefault.declaringHostAudioRouting()
                .declaringAudioStreamOff()
                .declaringAudioQuietPosture()
            : .wireDefault
        if clipboardLeaf != nil {
            declared = declared.declaringClipboardText()
            // P-1: key 12 follows the TIER, not the flag alone — the
            // leaf must be up AND images enabled (a text-only run
            // truthfully never promises the image dialect, and the
            // key is independent of key 11's file consent).
            if opts.clipboardImages {
                declared = declared.declaringClipboardImages()
            }
        }
        if bulkShell != nil {
            declared = declared.declaringBulkTransfer()
        }
        // E3: key 13 (cursorShape) — the direct eye sends the cursor
        // plane as metadata, never composited into the video.
        declared = declared.declaringCursorShape()
        // Video posture (key 16): the direct eye's keepalive can
        // always back off honestly — announced, never inferred.
        declared = declared.declaringVideoQuietPosture()

        // V-4: chroma is declared on PROOF, never a hardcoded claim.
        // The direct eye's native VAAPI pens write NV12 4:2:0 and
        // nothing else yet, so the host declares [420] alone
        // regardless of what the silicon could do; the Best tier
        // (4:4:4) returns when Rext lands in the native pens (the
        // recorded ladder item), proven by its own probe — never
        // borrowed from another encoder's.
        print("chroma: native VAAPI seat is 4:2:0 — declaring "
            + "chroma [420] only (Best tier returns with Rext "
            + "in the native pens)")

        // HS-21: arm the retry-cookie dial when asked. A random secret,
        // process-scoped: the host both mints and verifies with it, and
        // no cookie needs to survive a restart (an honest client re-dials
        // with a fresh msg1, drawing a fresh challenge).
        var gateConfig = HandshakeGate.Config()
        if opts.requireCookie {
            var secret = [UInt8](repeating: 0, count: RetryCookie.secretByteCount)
            for i in secret.indices { secret[i] = UInt8.random(in: 0...255) }
            gateConfig = HandshakeGate.Config(
                cookieSecret: secret,
                cookieEnterThreshold: opts.cookieEnter,
                cookieExitThreshold: opts.cookieExit
            )
            print("handshake: W8 retry-cookie dial ARMED "
                + "(require-cookie engages at \(opts.cookieEnter) msg1/s, "
                + "clears at \(opts.cookieExit)/s)")
        }

        let w = try SessionWire(
            listenPort: opts.wireListen,
            peer: opts.wireOut,
            insecure: opts.insecure,
            rateBitsPerSecond: Int(opts.wireRateMbps * 1_000_000),
            capabilities: declared,
            allowedClientStatics: allowed,
            handshakeGateConfig: gateConfig,
            pairing: pairingService,
            onPairingEvent: handlePairingEvent
        )
        if let hostStatic {
            // HS-10: the advertisement goes up BEFORE the handshake wait,
            // so a browsing client can find the host and then connect to
            // it — commit-and-retain is all Avahi needs (the entry group
            // lives as long as the D-Bus connection; no servicing loop).
            if opts.advertise, let listenPort = opts.wireListen {
                do {
                    advertiser = try AvahiAdvertiser(
                        port: listenPort,
                        staticPublicKey: hostStatic.publicKey,
                        interfaceName: opts.advertiseInterface
                    )
                } catch {
                    print("discovery: unavailable (\(error)) — "
                        + "manual host:port still works")
                }
            }
            try w.awaitClient(hostStatic: hostStatic, timeoutSeconds: 120)
        }
        wire = w
        print("session: up — pacer \(opts.wireRateMbps) Mbps, per-packet "
            + "TOS (video 0xA0 / ctrl+audio+repairs 0xC0), 1 Hz beacon "
            + "on CTRL")

        // HS-20: the estimator's ceiling reaches the encoder as rate
        // directives — the direct leg applies them live (RC misc
        // buffer on the next frame). The baseline mirrors the native
        // seat's opening posture: VBR under the wire-rate cap, no CBR
        // average, VBV at the unprotectable-frame guard's ceiling
        // (HS-25: a squeeze→clean RESTORE returns to the guarded
        // posture and can never re-open the >255-shard hole).
        if opts.vbvReconfigure {
            let guardBits = w.worstCaseProtectableFrameCeiling * 8
            let rateBits = Int(opts.wireRateMbps * 1_000_000)
            // The native seat applies rate moves without a reset BY
            // CONSTRUCTION (no libavcodec, no hidden NVENC reset), so
            // the ladder keeps the posture the vendored no-reset lib
            // had to prove: half-rungs and exact tightens (HS-33).
            // The loosening sustain stays at HS-27's 10 s DELIBERATELY
            // — an eager sustain was measured live to chase every
            // climb into a zero-loss floor limit cycle (2026-07-29
            // armed A/B).
            w.armEncoderVbv(EncoderVbvConfig(
                fps: Int(opts.fps),
                baselineAverageBitsPerSecond: nil,
                baselineMaxBitsPerSecond: rateBits,
                baselineVbvBits: guardBits,
                rungsPerOctave: 2,
                exactTighten: true
            ))
        } else {
            print("encoder-vbv: DISABLED (--no-vbv-reconfigure) — the "
                + "opening posture rides the whole run")
        }

        // HS-13: the injection backend comes up with the session — the
        // Mutter RemoteDesktop session is independent of the portal
        // capture (CP-5 Q6: the video token is never touched).
        if let injector = makeInputInjector(opts.input) {
            w.inputInjector = injector
            print("input: injection via \(injector.name) "
                + "(echo tuples + lastInputSeq stamping active)")
        }

        // HS-19: the clipboard loop — client 0x1A sets apply through
        // the leaf; leaf-observed changes (genuine copies AND the
        // applies' own echoes, which the session's book suppresses)
        // flow back through noteHostClipboardChanged. All of it rides
        // the video tick's off-lock service pass.
        if let leaf = clipboardLeaf {
            w.clipboardApplyHandler = { [weak leaf] text in
                leaf?.apply(text: text)
            }
            w.clipboardServiceHook = { [weak leaf] in
                leaf?.service()
            }
            leaf.onLocalChange = { [weak w] text in
                w?.noteHostClipboardChanged(text)
            }
            // P-1: the image loop rides the same seams — client
            // images apply through the leaf; leaf-observed image
            // copies (genuine AND the applies' echoes) flow back
            // through the session's shared book.
            if opts.clipboardImages {
                w.clipboardImageApplyHandler = { [weak leaf] data in
                    leaf?.apply(imageData: data)
                }
                leaf.onLocalImageChange = { [weak w] data in
                    w?.noteHostClipboardImageChanged(data)
                }
            }
        }

        // F-3: the file-drop loop — chan-8 bulk messages buffered
        // under the session lock, driven through the shell (disk IO,
        // hashing) on the same off-lock service pass the clipboard
        // rides; the shell's replies re-enter through sendBulk.
        w.bulkShell = bulkShell
    }

    // HS-15: audio comes up with the session, on its own capture loop
    // thread — continuous 5 ms CBR from establishment, silence
    // included (the cadence is the receiver's clock and the path
    // probe). A missing default sink degrades to a warning, never a
    // failure: the screen must stream even if audio cannot.
    // HS-18: the leaf comes up in the --host-audio posture, and a
    // capability-negotiated client can flip it (0x18) — the handler
    // below rebuilds the leaf in the other routing.
    var audioWire: AudioWire?
    if sessionMode, opts.audio, let w = wire {
        do {
            let audio = try AudioWire(
                wire: w, bitrate: opts.audioBitrate, mode: opts.hostAudio
            )
            audio.start(seconds: opts.seconds + 20.0)
            audioWire = audio
            w.setInitialAudioRouting(opts.hostAudio)
            w.audioRoutingHandler = { mode in
                // Runs on the video-loop thread, off the session lock
                // (SessionWire.service drains requests there). The
                // 5 ms stream pauses across the rebuild — one leaf
                // owns the quantum forcing, so two never overlap.
                audioWire?.stop()
                audioWire = nil
                // Mute-at-source (postures design, mode 0x03): stop
                // IS the whole apply — no capture, no encode, zero
                // packets; the host's own speakers keep playing. The
                // return-to-streaming request rebuilds below like any
                // other flip.
                if mode == .streamOff {
                    print("audio-routing: stream OFF — the wire "
                        + "carries no audio track (host speakers "
                        + "unaffected)")
                    return true
                }
                do {
                    let flipped = try AudioWire(
                        wire: w, bitrate: opts.audioBitrate, mode: mode
                    )
                    flipped.start(seconds: opts.seconds + 20.0)
                    audioWire = flipped
                    return true
                } catch {
                    print("audio-routing: rebuild in \(mode) failed "
                        + "(\(error)) — trying to come back "
                        + "\(opts.hostAudio)")
                    if let back = try? AudioWire(
                        wire: w, bitrate: opts.audioBitrate,
                        mode: opts.hostAudio
                    ) {
                        back.start(seconds: opts.seconds + 20.0)
                        audioWire = back
                    }
                    return false
                }
            }
            print("audio: "
                + (opts.hostAudio == .hostMuted
                    ? "\"Lyte Audio\" virtual-sink capture (host MUTED)"
                    : "default-sink monitor capture (host audible)")
                + " → opus \(opts.audioBitrate / 1_000) kbps hard CBR → "
                + "5 ms packets → RS 4+2 → chan 1 (TOS 0xC0 / DSCP 48)")
        } catch {
            print("audio: unavailable (\(error)) — video-only session")
        }
    }

    var file: UnsafeMutablePointer<FILE>?
    if !sessionMode {
        guard let f = fopen(opts.outputPath, "wb") else {
            throw HostError("cannot open \(opts.outputPath) for writing")
        }
        file = f
    }

    // E1/E5: the direct eye is capture AND encode — encoded access
    // units go straight to the wire (or the probe file).
    let leg = DirectEyeLeg(
        config: .init(
            seconds: opts.seconds,
            bitrateBitsPerSecond: wire != nil
                ? Int64(opts.wireRateMbps * 1_000_000) : 0),
        wire: wire, file: file)
    leg.run()

    if let file { fclose(file) }

    // HS-15: quit the audio loop BEFORE the teardown so the last audio
    // shards ride out ahead of the 0x0A, not into a closed session.
    audioWire?.stop()

    // HS-11: the orderly exit — a typed SessionTeardown on the reliable
    // stream (retransmitted until acknowledged or patience runs out), so
    // the client learns the session ended instead of inferring it.
    wire?.shutdown(reason: .shuttingDown)
    // HS-13: close the Mutter RemoteDesktop session (uinput devices die
    // with the process either way).
    wire?.inputInjector?.stop()
    // HS-19: close the clipboard leaf's RemoteDesktop session (its
    // selection ownership and pending transfers die with it; the
    // connection-owned session can never be stranded by a crash).
    clipboardLeaf?.stop()
    // F-3: the receiving end's one resume obligation — persist the
    // mid-flight BulkResumeState beside its staging file so the next
    // session's re-offer resumes from the gap, sha-exact.
    bulkShell?.teardown()

    if let failure = leg.lastError {
        throw HostError(failure)
    }
    if leg.frames == 0 {
        throw HostError("direct eye produced no frames in "
            + "\(Int(opts.seconds))s")
    }
    print("""

    done: \(leg.frames) frames encoded (direct eye), \
    \(leg.keyframes) IDR, \(leg.bytes) bytes, \
    missed_grabs \(leg.missedGrabs), \
    rate directives applied \(leg.directivesApplied)
    """)
    // The stream-startability gate: the native encoder must open with
    // VPS/SPS/PPS + IRAP or the client can never join mid-life.
    let directNals = AnnexB.nalUnits(in: leg.firstPacket)
    print("first packet NALs: \(AnnexB.summary(of: leg.firstPacket))")
    guard AnnexB.startsWithParameterSetsAndIrap(leg.firstPacket) else {
        throw HostError("the direct eye's first packet does not begin "
            + "with VPS/SPS/PPS + an IRAP picture (got: "
            + "\(directNals.map { HevcNal.name($0.type) }.joined(separator: " ")))")
    }
    print("first packet starts with parameter sets + IDR: OK")

    // The session books — the wire half is backend-agnostic evidence.
    if let wire {
        let t = wire.pacerTelemetry
        let c = wire.counters
        let s = wire.sessionCounters
        // HS-19: the leaf's own books (byte-level transfer evidence),
        // appended to the clipboard line when the leaf ran.
        // HS-20: the final standing directive, if any moved the encoder.
        var vbvFinal = ""
        if let d = wire.lastVbvDirective {
            let avg = d.averageBitsPerSecond
                .map { " avg \($0 / 1_000) kbps," } ?? ""
            vbvFinal = " — final\(avg) max \(d.maxBitsPerSecond / 1_000) "
                + "kbps, vbv \(d.vbvBits / 8) B "
                + "(ceiling \(d.frameByteCeiling) B)"
        }
        // F-3: the shell's own books (chunk/byte-level evidence),
        // appended to the files line when the shell ran.
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
            clipboardLeafStats += ", \(leaf.baselineReplaysSkipped) baseline skipped)"
        }
        print("""
        session: \(c.framesIngested) frames → \(c.shardsEnqueued) shards → \
        \(wire.datagramsSent) datagrams (\(wire.bytesSent) B) in \
        \(t.batches) paced batches; max batch wire time \
        \(t.maxBatchWireTimeNS) ns (quantum 1000000); freshVideo max queue \
        delay \(t[.freshVideo].maxQueueDelayNS) ns
        socket: \(wire.socketWouldBlockCount) would-block retries, pending max \
        \(wire.socketPendingMaxDatagrams) datagrams / \
        \(wire.socketPendingMaxBytes) B; audio blocked \
        \(wire.audioSocketWouldBlockCount) times, outbox max \
        \(wire.audioSocketOutboxMaxNS) ns at seq \
        \(wire.audioSocketWorstSeq.map(String.init) ?? "—") \
        (enqueued/accepted \
        \(wire.audioSocketWorstEnqueuedAtNS.map(String.init) ?? "—")/\
        \(wire.audioSocketWorstAcceptedAtNS.map(String.init) ?? "—"), \
        behind video \(wire.audioSocketWorstBlockedByVideo)); kernel sndbuf \
        \(wire.socketSendBufferBytes) B, outq max \
        \(wire.socketOutqMaxBytes) B; latency lane sndbuf \
        \(wire.latencySocketSendBufferBytes) B, outq max \
        \(wire.latencySocketOutqMaxBytes) B; ENOBUFS \
        \(wire.socketENOBUFSCount), outq query failures \
        \(wire.socketOutqQueryFailures); pressure \
        \(wire.kernelPressureState), video debt \
        \(wire.kernelVideoServiceDebtNS) ns, EAGAIN video/latency \
        \(wire.videoSocketWouldBlockCount)/\
        \(wire.latencySocketWouldBlockCount), ENOBUFS video/latency \
        \(wire.videoSocketENOBUFSCount)/\
        \(wire.latencySocketENOBUFSCount), stale fresh shed \
        \(wire.socketFreshVideoShedDatagrams) datagrams / \
        \(wire.socketFreshVideoShedBytes) B
        session: \(s.beaconsSent) beacons, \(s.beaconEchoes) echoes \
        (last offset \(wire.clock.lastOffsetMicroseconds.map(String.init) ?? "—") µs, \
        min rtt \(wire.clock.minRttMicroseconds.map(String.init) ?? "—") µs), \
        \(s.idrRequests) IDR requests, \(s.unsealFailures) unseal failures, \
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
        encoder 4:2:0 (native VAAPI)
        input: \(s.inputEventsReceived) events received, \
        \(wire.inputInjected) injected \
        (\(wire.inputInjectFailures) failed), \
        \(s.inputEchoTuplesSent) echo tuples sent; receive→inject \
        p50 \(wire.inputLatency.p50.map(String.init) ?? "—") µs / \
        p99 \(wire.inputLatency.p99.map(String.init) ?? "—") µs / \
        max \(wire.inputLatency.maxValue.map(String.init) ?? "—") µs
        audio: \(s.audioPacketsIngested) packets → \
        \(s.audioDatagramsEnqueued) datagrams \
        (\(s.audioGroupsCompleted) RS 4+2 groups), \
        \(s.audioPacketsSuppressed) suppressed, \
        \(wire.audioSendFailures) send failures, \
        \(wire.audioPacketsDroppedPreSession) dropped pre-session; \
        max audio queue delay \(t[.audio].maxQueueDelayNS) ns; \
        mailbox depth max \(wire.audioMailboxMaxDepth), \
        dwell p99 \(wire.audioMailboxDwell.p99.map(String.init) ?? "—") ns / \
        max \(wire.audioMailboxMaxDwellNS) ns, \
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
        \(wire.estimatorStats.fallDeferrals) dwell deferrals), \
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
        repair: \(s.nackEntriesReceived) NACK entries \
        (\(s.nacksHonored) honored → \(s.repairDatagramsEnqueued) repair \
        datagrams, \(s.nacksJudgedStale) stale, \
        \(s.repairRefusalsSent) refusals sent, \
        \(s.openingExemptRepairsHonored) opening-exempt, \
        \(s.idrArmedOnStaleNack) IDR-armed; \
        budget \(wire.repairBudgetMS) ms), \
        \(wire.estimatorStats.nackShardsCounted) post-FEC shards counted \
        (\(wire.estimatorStats.nackShardsRecused) recused as self-drain), \
        \(wire.estimatorStats.postFecDownshifts) rung-3 downshifts, \
        \(s.fecRegimeSteps) regime steps (final \(wire.fecRegime.rawValue)); \
        srtt \(wire.srttMicros.map { "\($0) µs" } ?? "—"), \
        store \(wire.repairStoreBytes) B
        """)
        if let audio = audioWire {
            let trip = audio.tripwireCounters
            print("audio: \(audio.packetsEncoded) packets encoded "
                + "(\(audio.encodeFailures) encode failures)"
                + (audio.negotiated.map {
                    ", negotiated F32 \($0.rate) Hz \($0.channels)ch"
                } ?? ", no buffers arrived")
                + (trip.quietEntries > 0
                    ? "; tripwire \(trip.quietEntries) quiet, "
                        + "\(trip.wakes) wakes, "
                        + "\(trip.packetsGated) gated, "
                        + "\(trip.preRollShipped) pre-roll shipped"
                    : "")
                + (audio.negotiationError.map { "; ERROR \($0)" } ?? "")
                + (audio.runError.map { "; run error \($0)" } ?? ""))
        }
    } else {
        print("output: \(opts.outputPath)")
    }
    if let pairing = pairingService {
        if let key = pairing.pairedClientStaticPublicKey {
            print("pairing: result — PAIRED, client "
                + HostStaticKey.hex(key))
        } else if pairing.isBurned {
            print("pairing: result — PIN burned, nothing pinned")
        } else {
            print("pairing: result — no client paired this run")
        }
    }

    // The advertiser is retained to this line on purpose: the record
    // stays published for the whole session and returning withdraws it.
    withExtendedLifetime(advertiser) {}
}

// Subcommands, each of which never returns: `sniff` is the HS-5
// Lyte-UDP header dissector (Sniff.swift); `advertise` is the HS-10
// standalone Avahi advertisement (AvahiAdvertise.swift). Everything
// else is the capture path.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "sniff" {
    sniffMain(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "advertise" {
    lyte_stdout_linebuf() // prints must land live through an ssh pipe
    advertiseMain(Array(CommandLine.arguments.dropFirst(2)))
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("lyte-host: error: \(error)\n".utf8))
    exit(1)
}
