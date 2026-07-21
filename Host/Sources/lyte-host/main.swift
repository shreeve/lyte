// lyte-host capture spike (H0a slice 1): portal ScreenCast → PipeWire frames
// → NVENC HEVC (libavcodec leaf) → Annex-B file. Proves capture + encode in
// isolation; no RTP, no protocol.

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
            case "--help", "-h":
                print("""
                usage: lyte-host [--out PATH] [--seconds N] [--bitrate-mbps N]
                                 [--backend portal|mutter] [--connector NAME]
                Captures the desktop and writes Annex-B HEVC (hevc_nvenc) to
                PATH (default /tmp/lyte-h0a.hevc).
                  --backend portal  xdg-desktop-portal ScreenCast (primary;
                                    one-time on-screen consent on first run)
                  --backend mutter  org.gnome.Mutter.ScreenCast (no dialog;
                                    spike fallback for headless/ssh runs)
                  --connector NAME  monitor connector for the mutter backend
                                    (e.g. DP-1); empty records the primary
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
    var file: UnsafeMutablePointer<FILE>

    var framesIn = 0
    var packetsOut = 0
    var bytesOut = 0
    var keyframes = 0
    var firstFrameAt: Double?
    var lastError: String?
    var firstPacket: [UInt8] = []
    var negotiated: (width: UInt32, height: UInt32, format: String)?

    init(opts: Options, file: UnsafeMutablePointer<FILE>) {
        self.opts = opts
        self.file = file
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
                 width: UInt32, height: UInt32, fmt: lyte_pixfmt) {
        if lastError != nil { return }

        if encoder == nil {
            guard let name = Sink.pixFmtName(fmt) else {
                fail("PipeWire negotiated an unsupported pixel format "
                    + "(spa value \(fmt.rawValue)); this slice supports "
                    + "BGRx/BGRA/RGBx/RGBA")
                return
            }
            var err = [CChar](repeating: 0, count: 256)
            guard let enc = lyte_hevc_enc_new(Int32(width), Int32(height), name,
                                              opts.fps, opts.bitrate,
                                              &err, err.count) else {
                fail("encoder init failed: \(errString(err))")
                return
            }
            encoder = enc
            negotiated = (width, height, name)
            print("capture: \(width)x\(height) \(name), stride \(stride) — "
                + "encoding hevc_nvenc @ \(opts.bitrate / 1_000_000) Mbps")
        }

        let now = monotonicNow()
        if firstFrameAt == nil { firstFrameAt = now }

        var err = [CChar](repeating: 0, count: 256)
        let user = Unmanaged.passUnretained(self).toOpaque()
        let rc = lyte_hevc_enc_send(encoder, data, stride, Int64(framesIn),
                                    framesIn == 0 ? 1 : 0,
                                    packetTrampoline, user, &err, err.count)
        if rc != 0 {
            fail("encode failed at frame \(framesIn): \(errString(err))")
            return
        }
        framesIn += 1

        if let start = firstFrameAt, now - start >= opts.seconds, let capture {
            lyte_pw_capture_quit(capture)
        }
    }

    func onPacket(data: UnsafePointer<UInt8>, size: Int, keyframe: Bool) {
        if firstPacket.isEmpty {
            firstPacket = Array(UnsafeBufferPointer(start: data, count: size))
        }
        fwrite(data, 1, size, file)
        packetsOut += 1
        bytesOut += size
        if keyframe { keyframes += 1 }
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
                             fmt: lyte_pixfmt) {
    guard let user, let data else { return }
    let sink = Unmanaged<Sink>.fromOpaque(user).takeUnretainedValue()
    sink.onFrame(data: data, size: size, stride: stride,
                 width: width, height: height, fmt: fmt)
}

private func packetTrampoline(user: UnsafeMutableRawPointer?,
                              data: UnsafePointer<UInt8>?, size: Int,
                              keyframe: Int32) {
    guard let user, let data else { return }
    let sink = Unmanaged<Sink>.fromOpaque(user).takeUnretainedValue()
    sink.onPacket(data: data, size: size, keyframe: keyframe != 0)
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

    print("lyte-host H0a capture spike — \(opts.backend.rawValue) → PipeWire → "
        + "hevc_nvenc → \(opts.outputPath)")

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

    guard let file = fopen(opts.outputPath, "wb") else {
        throw HostError("cannot open \(opts.outputPath) for writing")
    }

    let sink = Sink(opts: opts, file: file)
    var err = [CChar](repeating: 0, count: 256)
    let user = Unmanaged.passUnretained(sink).toOpaque()
    guard let capture = lyte_pw_capture_new(stream.pipewireFd, stream.nodeId,
                                            frameTrampoline, user,
                                            &err, err.count) else {
        fclose(file)
        throw HostError("pipewire capture setup failed: \(errString(err))")
    }
    sink.capture = capture

    // Grace beyond the capture window covers stream negotiation and a
    // sparse damage-driven frame supply.
    let rc = lyte_pw_capture_run(capture, opts.seconds + 15.0, &err, err.count)

    try sink.flushEncoder()
    fclose(file)
    sink.freeEncoder()
    mutter?.stop()

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

    done: \(sink.framesIn) frames in, \(sink.packetsOut) packets out \
    (\(sink.keyframes) IDR), \(sink.bytesOut) bytes over \(String(format: "%.1f", captured))s
    resolution \(n.width)x\(n.height), input format \(n.format)
    """)
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
    print("output: \(opts.outputPath)")

    // The capture leaf is not freed here: PipeWire loop/context teardown can
    // block on the compositor after the stream is done, and the spike's
    // deliverable (the file) is already complete and flushed. Exit directly.
    lyte_stdout_flush()
    exit(0)
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("lyte-host: error: \(error)\n".utf8))
    exit(1)
}
