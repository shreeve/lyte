// lyte-host capture spike (H0a slice 1): portal ScreenCast → PipeWire frames
// → NVENC HEVC (libavcodec leaf) → Annex-B file. HS-5 added the wire mode;
// HS-7 turns it into a real session: `--wire-out HOST:PORT` (or
// `--wire-listen PORT`) runs HostWire.Session — Noise IK responder
// handshake against a connecting client (default) or the `--insecure`
// CP-3 passthrough — then capture → encode → VideoChannel → seal → Pacer
// → CNetIO, with 1 Hz beacons, conn-id TLVs, and inbound handling
// (echoes, IDR requests, path challenges) on the same loop.

import CHevcEncode
import CPipeWireCapture
import Foundation
import HostCore
import HostWire
import LyteWire

// MARK: - Options

enum Backend: String {
    case portal
    case mutter
}

struct Options {
    var outputPath = "/tmp/lyte-h0a.hevc"
    var seconds = 5.0
    var bitrate: Int64 = 10_000_000
    /// True when --bitrate-mbps was given: in session mode an
    /// unspecified encoder recipe PAIRS to the wire rate (HS-23/R2 —
    /// one knob moves both unless the operator splits them).
    var bitrateExplicit = false
    var fps: Int32 = 60
    var backend: Backend = .portal
    var connector = ""
    var idleFloor = true
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
    /// the encoder keeps its opening recipe for the whole run (the
    /// pre-HS-20 posture, everything else identical). Debug only.
    var vbvReconfigure = true
    /// HS-24: the NVENC recipe. The shipped posture is
    /// EncoderRecipe.sessionDefault (test-pinned in HostCore); the
    /// --enc-* knobs exist for A/B ladder legs, one flag per leg.
    var encoderRecipe = EncoderRecipe.sessionDefault

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
            case "--bitrate-mbps":
                i += 1
                guard i < args.count, let v = Double(args[i]), v > 0 else {
                    throw HostError("--bitrate-mbps needs a positive number")
                }
                opts.bitrate = Int64(v * 1_000_000)
                opts.bitrateExplicit = true
            case "--backend":
                i += 1
                guard i < args.count, let b = Backend(rawValue: args[i]) else {
                    throw HostError("--backend must be 'portal' or 'mutter'")
                }
                opts.backend = b
            case "--connector":
                i += 1
                guard i < args.count else { throw HostError("--connector needs a name") }
                opts.connector = args[i]
            case "--no-idle-floor":
                opts.idleFloor = false
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
            case "--enc-preset":
                i += 1
                guard i < args.count else {
                    throw HostError("--enc-preset needs p1…p7")
                }
                opts.encoderRecipe.preset = args[i]
            case "--enc-tune":
                i += 1
                guard i < args.count else {
                    throw HostError("--enc-tune needs ull or ll")
                }
                opts.encoderRecipe.tune = args[i]
            case "--enc-multipass":
                i += 1
                guard i < args.count else {
                    throw HostError(
                        "--enc-multipass needs disabled, qres, or fullres")
                }
                opts.encoderRecipe.multipass = args[i]
            case "--enc-spatial-aq":
                opts.encoderRecipe.spatialAQ = true
            case "--enc-temporal-aq":
                opts.encoderRecipe.temporalAQ = true
            case "--enc-aq-strength":
                i += 1
                guard i < args.count, let v = Int(args[i]) else {
                    throw HostError("--enc-aq-strength needs 1…15")
                }
                opts.encoderRecipe.aqStrength = v
            case "--audio-bitrate-kbps":
                i += 1
                guard i < args.count, let v = Int32(args[i]), v > 0 else {
                    throw HostError("--audio-bitrate-kbps needs a "
                        + "positive number")
                }
                opts.audioBitrate = v * 1_000
            case "--help", "-h":
                print("""
                usage: lyte-host [--out PATH] [--seconds N] [--bitrate-mbps N]
                                 [--backend portal|mutter] [--connector NAME]
                                 [--no-idle-floor] [--ratchet]
                                 [--wire-out HOST:PORT] [--wire-rate-mbps N]
                Captures the desktop and writes Annex-B HEVC (hevc_nvenc) to
                PATH (default /tmp/lyte-h0a.hevc).
                  --backend portal  xdg-desktop-portal ScreenCast (primary;
                                    one-time on-screen consent on first run)
                  --backend mutter  org.gnome.Mutter.ScreenCast (no dialog;
                                    spike fallback for headless/ssh runs)
                  --connector NAME  monitor connector for the mutter backend
                                    (e.g. DP-1); empty records the primary
                  --no-idle-floor   disable the steady-rate supply (encode
                                    only damage-driven frames; debugging aid)
                  --ratchet         quality-ratchet prototype: capped-CQ VBR
                                    instead of CBR; after 250ms of damage
                                    quiet, re-encode the retained frame at a
                                    fraction of fps until quality converges
                                    at the visually-lossless floor, then go
                                    silent (replaces the steady idle floor)
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
                                    recipe rides the whole run)
                  --enc-preset pN   NVENC preset override (p1…p7) for
                                    an A/B ladder leg; the shipped
                                    recipe is HostCore's test-pinned
                                    EncoderRecipe.sessionDefault
                  --enc-tune T      NVENC tuning override: ull or ll
                  --enc-multipass M rate-control passes: disabled,
                                    qres, or fullres
                  --enc-spatial-aq  enable spatial adaptive quantization
                  --enc-temporal-aq enable temporal AQ (expected to be
                                    rejected at open: it needs
                                    lookahead, which the latency frame
                                    forbids)
                  --enc-aq-strength N
                                    spatial-AQ strength 1…15
                                    (default: nvenc's 8)
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
                             lyte-host rd-spike …         (CP-5 input probe)
                             lyte-host advertise …        (HS-10 discovery)
                """)
                exit(0)
            default:
                throw HostError("unknown argument \(args[i]) (try --help)")
            }
            i += 1
        }
        do {
            _ = try opts.encoderRecipe.validated()
        } catch let knob as EncoderRecipe.KnobError {
            switch knob {
            case .preset(let v):
                throw HostError("--enc-preset must be p1…p7 (got \(v))")
            case .tune(let v):
                throw HostError("--enc-tune must be ull or ll (got \(v))")
            case .multipass(let v):
                throw HostError("--enc-multipass must be disabled, qres, "
                    + "or fullres (got \(v))")
            case .aqStrength(let v):
                throw HostError("--enc-aq-strength must be 1…15 (got \(v))")
            // No CLI flag reaches these three — the chroma knobs are
            // negotiated (V-4), not operator-tunable; a hit here is a
            // recipe-authoring bug, named plainly.
            case .profile(let v):
                throw HostError("recipe profile must be '' or rext (got \(v))")
            case .rgbMode(let v):
                throw HostError("recipe rgb-mode must be '' or yuv444 "
                    + "(got \(v))")
            case .ratchetFloorQP(let v):
                throw HostError("recipe ratchet floor must be 1…51 (got \(v))")
            }
        }
        return opts
    }
}

// MARK: - Capture → encode sink

final class Sink {
    let opts: Options
    var capture: OpaquePointer?
    var encoder: OpaquePointer?
    /// Exactly one of these is the packet destination: the Annex-B file
    /// (H0a spike) or the Lyte-UDP session leg (HS-7 `--wire-out`).
    var file: UnsafeMutablePointer<FILE>?
    var wire: SessionWire?

    var framesIn = 0
    var damageFrames = 0
    var repeatedFrames = 0
    var packetsOut = 0
    var bytesOut = 0
    var keyframes = 0
    var firstFrameAt: Double?
    var lastError: String?
    var firstPacket: [UInt8] = []
    var negotiated: (width: UInt32, height: UInt32, format: String)?

