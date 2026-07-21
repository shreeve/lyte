// lyte-host capture spike (H0a slice 1): portal ScreenCast → PipeWire frames
// → NVENC HEVC (libavcodec leaf) → Annex-B file. HS-5 adds the wire mode:
// `--wire-out HOST:PORT` streams the same encode output through
// HostWire.VideoChannel (packetize + FEC + pacer) → CNetIO instead of the
// file, with the PipeWire graph-clock capture stamp in every envelope.

import CHevcEncode
import CPipeWireCapture
import Foundation
import HostCore

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
    /// HS-5: stream shards to this peer instead of writing the file.
    var wireOut: (host: String, port: UInt16)?
    /// Pacer rate for the wire mode. No negotiation exists yet (HS-16),
    /// so the configured ceiling is the honest default, per Pacer's rule.
    var wireRateMbps = 20.0

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
                  --wire-out H:P    HS-5 wire mode: stream Lyte-UDP video
                                    shards (packetizer + FEC + pacer, per-
                                    packet TOS 0xA0) to HOST:PORT instead
                                    of writing the file
                  --wire-rate-mbps  pacer rate in the wire mode (default 20)

                subcommands: lyte-host sniff --port PORT  (header dissector)
                             lyte-host rd-spike …         (CP-5 input probe)
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
    /// (H0a spike) or the Lyte-UDP wire leg (HS-5 `--wire-out`).
    var file: UnsafeMutablePointer<FILE>?
    var wireOut: WireOut?

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

    init(opts: Options, file: UnsafeMutablePointer<FILE>?, wireOut: WireOut?) {
        self.opts = opts
        self.file = file
        self.wireOut = wireOut
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

        guard encode(data: data, stride: stride) else { return }
        damageFrames += 1
        encodedSinceTick = true

        quitIfElapsed(now)
    }

    /// Idle-floor tick, on the PipeWire loop thread at the fps interval:
    /// when no fresh frame was encoded since the previous tick, re-encode
    /// the retained copy so output flows at a steady rate. In ratchet mode
    /// the same tick instead drives quality-refinement passes.
    func onTick() {
        if lastError != nil { return }

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
        }
    }

    /// Encodes one frame; pts advances monotonically per encoded frame and
    /// only frame 0 is a forced IDR (repeats are normal P-frames).
    private func encode(data: UnsafePointer<UInt8>, stride: Int32) -> Bool {
        var err = [CChar](repeating: 0, count: 256)
        let user = Unmanaged.passUnretained(self).toOpaque()
        let rc = lyte_hevc_enc_send(encoder, data, stride, Int64(framesIn),
                                    framesIn == 0 ? 1 : 0,
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
        if let wireOut {
            do {
                try wireOut.sendFrame(data: data, size: size,
                                      isKeyframe: keyframe,
                                      captureMicros: pendingCaptureUs)
            } catch {
                fail("wire-out failed at packet \(packetsOut): \(error)")
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

    let destination = opts.wireOut.map { "lyte-udp://\($0.host):\($0.port)" }
        ?? opts.outputPath
    print("lyte-host — \(opts.backend.rawValue) → PipeWire → "
        + "hevc_nvenc → \(destination)")

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
    var wireOut: WireOut?
    if let peer = opts.wireOut {
        wireOut = try WireOut(
            host: peer.host, port: peer.port,
            rateBitsPerSecond: Int(opts.wireRateMbps * 1_000_000)
        )
        print("wire-out: shards to \(peer.host):\(peer.port), pacer "
            + "\(opts.wireRateMbps) Mbps, TOS 0xA0 per video datagram")
    } else {
        guard let f = fopen(opts.outputPath, "wb") else {
            throw HostError("cannot open \(opts.outputPath) for writing")
        }
        file = f
    }

    let sink = Sink(opts: opts, file: file, wireOut: wireOut)
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
            + "on pop's physical screen is still pending, or the compositor is not "
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
    if let wireOut = sink.wireOut {
        let t = wireOut.pacerTelemetry
        let c = wireOut.counters
        print("""
        wire-out: \(c.framesIngested) frames → \(c.shardsEnqueued) shards → \
        \(wireOut.datagramsSent) datagrams (\(wireOut.bytesSent) B) in \
        \(t.batches) paced batches; max batch wire time \
        \(t.maxBatchWireTimeNS) ns (quantum 1000000); freshVideo max queue \
        delay \(t[.freshVideo].maxQueueDelayNS) ns
        """)
    } else {
        print("output: \(opts.outputPath)")
    }

    // The capture leaf is not freed here: PipeWire loop/context teardown can
    // block on the compositor after the stream is done, and the spike's
    // deliverable (the file) is already complete and flushed. Exit directly.
    lyte_stdout_flush()
    exit(0)
}

// Subcommands, each of which never returns: `rd-spike` is the CP-5
// RemoteDesktop headless-injection probe (RemoteDesktopSpike.swift);
// `sniff` is the HS-5 Lyte-UDP header dissector (Sniff.swift).
// Everything else is the capture path.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "rd-spike" {
    rdSpikeMain(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "sniff" {
    sniffMain(Array(CommandLine.arguments.dropFirst(2)))
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("lyte-host: error: \(error)\n".utf8))
    exit(1)
}
