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
    /// [500 kbps, this] on feedback evidence.
    var wireRateMbps = 20.0
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
                  --wire-rate-mbps  pacer rate in the wire mode (default 20)
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

    // Idle-floor state. The PipeWire buffer is only valid inside the frame
    // callback, so the most recent frame is retained by copy; on a tick with
    // no fresh frame since the previous tick, that copy is re-encoded as an
    // ordinary P-frame. Ticks and frame callbacks share the PipeWire loop
    // thread, so no locking is needed.
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
        static let floorQP = 12       // visually-lossless target (spec §3)
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
    // HS-11: the most recent encoded packet's bytes, retained only in
    // ratchet+session mode — on convergence this IS the final converged
    // frame, re-sent on a reliable one-shot before the idle flip.
    var lastEncodedPacket: [UInt8] = []

    init(opts: Options, file: UnsafeMutablePointer<FILE>?, wire: SessionWire?) {
        self.opts = opts
        self.file = file
        self.wire = wire
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

        if encoder == nil {
            guard let name = Sink.pixFmtName(fmt) else {
                fail("PipeWire negotiated an unsupported pixel format "
                    + "(spa value \(fmt.rawValue)); this slice supports "
                    + "BGRx/BGRA/RGBx/RGBA")
                return
            }
            var err = [CChar](repeating: 0, count: 256)
            let cq: Int32 = opts.ratchet ? Int32(Ratchet.floorQP) : 0
            guard let enc = lyte_hevc_enc_new(Int32(width), Int32(height), name,
                                              opts.fps, opts.bitrate, cq,
                                              &err, err.count) else {
                fail("encoder init failed: \(errString(err))")
                return
            }
            encoder = enc
            negotiated = (width, height, name)
            wire?.noteMonitorExtent(width: width, height: height)
            let rcDesc = opts.ratchet
                ? "capped-CQ vbr cq=\(Ratchet.floorQP), cap \(opts.bitrate / 1_000_000) Mbps"
                : "cbr \(opts.bitrate / 1_000_000) Mbps"
            print("capture: \(width)x\(height) \(name), stride \(stride) — "
                + "encoding hevc_nvenc (\(rcDesc))")
        }

        let now = monotonicNow()
        if firstFrameAt == nil { firstFrameAt = now }

        if opts.idleFloor || opts.ratchet {
            let count = Int(size)
            if lastFrame.count != count {
                lastFrame = [UInt8](repeating: 0, count: count)
            }
            lastFrame.withUnsafeMutableBytes { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: data, count: count))
            }
            lastStride = stride
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

        // The session is over (peer gone, teardown, liveness): stop the
        // capture loop cleanly — the HS-11 graceful exit.
        if wire?.sessionEnded == true, let capture {
            lyte_pw_capture_quit(capture)
            return
        }

        let now = monotonicNow()
        quitIfElapsed(now)

        if encodedSinceTick {
            encodedSinceTick = false
            return
        }
        guard !lastFrame.isEmpty else { return } // nothing to repeat yet

        if opts.ratchet {
            ratchetTick(now)
            return
        }

        pendingCaptureUs = lastFrameGraphUs
        let ok = lastFrame.withUnsafeBufferPointer { buf in
            encode(data: buf.baseAddress!, stride: lastStride)
        }
        if ok { repeatedFrames += 1 }
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
        let ok = lastFrame.withUnsafeBufferPointer { buf in
            encode(data: buf.baseAddress!, stride: lastStride)
        }
        guard ok else { return }

        ratchetStep += 1
        ratchetFrames += 1
        ratchetBytes += lastPacketBytes
        ratchetEpisodeBytes += lastPacketBytes
        let sinceTrigger = (now - ratchetTriggeredAt!) * 1000
        print(String(format: "ratchet: step %2d  qp=%2d  bytes=%7d  t+%.0f ms",
                     ratchetStep, lastPacketQP, lastPacketBytes, sinceTrigger))

        if lastPacketBytes <= Ratchet.skipBytes {
            ratchetConverged = true
        } else if lastPacketQP <= Ratchet.floorQP, ratchetPrevBytes > 0,
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
    private func encode(data: UnsafePointer<UInt8>, stride: Int32) -> Bool {
        var err = [CChar](repeating: 0, count: 256)
        let user = Unmanaged.passUnretained(self).toOpaque()
        let forceIdr = framesIn == 0 || (wire?.takeForcedIdr() ?? false)
        let rc = lyte_hevc_enc_send(encoder, data, stride, Int64(framesIn),
                                    forceIdr ? 1 : 0,
                                    packetTrampoline, user, &err, err.count)
        if rc != 0 {
            fail("encode failed at frame \(framesIn): \(errString(err))")
            return false
        }
        framesIn += 1
        return true
    }

    private func quitIfElapsed(_ now: Double) {
        if let start = firstFrameAt, now - start >= opts.seconds, let capture {
            lyte_pw_capture_quit(capture)
        }
    }

    func onPacket(data: UnsafePointer<UInt8>, size: Int, keyframe: Bool, avgQP: Int) {
        if firstPacket.isEmpty {
            firstPacket = Array(UnsafeBufferPointer(start: data, count: size))
        }
        if let wire {
            do {
                try wire.sendFrame(data: data, size: size,
                                   isKeyframe: keyframe,
                                   captureMicros: pendingCaptureUs)
            } catch {
                fail("session send failed at packet \(packetsOut): \(error)")
                return
            }
        } else if let file {
            fwrite(data, 1, size, file)
        }
        packetsOut += 1
        bytesOut += size
        if keyframe { keyframes += 1 }
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

    let opts = try Options.parse(CommandLine.arguments)

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

    // The session comes up BEFORE capture: in Noise mode the host blocks
    // here for the client's handshake (printing the static public key the
    // client must hold), so no frames are encoded for nobody and the
    // first encoded frame is the session's first IDR.
    var wire: SessionWire?
    var advertiser: AvahiAdvertiser?
    var pairingService: PairingResponderService?
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

        // The W7 declaration: key 9 (hostAudioRouting, the HS-18
        // virtual-sink mute) rides the forward-compat spine whenever
        // the audio leg exists — the client's control strip gates its
        // mute button on the intersection, so a --no-audio host
        // truthfully never declares it.
        let declared = opts.audio
            ? Capabilities.wireDefault.declaringHostAudioRouting()
            : .wireDefault

        let w = try SessionWire(
            listenPort: opts.wireListen,
            peer: opts.wireOut,
            insecure: opts.insecure,
            rateBitsPerSecond: Int(opts.wireRateMbps * 1_000_000),
            capabilities: declared,
            allowedClientStatics: allowed,
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
            + "TOS (video 0xA0 / control 0xC0), 1 Hz beacon on CTRL")

        // HS-13: the injection backend comes up with the session — the
        // Mutter RemoteDesktop session is independent of the portal
        // capture (CP-5 Q6: the video token is never touched).
        if let injector = makeInputInjector(opts.input) {
            w.inputInjector = injector
            print("input: injection via \(injector.name) "
                + "(echo tuples + lastInputSeq stamping active)")
        }
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

    let sink = Sink(opts: opts, file: file, wire: wire)
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
        lifecycle: \(s.modeTransitionsSent) mode transitions, \
        \(s.videoFramesSuppressed) frames suppressed (FROZEN/closed), \
        final state \(wire.lifecycleState.map { "\($0)" } ?? "—") \
        (wire mode \(wire.currentWireMode.map { "\($0)" } ?? "—"))
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
        max audio queue delay \(t[.audio].maxQueueDelayNS) ns
        audio-routing: final \(wire.currentAudioRouting), \
        \(s.audioRoutingRequestsReceived) flip requests, \
        \(s.audioRoutingStatusesSent) statuses sent
        estimator: rate \(wire.estimatedRate / 1_000) kbps \
        (pacer \(wire.pacerRate / 1_000) kbps, ceiling \
        \(Int(opts.wireRateMbps * 1_000)) kbps), delivery \
        \(wire.deliveryRate.map { "\($0 / 1_000) kbps" } ?? "—"), \
        queuing delay \(wire.queuingDelayMicros.map { "\($0) µs" } ?? "—"); \
        \(wire.estimatorStats.reportsIngested) reports \
        (\(s.feedbackReportsParsed) parsed, \
        \(s.feedbackReportsMalformed) malformed), \
        \(wire.estimatorStats.deliverySamples) delivery samples \
        (\(wire.estimatorStats.dispersionSamplesMatched) matched / \
        \(wire.estimatorStats.dispersionSamplesUnmatched) unmatched), \
        \(wire.estimatorStats.downshifts) downshifts \
        (\(wire.estimatorStats.lossDownshifts) loss, \
        \(wire.estimatorStats.overuseVerdicts) overuse verdicts), \
        \(wire.estimatorStats.upshifts) upshifts, \
        \(s.rateChanges) pacer moves; frameByteCeiling@\(opts.fps)fps \
        \(wire.frameByteCeiling(fps: Int(opts.fps))) B
        repair: \(s.nackEntriesReceived) NACK entries \
        (\(s.nacksHonored) honored → \(s.repairDatagramsEnqueued) repair \
        datagrams, \(s.nacksJudgedStale) stale, \
        \(s.idrArmedOnStaleNack) IDR-armed), \
        \(wire.estimatorStats.nackShardsCounted) post-FEC shards counted, \
        \(wire.estimatorStats.postFecDownshifts) rung-3 downshifts, \
        \(s.fecRegimeSteps) regime steps (final \(wire.fecRegime.rawValue)); \
        srtt \(wire.srttMicros.map { "\($0) µs" } ?? "—"), \
        store \(wire.repairStoreBytes) B
        """)
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