    // Idle-floor state. On a tick with no fresh frame since the previous
    // tick, the last frame is re-encoded as an ordinary P-frame — via
    // lyte_hevc_enc_resend, which reuses the pixels the encoder's own
    // AVFrame retained from the last send (no per-damage-frame copy of
    // the ~full capture buffer). lastFrame survives only for LYTE_DUMP_RAW,
    // which wants the raw pixels at exit. Ticks and frame callbacks share
    // the PipeWire loop thread, so no locking is needed.
    let wantsRawDump =
        ProcessInfo.processInfo.environment["LYTE_DUMP_RAW"] != nil
    var lastFrame: [UInt8] = []
    var lastStride: Int32 = 0
    var encodedSinceTick = false

    // Capture-timestamp plumbing (HS-5): the graph-clock µs of the frame
    // an encode call is about to consume; onPacket forwards it into the
    // envelope (encode is synchronous — NVENC runs zero-delay, 1-in-1-out).
    // A repeated/ratcheted frame carries the RETAINED frame's stamp: the
    // timestamp says when the pixels were captured, not when they were
    // re-encoded.
    var pendingCaptureUs: UInt64 = 0
    var lastFrameGraphUs: UInt64 = 0
    /// HS-18: the SIGINT/SIGTERM notice printed once.
    var terminationNoted = false

    // Quality-ratchet prototype (--ratchet). The encoder runs capped-CQ VBR
    // with qmin pinned at the floor; each re-encode of the retained frame
    // lets nvenc walk the frame QP one rung down, so the ladder emerges from
    // rate control — Swift only decides when to feed passes and when to stop.
    enum Ratchet {
        // The floor QP itself lives on the EncoderRecipe (V-4: the
        // Good tier ships 12 — spec §3's visually-lossless target —
        // and the Best tier carries its own); the Sink reads it off
        // the recipe the negotiated posture chose.
        static let settle = 0.25      // damage-quiet time before ratcheting
        static let paceDivisor = 4    // passes run at fps/paceDivisor
        static let skipBytes = 2048   // pass this small is ~all-skip: done
        static let stableRatio = 0.01 // <1% byte delta counts as stable
        static let stablePasses = 3   // stable passes at the floor: done
    }
    var lastDamageAt: Double?
    var ratchetTriggeredAt: Double?
    var ratchetConverged = false
    var ratchetTickCount = 0
    var ratchetStep = 0
    var ratchetStableCount = 0
    var ratchetPrevBytes = 0
    var ratchetEpisodeBytes = 0
    var ratchetFrames = 0
    var ratchetBytes = 0

    // Most recent packet's stats, recorded by onPacket for the ratchet pass
    // that synchronously produced it.
    var lastPacketBytes = 0
    var lastPacketQP = -1
    // HS-20: encoder-VBV reconfigures applied to the leaf, and the
    // rolling frame-size books (5 s windows, session mode only) — the
    // live gate's before/during/after percentile evidence that a rate
    // drop actually shrinks emitted frames.
    var encoderReconfigures = 0
    var frameWindowSizes: [Int] = []
    var frameWindowStartedAt: Double?
    static let frameWindowSeconds = 5.0
    // HS-22 quality books: one line per second of session-mode
    // encoding — nvenc's frame-average QP (the packet's quality-stats
    // side data, already delivered per packet: the cheapest correct
    // source), emitted frame-size percentiles, the encoder's CURRENT
    // rate-control posture vs its opening recipe, and the live
    // ceiling/pacer pair. The line that tells "the encoder is being
    // squeezed on a clean path" from "the estimator is holding low".
    var lastAppliedDirective: EncoderRateDirective?
    var qualityWindowQPs: [Int] = []
    var qualityWindowSizes: [Int] = []
    var qualityWindowStartedAt: Double?
    static let qualityWindowSeconds = 1.0
    // The fps-ceiling stage books (Q-1's red row): where each frame
    // period actually went, in µs — the capture inter-arrival gap,
    // the synchronous NVENC encode, the packetize+FEC+seal ingest,
    // and the pacer-drain wait — plus capture frames the backpressure
    // gate skipped. Session mode only; one `stages:` line per ~5 s.
    var stageGapUs: [UInt64] = []
    var stageEncodeUs: [UInt64] = []
    var stageIngestUs: [UInt64] = []
    var stageDrainUs: [UInt64] = []
    var stageWindowStartedAt: Double?
    var lastOnFrameAt: Double?
    /// Capture-starvation tripwire. Only pointer motion is a structural
    /// damage witness with EMBEDDED cursor mode: keys/buttons/scroll may
    /// legitimately draw nothing. `pointerMotionsAtLastFrame` lets the
    /// detector require a burst of motion injected since the last
    /// capture callback instead of mistaking a damage-driven static desk
    /// (often one compositor frame per second) for starvation.
    var pointerMotionsAtLastFrame = 0
    var starvationWarnedAt: Double?
    var starvationEpisodes = 0
    /// Nanoseconds onPacket spent inside wire.sendFrame during the
    /// current encode call — the packet callback runs INSIDE
    /// lyte_hevc_enc_send, so the encoder's own share is the
    /// difference.
    var sendFrameNanosThisEncode: UInt64 = 0
    var throttledFrames = 0
    static let stageWindowSeconds = 5.0
    // HS-11: the most recent encoded packet's bytes, retained only in
    // ratchet+session mode — on convergence this IS the final converged
    // frame, re-sent on a reliable one-shot before the idle flip.
    var lastEncodedPacket: [UInt8] = []

    // HS-25: the opening VBV cap actually applied (nil = the recipe's
    // own VBV already sat under the protectable ceiling), and the last
    // unprotectable-drop count already logged.
    var openingVbvCapBits: Int64?
    var unprotectableLogged = 0

    // The estimator-ramp hunt's cause-tagged IDR books (session mode):
    // every keyframe the encoder emits is attributed to the demand(s)
    // recorded at encode time — opening / the session's typed demands
    // (client-request, wake, recovery, path-promotion, stale-nack,
    // unprotectable) / a VBV reconfigure (under DISTRO libavcodec every
    // rate move is a hidden NVENC reset + forced IDR — the HS-22
    // correction; under the HS-33 vendored no-reset lib a rate move
    // mints NO IDR and its tag goes to `reconfigureBooks.noReset`
    // instead, never into this tally) / spontaneous (nothing armed —
    // gop=INT_MAX makes that a finding, not noise). One line per IDR
    // (they are sparse by design), tallied on the final stats block.
    var pendingIdrCauses: [String] = []
    var idrCauseTally: [String: Int] = [:]
    // HS-33: per-directive cost books — IDR-minting vs no-reset,
    // decided by observing whether the encode a directive rode into
    // came back a keyframe (truth by observation, not configuration).
    var reconfigureBooks = EncoderReconfigureBooks()
    /// Whether the linked libavcodec applies rate moves without a
    /// reset (lyte_hevc_noreset_enable at startup: the vendored lib
    /// PROVES itself via its configuration marker + the env gate).
    let noResetRateMoves: Bool

    // V-4: the negotiated chroma posture (drives the encoder open), the
    // recipe it chose (floor QP included — the ratchet reads it here),
    // and the brief pre-agreement hold. The capability exchange rides
    // the reliable stream right behind the handshake, so it is nearly
    // always settled before the portal delivers a first frame; when it
    // is not, encoding holds briefly rather than opening the wrong
    // posture (chroma never moves mid-session — a wrong open would ride
    // to teardown). A peer that never declares (the grandfathered
    // pre-W7 posture) falls back to 4:2:0 at the deadline.
    var activeChroma = ChromaPosture.yuv420
    var activeRecipe: EncoderRecipe
    var chromaHoldStartedAt: Double?
    var framesHeldForChroma = 0
    static let chromaHoldSeconds = 2.0

    init(opts: Options, file: UnsafeMutablePointer<FILE>?, wire: SessionWire?,
         noResetRateMoves: Bool = false) {
        self.opts = opts
        self.file = file
        self.wire = wire
        self.activeRecipe = opts.encoderRecipe
        self.noResetRateMoves = noResetRateMoves
    }

    static func pixFmtName(_ fmt: lyte_pixfmt) -> String? {
        switch fmt {
        case LYTE_PIXFMT_BGRX: return "bgr0"
        case LYTE_PIXFMT_BGRA: return "bgra"
        case LYTE_PIXFMT_RGBX: return "rgb0"
        case LYTE_PIXFMT_RGBA: return "rgba"
        default: return nil
        }
    }

    func fail(_ message: String) {
        lastError = message
        if let capture { lyte_pw_capture_quit(capture) }
    }

    func onFrame(data: UnsafePointer<UInt8>, size: UInt32, stride: Int32,
                 width: UInt32, height: UInt32, fmt: lyte_pixfmt,
                 graphUs: UInt64) {
        if lastError != nil { return }

        // The buffer-bounds law (v1-final analysis, finding 2): the
        // encode memcpy reads (h-1)*stride + w*4 bytes of this buffer
        // on trust, so no frame — including frame 0 — reaches an
        // encode until its own declared extent fits inside its own
        // declared size. All supported formats are 4 bytes/pixel.
        if width == 0 || height == 0 || stride <= 0
            || Int64(size) < (Int64(height) - 1) * Int64(stride)
                + Int64(width) * 4 {
            fail("capture frame geometry unsafe — \(width)x\(height), "
                + "stride \(stride), \(size) bytes: the frame's extent "
                + "does not fit its buffer; refusing to read past the "
                + "mapped MemFd")
            return
        }

        // The geometry pin (same finding): the encoder is opened once
        // with frame-0 geometry and never revalidated, while PipeWire's
        // negotiated range (1×1…8192×8192) explicitly permits mid-
        // session renegotiation — a monitor-mode change used to send
        // the new extent through the old encoder's memcpy (SIGSEGV or
        // silent adjacent-heap encoding). A changed extent now ends
        // the session cleanly with a typed teardown; the client's
        // reconnect renegotiates at the new geometry.
        if let neg = negotiated, width != neg.width || height != neg.height {
            fail("capture geometry changed mid-session — "
                + "\(neg.width)x\(neg.height) → \(width)x\(height): the "
                + "encoder is opened for the original extent; ending "
                + "the session (reconnect renegotiates)")
            return
        }

        if encoder == nil {
            guard let name = Sink.pixFmtName(fmt) else {
                fail("PipeWire negotiated an unsupported pixel format "
                    + "(spa value \(fmt.rawValue)); this slice supports "
                    + "BGRx/BGRA/RGBx/RGBA")
                return
            }
            // V-4: the encoder posture branches on the agreed chroma
            // singleton (declaration-as-choice, owner decision 1).
            // Agreement pending → hold encoding briefly instead of
            // opening a posture the client didn't choose.
            if let wire {
                let agreed = wire.agreedChromaModes
                if agreed == nil {
                    let now = monotonicNow()
                    let started = chromaHoldStartedAt ?? now
                    chromaHoldStartedAt = started
                    if now - started < Self.chromaHoldSeconds {
                        framesHeldForChroma += 1
                        return
                    }
                    print("chroma: no capability declaration after "
                        + "\(Int(Self.chromaHoldSeconds)) s "
                        + "(\(framesHeldForChroma) frames held) — "
                        + "grandfathered peer, opening 4:2:0")
                }
                activeChroma = ChromaPosture.from(agreedChromaModes: agreed)
            }
            var recipe = opts.encoderRecipe
            if activeChroma == .yuv444 {
                recipe = recipe.chroma444()
            }
            activeRecipe = recipe
            var err = [CChar](repeating: 0, count: 256)
            let cq: Int32 = opts.ratchet ? Int32(recipe.ratchetFloorQP) : 0
            guard let enc = lyte_hevc_enc_new(Int32(width), Int32(height), name,
                                              opts.fps, opts.bitrate, cq,
                                              recipe.preset, recipe.tune,
                                              recipe.multipass,
                                              recipe.spatialAQ ? 1 : 0,
                                              recipe.temporalAQ ? 1 : 0,
                                              Int32(recipe.aqStrength),
                                              recipe.profile, recipe.rgbMode,
                                              &err, err.count) else {
                fail("encoder init failed: \(errString(err))")
                return
            }
            encoder = enc
            negotiated = (width, height, name)
            wire?.noteMonitorExtent(width: width, height: height)
            let rcDesc = opts.ratchet
                ? "capped-CQ vbr cq=\(recipe.ratchetFloorQP), cap \(opts.bitrate / 1_000_000) Mbps"
                : "cbr \(opts.bitrate / 1_000_000) Mbps"
            let chromaDesc = activeChroma == .yuv444
                ? "4:4:4 Rext rgb_mode (VUI 601-limited, signed truthfully)"
                : "4:2:0"
            print("capture: \(width)x\(height) \(name), stride \(stride) — "
                + "encoding hevc_nvenc (\(recipe.summary), \(rcDesc), "
                + "chroma \(chromaDesc))")

            // HS-25: in session mode the opening posture itself must
            // bound every frame to what ONE FEC group can protect (the
            // GF(2⁸) 255-shard block — a 307 KB IDR at the 50 Mbps/p4
            // recipe packetized to 279 data shards and killed the
            // session at HEAD). Capped-CQ opens with NO VBV at all and
            // CBR's single-frame VBV can exceed the block at high
            // rates, so whenever the opening VBV is absent or larger
            // than the worst-case protectable ceiling (lossy column,
            // input stamp riding), impose exactly that ceiling. The
            // wrapper folds it into the first send — which is the
            // forced IDR frame 0 anyway, so the reconfigure costs
            // nothing extra.
            if let wire {
                let capBits =
                    Int64(wire.worstCaseProtectableFrameCeiling) * 8
                let openingVbv: Int64? = opts.ratchet
                    ? nil : Int64(opts.bitrate) / Int64(opts.fps)
                if openingVbv == nil || openingVbv! > capBits {
                    if lyte_hevc_enc_set_rate(enc, 0, opts.bitrate,
                                              capBits,
                                              &err, err.count) == 0 {
                        openingVbvCapBits = capBits
                        print("encoder: unprotectable-frame guard — "
                            + "opening vbv capped at \(capBits / 8) B "
                            + "(one FEC group's worst-case ceiling)")
                    } else {
                        print("encoder: unprotectable-frame guard vbv "
                            + "cap REJECTED: \(errString(err)) — the "
                            + "session-side drop guard still holds")
                    }
                }
            }
        }

        let now = monotonicNow()
        if firstFrameAt == nil { firstFrameAt = now }
        if wire != nil {
            if let last = lastOnFrameAt {
                stageGapUs.append(UInt64(max(now - last, 0) * 1e6))
            }
            lastOnFrameAt = now
            pointerMotionsAtLastFrame =
                wire?.pointerMotionWitness.count ?? pointerMotionsAtLastFrame
        }

        // Hard queue-budget admission: skip BEFORE encode once the live
        // queue has consumed its clean/impaired latency allowance.
        // Session owns both numbers and fall purge uses the same budget,
        // so a capacity cliff cannot leave one policy admitting while
        // another policy preserves a stale tail.
        if let wire {
            let posture = wire.videoAdmissionPosture
            if posture.backlogWireTimeNS >= posture.budgetNS {
                throttledFrames += 1
                return
            }
        }

        if opts.idleFloor || opts.ratchet {
            if wantsRawDump {
                let count = Int(size)
                if lastFrame.count != count {
                    lastFrame = [UInt8](repeating: 0, count: count)
                }
                lastFrame.withUnsafeMutableBytes { dst in
                    dst.copyMemory(
                        from: UnsafeRawBufferPointer(start: data, count: count))
                }
                lastStride = stride
            }
            lastFrameGraphUs = graphUs
        }
        pendingCaptureUs = graphUs

        // Fresh damage abandons any ratchet in progress; the episode restarts
        // once damage goes quiet again.
        lastDamageAt = now
        ratchetTriggeredAt = nil
        ratchetConverged = false
        ratchetStep = 0
        ratchetStableCount = 0
        ratchetPrevBytes = 0
        ratchetEpisodeBytes = 0

        // HS-11: fresh damage into the lifecycle machine BEFORE the
        // encode — in IDLE this is the WAKE (mode=active + this frame
        // owed as an IDR, which encode()'s forced-IDR poll consumes);
        // in ACTIVE it aborts a pending idle flip.
        wire?.noteDamage()

        guard encode(data: data, stride: stride) else { return }
        damageFrames += 1
        encodedSinceTick = true

        quitIfElapsed(now)
    }

    /// Idle-floor tick, on the PipeWire loop thread at the fps interval:
    /// when no fresh frame was encoded since the previous tick, re-encode
    /// the retained copy so output flows at a steady rate. In ratchet mode
    /// the same tick instead drives quality-refinement passes. In session
    /// mode the tick is also the between-frames service point — inbound
    /// datagrams (echoes, IDR requests, path messages) and the 1 Hz
    /// beacon timer run here, on the same thread as everything else.
    func onTick() {
        if lastError != nil { return }

        // HS-18: an interrupted run (SIGINT/SIGTERM) exits through the
        // same door as a completed one, so the audio-routing restore
        // and the typed teardown both happen.
        if lyteTerminationRequested != 0, let capture {
            if !terminationNoted {
                terminationNoted = true
                print("session: termination signal — closing cleanly")
            }
            lyte_pw_capture_quit(capture)
            return
        }

        wire?.service()
        flushFrameWindow(monotonicNow())
        flushQualityWindow(monotonicNow())
        flushStageWindow(monotonicNow())

        // The session is over (peer gone, teardown, liveness): stop the
        // capture loop cleanly — the HS-11 graceful exit.
        if wire?.sessionEnded == true, let capture {
            lyte_pw_capture_quit(capture)
            return
        }

        let now = monotonicNow()
        quitIfElapsed(now)
        checkCaptureStarvation(now)

        if encodedSinceTick {
            encodedSinceTick = false
            return
        }
        guard framesIn > 0 else { return } // nothing to repeat yet

        if opts.ratchet {
            ratchetTick(now)
            return
        }

        pendingCaptureUs = lastFrameGraphUs
        if encode(data: nil, stride: 0) { repeatedFrames += 1 }
    }

    /// One ratchet opportunity: after damage has been quiet for the settle
    /// time, re-encode the retained frame at fps/paceDivisor. Each pass lets
    /// capped-CQ rate control step the frame QP down; stop on convergence —
    /// an ~all-skip pass, or byte-stable passes once the QP floor is reached.
    /// After convergence: true silence until new damage.
    private func ratchetTick(_ now: Double) {
        guard !ratchetConverged else { return }
        guard let quietSince = lastDamageAt,
              now - quietSince >= Ratchet.settle else { return }

        ratchetTickCount += 1
        guard ratchetTickCount % Ratchet.paceDivisor == 0 else { return }

        if ratchetTriggeredAt == nil { ratchetTriggeredAt = now }
        pendingCaptureUs = lastFrameGraphUs
        guard encode(data: nil, stride: 0) else { return }

        ratchetStep += 1
        ratchetFrames += 1
        ratchetBytes += lastPacketBytes
        ratchetEpisodeBytes += lastPacketBytes
        let sinceTrigger = (now - ratchetTriggeredAt!) * 1000
        print(String(format: "ratchet: step %2d  qp=%2d  bytes=%7d  t+%.0f ms",
                     ratchetStep, lastPacketQP, lastPacketBytes, sinceTrigger))

        if lastPacketBytes <= Ratchet.skipBytes {
            ratchetConverged = true
        } else if lastPacketQP <= activeRecipe.ratchetFloorQP, ratchetPrevBytes > 0,
                  abs(lastPacketBytes - ratchetPrevBytes)
                      <= Int(Double(ratchetPrevBytes) * Ratchet.stableRatio) {
            ratchetStableCount += 1
            ratchetConverged = ratchetStableCount >= Ratchet.stablePasses
        } else {
            ratchetStableCount = 0
        }
        ratchetPrevBytes = lastPacketBytes

        if ratchetConverged {
            print(String(format: "ratchet: converged after %d passes, "
                + "%d bytes, %.0f ms — going silent", ratchetStep,
                ratchetEpisodeBytes, sinceTrigger))
            // HS-11: the all-skip stop is the machine's ratchetConverged
            // input — the final converged frame rides a reliable
            // one-shot, and its acknowledgment flips the mode to IDLE.
            if let wire, !lastEncodedPacket.isEmpty {
                wire.noteRatchetConverged(
                    finalFrame: lastEncodedPacket,
                    captureMicros: lastFrameGraphUs
                )
            }
        }
    }

    /// Encodes one frame; pts advances monotonically per encoded frame.
    /// Frame 0 is a forced IDR, and in session mode so is any frame the
    /// session demands one for (HS-12 path promotion or a client 0x10 —
    /// the takeFreshKeyframeRequest poll, consulted per encode).
    /// `data == nil` re-encodes the retained frame inside the C leaf
    /// (the encoder's AVFrame still holds the last-submitted pixels) —
    /// the idle-floor repeat and ratchet passes pay no input copy. Callers
    /// of the nil form must have encoded at least once (framesIn > 0).
    private func encode(data: UnsafePointer<UInt8>?, stride: Int32) -> Bool {
        var err = [CChar](repeating: 0, count: 256)
        let user = Unmanaged.passUnretained(self).toOpaque()
        let demand = wire?.takeForcedIdrDemand() ?? []
        let forceIdr = framesIn == 0 || !demand.isEmpty
        pendingIdrCauses = framesIn == 0 ? ["opening"] : []
        pendingIdrCauses += demand.names
        // HS-20: the estimator's ceiling into the encoder BEFORE this
        // frame — the wrapper folds the changed rc fields into one
        // NvEncReconfigureEncoder on the send below.
        var appliedDirectiveKind: EncoderRateDirective.Kind?
        if let directive = wire?.takeEncoderRateDirective() {
            if lyte_hevc_enc_set_rate(
                encoder,
                Int64(directive.averageBitsPerSecond ?? 0),
                Int64(directive.maxBitsPerSecond),
                Int64(directive.vbvBits),
                &err, err.count
            ) == 0 {
                encoderReconfigures += 1
                appliedDirectiveKind = directive.kind
                // The books' cause tag for the IDR this reconfigure is
                // about to force through DISTRO libavcodec (nvenc
                // resets on any rc delta) — the policy names its own
                // move (HS-27): tighten / rung (a sustained loosening
                // step) / restore (the recipe back). Under the HS-33
                // no-reset lib the move mints NO IDR, so the tag never
                // arms — it lands in reconfigureBooks.noReset after
                // the send observes the outcome.
                if !noResetRateMoves {
                    switch directive.kind {
                    case .tighten: pendingIdrCauses.append("vbv-tighten")
                    case .loosen: pendingIdrCauses.append("vbv-rung")
                    case .restore: pendingIdrCauses.append("vbv-restore")
                    }
                }
                lastAppliedDirective = directive
                let avg = directive.averageBitsPerSecond
                    .map { "avg \($0 / 1_000) kbps, " } ?? ""
                print("encoder: rate reconfigure"
                    + (noResetRateMoves ? " (no-reset)" : "")
                    + " — \(avg)max "
                    + "\(directive.maxBitsPerSecond / 1_000) kbps, vbv "
                    + "\(directive.vbvBits / 8) B (frame ceiling "
                    + "\(directive.frameByteCeiling) B)")
            } else {
                print("encoder: rate reconfigure REJECTED: "
                    + errString(err))
            }
        }
        sendFrameNanosThisEncode = 0
        let keyframesBeforeSend = keyframes
        let encodeStart = monotonicNS()
        let rc: Int32
        if let data {
            rc = lyte_hevc_enc_send(encoder, data, stride, Int64(framesIn),
                                    forceIdr ? 1 : 0,
                                    packetTrampoline, user, &err, err.count)
        } else {
            rc = lyte_hevc_enc_resend(encoder, Int64(framesIn),
                                      forceIdr ? 1 : 0,
                                      packetTrampoline, user, &err, err.count)
        }
        if rc == -2 { return false } // nothing retained — callers guard framesIn
        if rc != 0 {
            fail("encode failed at frame \(framesIn): \(errString(err))")
            return false
        }
        if wire != nil {
            // The packet callback (→ sendFrame) runs inside the send
            // call; the encoder's own share is what remains.
            let total = monotonicNS() - encodeStart
            stageEncodeUs.append(
                (total - min(sendFrameNanosThisEncode, total)) / 1_000)
        }
        // HS-33 books: the directive's observed cost. zerolatency means
        // this frame's packet emerged inside the send above, so "did
        // the reconfigure reset the encoder" is answerable RIGHT HERE:
        // a keyframe = the distro wrapper's forced IDR (attributed via
        // the cause tag armed above); a P-frame = the no-reset path
        // rode. A demanded IDR (forceIdr) coinciding with a no-reset
        // move stays the demand's IDR, not the reconfigure's.
        if let kind = appliedDirectiveKind {
            let mintedByReconfigure = noResetRateMoves
                ? (keyframes > keyframesBeforeSend && !forceIdr)
                : keyframes > keyframesBeforeSend
            reconfigureBooks.note(kind, mintedIdr: mintedByReconfigure)
            if noResetRateMoves && mintedByReconfigure {
                // Should be structurally impossible (the spike measured
                // zero across every move shape) — loud if it ever isn't.
                print("encoder: WARNING — no-reset rate reconfigure "
                    + "returned an IDR anyway (kind \(kind.rawValue)); "
                    + "investigate before trusting the idr-books")
            }
        }
        // Attribution done (zerolatency: the packet emerged inside the
        // send above) — a cause never bleeds onto a later frame.
        pendingIdrCauses.removeAll(keepingCapacity: true)
        framesIn += 1
        return true
    }

    /// HS-20 evidence books: every ~5 s of session-mode encoding, one
    /// line of emitted frame-size percentiles next to the live ceiling
    /// and pacer rate — the host-side proof that a rate drop shrinks
    /// frames (and that a release lets them grow back).
    private func flushFrameWindow(_ now: Double) {
        guard let wire else { return }
        guard let started = frameWindowStartedAt else {
            frameWindowStartedAt = now
            return
        }
        guard now - started >= Self.frameWindowSeconds else { return }
        defer {
            frameWindowSizes.removeAll(keepingCapacity: true)
            frameWindowStartedAt = now
        }
        guard !frameWindowSizes.isEmpty else { return }
        let sorted = frameWindowSizes.sorted()
        func pct(_ q: Double) -> Int {
            sorted[max(Int((q * Double(sorted.count)).rounded(.up)), 1) - 1]
        }
        print("frames: \(sorted.count) in \(Int(now - started)) s — "
            + "p50 \(pct(0.5)) B, p95 \(pct(0.95)) B, max \(sorted.last!) B"
            + " | ceiling \(wire.frameByteCeiling(fps: Int(opts.fps))) B, "
            + "pacer \(wire.pacerRate / 1_000) kbps")
    }

    /// HS-22 quality books: every ~1 s of session-mode encoding, the
    /// quality line — QP avg/max, frame-size percentiles, the
    /// encoder's standing rate-control posture vs its opening recipe,
    /// and the live ceiling + pacer rate. Skips windows that encoded
    /// nothing (converged idle).
    private func flushQualityWindow(_ now: Double) {
        guard let wire else { return }
        guard let started = qualityWindowStartedAt else {
            qualityWindowStartedAt = now
            return
        }
        guard now - started >= Self.qualityWindowSeconds else { return }
        defer {
            qualityWindowQPs.removeAll(keepingCapacity: true)
            qualityWindowSizes.removeAll(keepingCapacity: true)
            qualityWindowStartedAt = now
        }
        guard !qualityWindowSizes.isEmpty else { return }
        let sorted = qualityWindowSizes.sorted()
        func pct(_ q: Double) -> Int {
            sorted[max(Int((q * Double(sorted.count)).rounded(.up)), 1) - 1]
        }
        let qp: String
        if qualityWindowQPs.isEmpty {
            qp = "—"
        } else {
            let avg = qualityWindowQPs.reduce(0, +) / qualityWindowQPs.count
            qp = "avg \(avg) max \(qualityWindowQPs.max()!)"
        }
        let openingVbv = openingVbvCapBits
            .map { "\($0 / 8) B (guard)" }
            ?? (opts.ratchet
                ? "none"
                : "\(Int(opts.bitrate) / Int(opts.fps) / 8) B")
        let opening = (opts.ratchet
            ? "capped-cq cap" : "cbr")
            + " \(opts.bitrate / 1_000) kbps vbv \(openingVbv)"
        let posture: String
        if let d = lastAppliedDirective {
            let avg = d.averageBitsPerSecond
                .map { "avg \($0 / 1_000) kbps " } ?? ""
            posture = "applied \(avg)max \(d.maxBitsPerSecond / 1_000) "
                + "kbps vbv \(d.vbvBits / 8) B (opening \(opening))"
        } else {
            posture = "opening \(opening)"
        }
        print("quality: \(sorted.count) fr — qp \(qp), "
            + "p50 \(pct(0.5)) B p95 \(pct(0.95)) B | enc \(posture) | "
            + "ceiling \(wire.frameByteCeiling(fps: Int(opts.fps))) B, "
            + "pacer \(wire.pacerRate / 1_000) kbps")
    }

    /// The fps-ceiling stage books: one line per ~5 s of session-mode
    /// encoding — µs percentiles of the capture inter-arrival gap and
    /// the per-frame encode / ingest (packetize+FEC+seal) / pacer-drain
    /// stages. This is the book that says where a 60 Hz frame period
    /// went when the glass reads 48.
    private func flushStageWindow(_ now: Double) {
        guard wire != nil else { return }
        guard let started = stageWindowStartedAt else {
            stageWindowStartedAt = now
            return
        }
        guard now - started >= Self.stageWindowSeconds else { return }
        defer {
            stageGapUs.removeAll(keepingCapacity: true)
            stageEncodeUs.removeAll(keepingCapacity: true)
            stageIngestUs.removeAll(keepingCapacity: true)
            stageDrainUs.removeAll(keepingCapacity: true)
            stageWindowStartedAt = now
        }
        guard !stageEncodeUs.isEmpty else { return }
        func book(_ samples: [UInt64]) -> String {
            let sorted = samples.sorted()
            guard !sorted.isEmpty else { return "—" }
            func pct(_ q: Double) -> Double {
                Double(sorted[max(
                    Int((q * Double(sorted.count)).rounded(.up)), 1) - 1])
                    / 1_000
            }
            return String(format: "p50 %.1f p95 %.1f max %.1f",
                          pct(0.5), pct(0.95), Double(sorted.last!) / 1_000)
        }
        print("stages: \(stageEncodeUs.count) fr — "
            + "gap \(book(stageGapUs)) | encode \(book(stageEncodeUs)) | "
            + "ingest \(book(stageIngestUs)) | drain \(book(stageDrainUs)) "
            + "ms | throttled \(throttledFrames)")
    }

    private func quitIfElapsed(_ now: Double) {
        if let start = firstFrameAt, now - start >= opts.seconds, let capture {
            lyte_pw_capture_quit(capture)
        }
    }

    /// Runtime capture tripwire. A damage-driven screencast is allowed
    /// to sit silent indefinitely; generic input is not proof that pixels
    /// changed. A burst of at least three newly injected pointer motions
    /// is different: EMBEDDED cursor mode owes visible cursor damage.
    /// The C-leaf counters distinguish "PipeWire stopped scheduling us"
    /// from "callbacks arrived but buffers were empty" in one bounded
    /// line, without restarting capture or manufacturing frames/IDRs.
    private func checkCaptureStarvation(_ now: Double) {
        guard let wire, wire.currentWireMode == .active,
              let lastFrame = lastOnFrameAt, now - lastFrame > 0.5 else {
            starvationWarnedAt = nil
            return
        }
        let motion = wire.pointerMotionWitness
        let motionsSinceFrame = motion.count - pointerMotionsAtLastFrame
        guard motionsSinceFrame >= 3, motion.lastAtMicros != 0 else {
            starvationWarnedAt = nil
            return
        }
        let motionAge =
            Double(monotonicMicros() &- motion.lastAtMicros) / 1e6
        guard motionAge < 0.25 else { return }
        if starvationWarnedAt == nil { starvationEpisodes += 1 }
        if let warned = starvationWarnedAt, now - warned < 5 { return }
        starvationWarnedAt = now
        var pw = lyte_pw_capture_stats()
        lyte_pw_capture_get_stats(capture, &pw)
        let processAgeMS = pw.last_process_monotonic_ns == 0
            ? -1
            : Int((monotonicNS() &- pw.last_process_monotonic_ns)
                / 1_000_000)
        print(String(
            format: "capture: STARVED — %d pointer motions since frame "
                + "(last %.2f s ago), no frame for %.0f ms (episode %d); "
                + "PipeWire state=%d process=%llu frames=%llu "
                + "dequeue-empty=%llu buffer-empty=%llu process-age=%d ms",
            motionsSinceFrame, motionAge, (now - lastFrame) * 1000,
            starvationEpisodes, pw.stream_state, pw.process_callbacks,
            pw.frames_delivered, pw.dequeue_empty, pw.buffer_empty,
            processAgeMS))
    }

    func onPacket(data: UnsafePointer<UInt8>, size: Int, keyframe: Bool, avgQP: Int) {
        if firstPacket.isEmpty {
            firstPacket = Array(UnsafeBufferPointer(start: data, count: size))
        }
        if let wire {
            let sendStart = monotonicNS()
            do {
                try wire.sendFrame(data: data, size: size,
                                   isKeyframe: keyframe,
                                   captureMicros: pendingCaptureUs)
                let telemetryCauses = keyframe
                    ? (pendingIdrCauses.isEmpty
                        ? ["spontaneous"] : pendingIdrCauses)
                    : []
                wire.annotateLastVideoFrame(
                    averageQP: avgQP >= 0 ? avgQP : nil,
                    idrCauses: telemetryCauses
                )
            } catch {
                fail("session send failed at packet \(packetsOut): \(error)")
                return
            }
            sendFrameNanosThisEncode &+= monotonicNS() - sendStart
            stageIngestUs.append(wire.lastFrameIngestNanos / 1_000)
            stageDrainUs.append(wire.lastFrameDrainNanos / 1_000)
            // HS-25: the session drops (never throws) a frame one FEC
            // group cannot protect — loud in the log, invisible to the
            // process lifetime. Should only fire if a frame slips past
            // the opening VBV cap above.
            let dropped = wire.videoFramesUnprotectable
            if dropped > unprotectableLogged {
                unprotectableLogged = dropped
                print("video: packet \(packetsOut) UNPROTECTABLE "
                    + "(\(size) B > ceiling "
                    + "\(wire.protectableFrameCeiling) B) — frame "
                    + "dropped, fresh IDR armed (total \(dropped))")
            }
        } else if let file {
            fwrite(data, 1, size, file)
        }
        packetsOut += 1
        bytesOut += size
        if keyframe { keyframes += 1 }
        if keyframe, wire != nil {
            // The cause-tagged IDR books: attribute this keyframe to
            // whatever armed it at encode time; nothing armed means the
            // encoder minted it on its own (gop=INT_MAX → a finding).
            let causes = pendingIdrCauses.isEmpty
                ? ["spontaneous"] : pendingIdrCauses
            for cause in causes { idrCauseTally[cause, default: 0] += 1 }
            let elapsed = firstFrameAt.map {
                monotonicNow() - $0
            } ?? 0
            print("idr: #\(keyframes) at t+"
                + String(format: "%.1f", elapsed) + "s — "
                + causes.joined(separator: "+") + " (\(size) B)")
        }
        if wire != nil {
            frameWindowSizes.append(size)
            qualityWindowSizes.append(size)
            if avgQP >= 0 { qualityWindowQPs.append(avgQP) }
        }
        lastPacketBytes = size
        lastPacketQP = avgQP
        if opts.ratchet, wire != nil {
            lastEncodedPacket = Array(
                UnsafeBufferPointer(start: data, count: size)
            )
        }
    }

    func flushEncoder() throws {
        guard let encoder else { return }
        var err = [CChar](repeating: 0, count: 256)
        let user = Unmanaged.passUnretained(self).toOpaque()
        if lyte_hevc_enc_flush(encoder, packetTrampoline, user, &err, err.count) != 0 {
            throw HostError("encoder flush failed: \(errString(err))")
        }
    }

    func freeEncoder() {
        if let encoder { lyte_hevc_enc_free(encoder) }
        encoder = nil
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

/// V-4: the empirical 4:4:4 gate (pillar §1's probe discipline) — a
/// real tiny Rext open through the production leaf, run at startup
/// before the capability declaration is built. A successful open IS
/// the NV_ENC_CAPS_SUPPORT_YUV444_ENCODE caps check (V-1: the wrapper
/// rejects at open when the cap reads 0), so the host never declares a
/// chroma it hasn't just proven on this exact silicon/driver/wrapper.
/// Returns nil on success, the leaf's error on failure.
func probeRext444Encode() -> String? {
    var err = [CChar](repeating: 0, count: 256)
    let r = EncoderRecipe.best444
    guard let enc = lyte_hevc_enc_new(
        320, 180, "bgr0", 60, 5_000_000, Int32(r.ratchetFloorQP),
        r.preset, r.tune, r.multipass,
        r.spatialAQ ? 1 : 0, r.temporalAQ ? 1 : 0, Int32(r.aqStrength),
        r.profile, r.rgbMode, &err, err.count
    ) else {
        return errString(err)
    }
    lyte_hevc_enc_free(enc)
    return nil
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

/// Does the seat's gnome-shell carry `disable-direct-scanout` in
/// MUTTER_DEBUG_PAINT? Without it, Mutter promotes fullscreen video to
/// direct scanout a few seconds in — compositing stops and the
/// ScreenCast starves, so the remote glass freezes while the host
/// idles (2026-07-30 verdict: wake IDRs + 1 s capture gaps). The flag
/// only lands via gnome-shell's login environment — no runtime toggle
/// exists on stock Mutter — so the most the host can do is testify at
/// startup. Returns nil when there is no readable gnome-shell to
/// inspect (other compositor, headless test rig): nothing to testify.
func mutterDirectScanoutDisabled() -> Bool? {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: "/proc") else { return nil }
    for pid in entries where Int(pid) != nil {
        guard let comm = try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8),
              comm.trimmingCharacters(in: .whitespacesAndNewlines) == "gnome-shell",
              let environ = fm.contents(atPath: "/proc/\(pid)/environ")
        else { continue }  // other users' environ is unreadable — skip
        return environ.split(separator: 0).contains { entry in
            entry.starts(with: Array("MUTTER_DEBUG_PAINT=".utf8))
                && String(decoding: entry, as: UTF8.self).contains("disable-direct-scanout")
        }
    }
    return nil
}

private func frameTrampoline(user: UnsafeMutableRawPointer?,
                             data: UnsafePointer<UInt8>?, size: UInt32,
                             stride: Int32, width: UInt32, height: UInt32,
                             fmt: lyte_pixfmt, graphUs: UInt64) {
    guard let user, let data else { return }
    let sink = Unmanaged<Sink>.fromOpaque(user).takeUnretainedValue()
    sink.onFrame(data: data, size: size, stride: stride,
                 width: width, height: height, fmt: fmt, graphUs: graphUs)
}

private func tickTrampoline(user: UnsafeMutableRawPointer?) {
    guard let user else { return }
    let sink = Unmanaged<Sink>.fromOpaque(user).takeUnretainedValue()
    sink.onTick()
}

private func packetTrampoline(user: UnsafeMutableRawPointer?,
                              data: UnsafePointer<UInt8>?, size: Int,
                              keyframe: Int32, avgQP: Int32) {
    guard let user, let data else { return }
    let sink = Unmanaged<Sink>.fromOpaque(user).takeUnretainedValue()
    sink.onPacket(data: data, size: size, keyframe: keyframe != 0,
                  avgQP: Int(avgQP))
}

// MARK: - Main

func run() throws {
    lyte_stdout_linebuf()

    var opts = try Options.parse(CommandLine.arguments)

    // THE RECIPE PAIRING (HS-23, the supremacy plan's R2): a session's
    // encoder recipe follows the wire rate unless --bitrate-mbps split
    // them deliberately — the pacer's headroom and the encoder's cap
    // move as ONE ceiling-relative recipe (the EncoderVbv k-ladder and
    // clean boundary are fractions of it, so they scale with it).
    // File mode keeps its own 10 Mbps default: no pacer to pair with.
    if opts.wireOut != nil || opts.wireListen != nil, !opts.bitrateExplicit {
        opts.bitrate = Int64(opts.wireRateMbps * 1_000_000)
    }

    guard ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"] != nil
        || FileManager.default.fileExists(
            atPath: "\(ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? "/nonexistent")/bus")
    else {
        throw HostError("no user session bus reachable (DBUS_SESSION_BUS_ADDRESS unset "
            + "and $XDG_RUNTIME_DIR/bus missing) — lyte-host must run inside the "
            + "logged-in user session")
    }

    let sessionMode = opts.wireOut != nil || opts.wireListen != nil
    let destination = sessionMode
        ? "lyte-udp session ("
            + (opts.wireOut.map { "\($0.host):\($0.port)" }
                ?? "listen :\(opts.wireListen!)")
            + (opts.insecure ? ", INSECURE" : ", noise") + ")"
        : opts.outputPath
    print("lyte-host — \(opts.backend.rawValue) → PipeWire → "
        + "hevc_nvenc → \(destination)")

    // HS-33: which libavcodec did this binary link? The vendored
    // no-reset build (Scripts/vendor-ffmpeg.sh) signs itself with a
    // configuration marker; lyte_hevc_noreset_enable reads it and
    // defaults the env gate ON (explicit LYTE_NVENC_NO_RESET_RATE=0
    // forces the upstream reset+IDR path — the live A/B control
    // through the same binary). Everything downstream that branches on
    // this (the ladder retune, the idr-books tags) keys off THIS
    // proof, never off an assumption about the build.
    let noResetRateMoves = lyte_hevc_noreset_enable() != 0
    print(noResetRateMoves
        ? "encoder: vendored no-reset libavcodec — rate directives "
            + "reconfigure in place (zero reset, zero IDR)"
        : "encoder: no-reset rate moves INACTIVE (distro libavcodec, "
            + "or the vendored lib with LYTE_NVENC_NO_RESET_RATE=0) — "
            + "every rate directive resets the encoder and mints an IDR")

    if mutterDirectScanoutDisabled() == false {
        print("capture: WARNING — gnome-shell lacks MUTTER_DEBUG_PAINT="
            + "disable-direct-scanout; fullscreen video will freeze the "
            + "stream (direct scanout starves the ScreenCast). Run "
            + "Scripts/setup-host.sh and log in again.")
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
        var declared = opts.audio
            ? Capabilities.wireDefault.declaringHostAudioRouting()
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

        // V-4: chroma is declared on PROOF, never a hardcoded claim —
        // the Best tier (4:4:4) joins the declaration only when the
        // startup Rext self-probe just opened on this box. A failed
        // probe truthfully declares [420] alone: a Best-declaring
        // client then hits `noCommonChromaMode` and its auto-re-dial
        // banner, the pillar's NAMED degradation.
        if let probeError = probeRext444Encode() {
            print("chroma: Rext 4:4:4 self-probe FAILED (\(probeError)) "
                + "— declaring chroma [420] only; Best tier not offered")
        } else {
            declared.chromaModes = [
                CapabilityChroma.yuv420, CapabilityChroma.yuv444,
            ]
            print("chroma: Rext 4:4:4 self-probe passed — declaring "
                + "chroma [420, 444]")
        }

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
                        staticPublicKey: hostStatic.publicKey
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

        // HS-20: the encoder finally consumes frameByteCeiling. The
        // baseline mirrors the opening posture lyte_hevc_enc_new will
        // configure (CBR: avg = max = --bitrate-mbps, single-frame VBV;
        // capped-CQ: only the max-rate cap) — the policy caps against
        // it and never pushes above it. Sink polls per encode.
        // HS-25: the baseline VBV is now the unprotectable-frame
        // guard's ceiling wherever the recipe's own VBV was absent or
        // larger (the Sink imposes the same cap at encoder open) — so
        // a squeeze→clean RESTORE returns to the guarded posture and
        // can never re-open the >255-shard hole.
        if opts.vbvReconfigure {
            let guardBits = w.worstCaseProtectableFrameCeiling * 8
            // HS-33 retune: with the vendored no-reset lib a directive
            // stops costing an IDR, so the ladder NARROWS to half-rungs
            // (posture/pacer slack 2× → ≤√2: a tighten lands the
            // posture closer above the fallen rate, shrinking the
            // oversized-frame transient the §5 fall-repricing finding
            // measured). The loosening sustain stays at HS-27's 10 s
            // DELIBERATELY: an eager (2 s) sustain was measured live
            // to chase every climb — the posture re-postures at/above
            // the still-climbing pacer, frames overstay their budget,
            // and queuing-delay overuse fires a floor limit cycle with
            // ZERO loss (the 2026-07-29 armed A/B: 10 falls to
            // 500 kbps vs the control's clean ride). The sustain costs
            // no IDRs under no-reset — it is pure climb-lag, and the
            // books keep it honest. Distro lib keeps the HS-27 posture
            // verbatim — the knobs follow the PROVEN capability above.
            w.armEncoderVbv(EncoderVbvConfig(
                fps: Int(opts.fps),
                baselineAverageBitsPerSecond:
                    opts.ratchet ? nil : Int(opts.bitrate),
                baselineMaxBitsPerSecond: Int(opts.bitrate),
                baselineVbvBits: opts.ratchet
                    ? guardBits
                    : min(Int(opts.bitrate) / Int(opts.fps), guardBits),
                rungsPerOctave: noResetRateMoves ? 2 : 1,
                // The second free harvest: tightens land exactly on
                // the ceiling rate (no √2 slack above the fallen
                // rate) — only under the proven no-reset lib, same
                // gate as the half-rung ladder.
                exactTighten: noResetRateMoves
            ))
        } else {
            print("encoder-vbv: DISABLED (--no-vbv-reconfigure) — the "
                + "opening recipe rides the whole run")
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

    // Both backends must stay alive for the whole capture: dropping them
    // closes their D-Bus connection, which closes the portal/Mutter session
    // and destroys the PipeWire node mid-stream.
    let stream: ScreenCastStream
    var portal: PortalScreenCast?
    var mutter: MutterScreenCast?
    switch opts.backend {
    case .portal:
        let p = try PortalScreenCast()
        portal = p
        stream = try p.openDesktopStream()
        print("portal: ScreenCast granted — PipeWire node \(stream.nodeId), fd \(stream.pipewireFd)")
    case .mutter:
        let m = try MutterScreenCast()
        mutter = m
        stream = try m.openMonitorStream(connector: opts.connector)
        print("mutter: ScreenCast started — PipeWire node \(stream.nodeId) on default remote")
    }
    defer {
        mutter?.stop()
        _ = portal // retained until capture completes
    }

    var file: UnsafeMutablePointer<FILE>?
    if !sessionMode {
        guard let f = fopen(opts.outputPath, "wb") else {
            throw HostError("cannot open \(opts.outputPath) for writing")
        }
        file = f
    }

    let sink = Sink(opts: opts, file: file, wire: wire,
                    noResetRateMoves: noResetRateMoves)
    var err = [CChar](repeating: 0, count: 256)
    let user = Unmanaged.passUnretained(sink).toOpaque()
    guard let capture = lyte_pw_capture_new(stream.pipewireFd, stream.nodeId,
                                            frameTrampoline, user,
                                            &err, err.count) else {
        if let file { fclose(file) }
        throw HostError("pipewire capture setup failed: \(errString(err))")
    }
    sink.capture = capture

    // Steady-rate supply: a repeating tick on the capture loop thread at the
    // fps interval; the Sink re-encodes the last frame when no fresh one
    // arrived, so output flows at ~fps regardless of desktop activity.
    if opts.idleFloor {
        let interval = UInt64(1_000_000_000) / UInt64(opts.fps)
        guard lyte_pw_capture_set_tick(capture, interval, tickTrampoline, user) == 0 else {
            if let file { fclose(file) }
            throw HostError("failed to arm the idle-floor tick timer")
        }
    }

    // Grace beyond the capture window covers stream negotiation and a
    // sparse damage-driven frame supply.
    let rc = lyte_pw_capture_run(capture, opts.seconds + 15.0, &err, err.count)

    try sink.flushEncoder()
    if let file { fclose(file) }
    sink.freeEncoder()
    mutter?.stop()

    // HS-15: quit the audio loop BEFORE the teardown so the last audio
    // shards ride out ahead of the 0x0A, not into a closed session.
    audioWire?.stop()

    // HS-11: the orderly exit — a typed SessionTeardown on the reliable
    // stream (retransmitted until acknowledged or patience runs out), so
    // the client learns the session ended instead of inferring it.
    sink.wire?.shutdown(reason: .shuttingDown)
    // HS-13: close the Mutter RemoteDesktop session (uinput devices die
    // with the process either way).
    sink.wire?.inputInjector?.stop()
    // HS-19: close the clipboard leaf's RemoteDesktop session (its
    // selection ownership and pending transfers die with it; the
    // connection-owned session can never be stranded by a crash).
    clipboardLeaf?.stop()
    // F-3: the receiving end's one resume obligation — persist the
    // mid-flight BulkResumeState beside its staging file so the next
    // session's re-offer resumes from the gap, sha-exact.
    bulkShell?.teardown()

    // Measurement aid: dump the final retained raw frame (stride-packed
    // BGRx as delivered by PipeWire) so decoded output can be PSNR'd
    // against ground truth. Env-gated; not a product surface.
    if let rawPath = ProcessInfo.processInfo.environment["LYTE_DUMP_RAW"],
       !sink.lastFrame.isEmpty {
        FileManager.default.createFile(atPath: rawPath,
                                       contents: Data(sink.lastFrame))
        print("raw reference dumped: \(rawPath) "
            + "(\(sink.lastFrame.count) bytes, stride \(sink.lastStride))")
    }

    if let failure = sink.lastError {
        throw HostError(failure)
    }
    if rc == -1 {
        throw HostError("capture failed: \(errString(err))")
    }
    if sink.framesIn == 0 {
        throw HostError("no frames arrived from PipeWire within \(Int(opts.seconds + 15))s. "
            + "The portal granted the stream, so likely causes: the consent dialog "
            + "on the host's physical screen is still pending, or the compositor is not "
            + "producing frames. Nothing was written.")
    }

    let captured = sink.firstFrameAt.map { monotonicNow() - $0 } ?? 0
    let n = sink.negotiated!
    print("""

    done: \(sink.framesIn) frames encoded (\(sink.damageFrames) damage, \
    \(sink.repeatedFrames) repeated, \(sink.ratchetFrames) ratchet), \
    \(sink.packetsOut) packets out \
    (\(sink.keyframes) IDR), \(sink.bytesOut) bytes over \(String(format: "%.1f", captured))s
    resolution \(n.width)x\(n.height), input format \(n.format)
    """)
    if opts.ratchet {
        print("ratchet total: \(sink.ratchetFrames) passes, "
            + "\(sink.ratchetBytes) bytes"
            + (sink.ratchetConverged ? ", converged" : ", NOT converged"))
    }
    if rc == 1 {
        print("note: capture ended at the safety timeout — the desktop was mostly "
            + "static, so frames arrived only on damage")
    }

    let firstNals = AnnexB.nalUnits(in: sink.firstPacket)
    print("first packet NALs: \(AnnexB.summary(of: sink.firstPacket))")
    guard AnnexB.startsWithParameterSetsAndIrap(sink.firstPacket) else {
        throw HostError("the first encoded packet does not begin with "
            + "VPS/SPS/PPS + an IRAP picture (got: "
            + "\(firstNals.map { HevcNal.name($0.type) }.joined(separator: " ")))"
            + " — the bitstream is not stream-startable")
    }
    print("first packet starts with parameter sets + IDR: OK")
    if let wire = sink.wire {
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
        \(sink.throttledFrames) capture frames throttled (backlog gate), \
        \(sink.starvationEpisodes) capture-starvation episodes, \
        final state \(wire.lifecycleState.map { "\($0)" } ?? "—") \
        (wire mode \(wire.currentWireMode.map { "\($0)" } ?? "—"))
        chroma: agreed \(wire.agreedChromaModes.map { "\($0)" } ?? "— (no declaration)"), \
        encoder \(sink.activeChroma == .yuv444
            ? "4:4:4 (\(sink.activeRecipe.summary), floor cq\(sink.activeRecipe.ratchetFloorQP))"
            : "4:2:0 (\(sink.activeRecipe.summary))"), \
        \(sink.framesHeldForChroma) frames held pre-agreement
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
        dwell max \(wire.audioMailboxMaxDwellNS) ns, \
        overflows \(wire.audioMailboxOverflows)
        audio-routing: final \(wire.currentAudioRouting), \
        \(s.audioRoutingRequestsReceived) flip requests, \
        \(s.audioRoutingStatusesSent) statuses sent
        clipboard: leaf \(clipboardLeaf != nil ? "ACTIVE" : "none"), \
        \(s.clipboardSetsReceived) sets received, \
        \(s.clipboardAnnouncesSent) announces sent, \
        \(s.clipboardAnnouncesSuppressed) suppressed\(clipboardLeafStats)
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
        (\(wire.estimatorStats.stretchedTrainsRecused) hole-recused), \
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
        \(wire.frameByteCeiling(fps: Int(opts.fps))) B
        encoder-vbv: \(wire.vbvDirectivesIssued) directives, \
        \(sink.encoderReconfigures) applied, \
        \(wire.vbvRateMovesAbsorbed) rate moves absorbed \
        (pacer-only, no encoder reset); applied cost — \
        \(sink.reconfigureBooks.idrMintingTotal) IDR-minting \
        (\(EncoderReconfigureBooks.summary(sink.reconfigureBooks.idrMinting))), \
        \(sink.reconfigureBooks.noResetTotal) no-reset \
        (\(EncoderReconfigureBooks.summary(sink.reconfigureBooks.noReset)))\(vbvFinal)
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
        // The estimator-ramp hunt's cause-tagged IDR books, tallied:
        // which cause dominates, and the beauty-bar rate itself.
        let idrPerMinute = captured > 0
            ? Double(sink.keyframes) * 60.0 / captured : 0
        let idrBook = sink.idrCauseTally.isEmpty ? "none"
            : sink.idrCauseTally
                .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
        print("idr-books: \(sink.keyframes) IDRs = "
            + String(format: "%.2f", idrPerMinute)
            + "/min over \(String(format: "%.0f", captured)) s — "
            + idrBook)
        if let audio = audioWire {
            print("audio: \(audio.packetsEncoded) packets encoded "
                + "(\(audio.encodeFailures) encode failures)"
                + (audio.negotiated.map {
                    ", negotiated F32 \($0.rate) Hz \($0.channels)ch"
                } ?? ", no buffers arrived")
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

    // The capture leaf is not freed here: PipeWire loop/context teardown can
    // block on the compositor after the stream is done, and the spike's
    // deliverable (the file) is already complete and flushed. Exit directly.
    // The advertiser is retained to this line on purpose: the record stays
    // published for the whole session and exiting withdraws it.
    withExtendedLifetime(advertiser) {}
    lyte_stdout_flush()
    exit(0)
}

// Subcommands, each of which never returns: `rd-spike` is the CP-5
// RemoteDesktop headless-injection probe (RemoteDesktopSpike.swift);
// `sniff` is the HS-5 Lyte-UDP header dissector (Sniff.swift);
// `advertise` is the HS-10 standalone Avahi advertisement
// (AvahiAdvertise.swift). Everything else is the capture path.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "rd-spike" {
    rdSpikeMain(Array(CommandLine.arguments.dropFirst(2)))
}
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
