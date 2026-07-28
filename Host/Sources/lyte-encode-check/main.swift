// lyte-encode-check (HS-24): the encoder A/B ladder harness — the
// supremacy plan's R4 measurement seam. Feeds a deterministic raw
// BGRx sequence (ffmpeg rawvideo bytes, no capture, no wire, no
// clock) through the exact CHevcEncode leaf a session uses, with the
// recipe knobs on the command line, and reports the numbers the
// blessed adoption bar names: bytes at the matched rate (PSNR comes
// from decoding --out against the same raw input — the script's
// half), per-frame encode wall time (the input→photon contribution a
// recipe change could tax), QP posture, and encode-capacity fps.
//
// Two modes:
//   sequence (default): encode --frames frames from --raw, looping
//     the file if it is shorter. CBR at --bitrate-mbps unless --cq
//     puts it in capped-CQ. Frame 0 is the only forced IDR.
//   --static N: encode the FIRST frame N times — the ratchet
//     mechanism in miniature (capped-CQ walks QP down across repeats;
//     byte-stability is the convergence detector). Verifies a recipe
//     candidate doesn't break the ratchet's convergence contract.
//
// Output ends with one machine-readable "RESULT …" key=value line the
// ladder script parses.

import CHevcEncode
import Foundation
import HostCore

struct CheckError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { self.description = d }
}

struct CheckOptions {
    var rawPath = ""
    var width = 0
    var height = 0
    var fps: Int32 = 60
    var frames = 0 // 0 = as many as the raw file holds
    var staticRepeats = 0 // >0: static mode
    var outPath = "/tmp/lyte-encode-check.hevc"
    var bitrate: Int64 = 20_000_000
    var cq: Int32 = 0
    var recipe = EncoderRecipe.sessionDefault

    static func parse(_ args: [String]) throws -> CheckOptions {
        var o = CheckOptions()
        var i = 1
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else {
                throw CheckError("\(flag) needs a value")
            }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--raw": o.rawPath = try value("--raw")
            case "--width":
                guard let v = Int(try value("--width")), v > 0 else {
                    throw CheckError("--width needs a positive integer")
                }
                o.width = v
            case "--height":
                guard let v = Int(try value("--height")), v > 0 else {
                    throw CheckError("--height needs a positive integer")
                }
                o.height = v
            case "--fps":
                guard let v = Int32(try value("--fps")), v > 0 else {
                    throw CheckError("--fps needs a positive integer")
                }
                o.fps = v
            case "--frames":
                guard let v = Int(try value("--frames")), v > 0 else {
                    throw CheckError("--frames needs a positive integer")
                }
                o.frames = v
            case "--static":
                guard let v = Int(try value("--static")), v > 0 else {
                    throw CheckError("--static needs a positive integer")
                }
                o.staticRepeats = v
            case "--out": o.outPath = try value("--out")
            case "--bitrate-mbps":
                guard let v = Double(try value("--bitrate-mbps")), v > 0
                else {
                    throw CheckError("--bitrate-mbps needs a positive number")
                }
                o.bitrate = Int64(v * 1_000_000)
            case "--cq":
                guard let v = Int32(try value("--cq")), v >= 0 else {
                    throw CheckError("--cq needs a non-negative integer")
                }
                o.cq = v
            case "--preset": o.recipe.preset = try value("--preset")
            case "--tune": o.recipe.tune = try value("--tune")
            case "--multipass": o.recipe.multipass = try value("--multipass")
            case "--spatial-aq": o.recipe.spatialAQ = true
            case "--temporal-aq": o.recipe.temporalAQ = true
            case "--aq-strength":
                guard let v = Int(try value("--aq-strength")) else {
                    throw CheckError("--aq-strength needs 1…15")
                }
                o.recipe.aqStrength = v
            case "--help", "-h":
                print("""
                usage: lyte-encode-check --raw FILE --width W --height H
                       [--fps N] [--frames N | --static N] [--out FILE]
                       [--bitrate-mbps N] [--cq N]
                       [--preset p1…p7] [--tune ull|ll]
                       [--multipass disabled|qres|fullres]
                       [--spatial-aq] [--temporal-aq] [--aq-strength 1…15]
                Encodes packed-BGRx rawvideo (ffmpeg -pix_fmt bgr0 -f
                rawvideo) through CHevcEncode with the given recipe and
                prints the A/B numbers; Annex-B lands at --out for the
                PSNR half. --cq 0 (default) is CBR at --bitrate-mbps;
                --cq N is capped-CQ. --static N re-encodes the first
                frame N times (the ratchet-convergence check).
                """)
                exit(0)
            default:
                throw CheckError("unknown argument \(args[i]) (try --help)")
            }
            i += 1
        }
        guard !o.rawPath.isEmpty, o.width > 0, o.height > 0 else {
            throw CheckError("--raw, --width, and --height are required")
        }
        do {
            _ = try o.recipe.validated()
        } catch let knob as EncoderRecipe.KnobError {
            throw CheckError("bad recipe knob: \(knob)")
        }
        return o
    }
}

/// Packet accumulator: bytes to the out file, per-frame QP/size books.
final class Collector {
    let file: UnsafeMutablePointer<FILE>
    var bytesOut = 0
    var keyframes = 0
    var frameBytes: [Int] = []
    var frameQPs: [Int] = []

    init(file: UnsafeMutablePointer<FILE>) { self.file = file }

    func onPacket(data: UnsafePointer<UInt8>, size: Int, keyframe: Bool,
                  avgQP: Int) {
        fwrite(data, 1, size, file)
        bytesOut += size
        if keyframe { keyframes += 1 }
        frameBytes.append(size)
        frameQPs.append(avgQP)
    }
}

private func packetTrampoline(user: UnsafeMutableRawPointer?,
                              data: UnsafePointer<UInt8>?, size: Int,
                              keyframe: Int32, avgQP: Int32) {
    guard let user, let data else { return }
    let c = Unmanaged<Collector>.fromOpaque(user).takeUnretainedValue()
    c.onPacket(data: data, size: size, keyframe: keyframe != 0,
               avgQP: Int(avgQP))
}

func nowMicros() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000 + UInt64(ts.tv_nsec) / 1_000
}

func errString(_ buf: [CChar]) -> String {
    let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

/// Nearest-rank percentile of a sorted array.
func percentile(_ sorted: [UInt64], _ p: Double) -> UInt64 {
    guard !sorted.isEmpty else { return 0 }
    let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
    return sorted[max(0, min(sorted.count - 1, rank))]
}

func percentileInt(_ sorted: [Int], _ p: Double) -> Int {
    guard !sorted.isEmpty else { return 0 }
    let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
    return sorted[max(0, min(sorted.count - 1, rank))]
}

func run() throws {
    lyte_stdout_linebuf()
    let opts = try CheckOptions.parse(CommandLine.arguments)

    guard let raw = fopen(opts.rawPath, "rb") else {
        throw CheckError("cannot open \(opts.rawPath)")
    }
    defer { fclose(raw) }
    fseek(raw, 0, SEEK_END)
    let rawSize = ftell(raw)
    fseek(raw, 0, SEEK_SET)

    let frameSize = opts.width * opts.height * 4
    let rowStride = Int32(opts.width * 4)
    let framesInFile = rawSize / frameSize
    guard framesInFile > 0 else {
        throw CheckError("\(opts.rawPath) holds no complete "
            + "\(opts.width)x\(opts.height) BGRx frame "
            + "(\(rawSize) bytes < \(frameSize))")
    }

    let total = opts.staticRepeats > 0
        ? opts.staticRepeats
        : (opts.frames > 0 ? opts.frames : framesInFile)

    guard let out = fopen(opts.outPath, "wb") else {
        throw CheckError("cannot open \(opts.outPath) for writing")
    }
    defer { fclose(out) }

    var err = [CChar](repeating: 0, count: 256)
    let r = opts.recipe
    guard let enc = lyte_hevc_enc_new(
        Int32(opts.width), Int32(opts.height), "bgr0",
        opts.fps, opts.bitrate, opts.cq,
        r.preset, r.tune, r.multipass,
        r.spatialAQ ? 1 : 0, r.temporalAQ ? 1 : 0, Int32(r.aqStrength),
        &err, err.count) else {
        // The reject IS a ladder verdict — surface it in parseable form.
        print("RESULT recipe=\(r.summary) verdict=open-rejected "
            + "error=\"\(errString(err))\"")
        throw CheckError("encoder init failed: \(errString(err))")
    }
    defer { lyte_hevc_enc_free(enc) }

    let mode = opts.cq > 0 ? "capped-cq\(opts.cq)" : "cbr"
    print("encode-check: \(opts.width)x\(opts.height) bgr0 @\(opts.fps), "
        + "\(total) frames (\(framesInFile) in file"
        + (opts.staticRepeats > 0 ? ", static-repeat mode" : "")
        + "), recipe \(r.summary), \(mode) "
        + "\(opts.bitrate / 1_000_000) Mbps")

    let collector = Collector(file: out)
    let user = Unmanaged.passUnretained(collector).toOpaque()
    var frame = [UInt8](repeating: 0, count: frameSize)
    var encodeMicros: [UInt64] = []
    encodeMicros.reserveCapacity(total)

    for i in 0..<total {
        if opts.staticRepeats > 0 {
            if i == 0 {
                guard fread(&frame, 1, frameSize, raw) == frameSize else {
                    throw CheckError("short read on frame 0")
                }
            }
        } else {
            if i % framesInFile == 0 && i > 0 { fseek(raw, 0, SEEK_SET) }
            guard fread(&frame, 1, frameSize, raw) == frameSize else {
                throw CheckError("short read on frame \(i)")
            }
        }
        let t0 = nowMicros()
        let rc = frame.withUnsafeBufferPointer { buf in
            lyte_hevc_enc_send(enc, buf.baseAddress!, rowStride, Int64(i),
                               i == 0 ? 1 : 0,
                               packetTrampoline, user, &err, err.count)
        }
        if rc != 0 {
            throw CheckError("encode failed at frame \(i): \(errString(err))")
        }
        encodeMicros.append(nowMicros() - t0)
    }
    if lyte_hevc_enc_flush(enc, packetTrampoline, user, &err, err.count) != 0 {
        throw CheckError("flush failed: \(errString(err))")
    }
    lyte_stdout_flush()

    let sortedUs = encodeMicros.sorted()
    let meanUs = encodeMicros.reduce(0, +) / UInt64(max(1, encodeMicros.count))
    let qps = collector.frameQPs.filter { $0 >= 0 }.sorted()
    let kbps = Double(collector.bytesOut) * 8.0 * Double(opts.fps)
        / Double(total) / 1000.0

    if opts.staticRepeats > 0 {
        // The convergence story: QP walk + byte stability, sampled.
        let n = collector.frameBytes.count
        let step = max(1, n / 12)
        var walk: [String] = []
        for i in stride(from: 0, to: n, by: step) {
            walk.append("[\(i)] qp\(collector.frameQPs[i]) "
                + "\(collector.frameBytes[i])B")
        }
        if let lastQP = collector.frameQPs.last,
           let lastBytes = collector.frameBytes.last {
            walk.append("[last] qp\(lastQP) \(lastBytes)B")
        }
        print("static walk: " + walk.joined(separator: " → "))
    }

    print(String(
        format: "encode: mean %.2f ms, p50 %.2f / p95 %.2f / p99 %.2f / "
            + "max %.2f ms — capacity %.0f fps",
        Double(meanUs) / 1000, Double(percentile(sortedUs, 0.50)) / 1000,
        Double(percentile(sortedUs, 0.95)) / 1000,
        Double(percentile(sortedUs, 0.99)) / 1000,
        Double(sortedUs.last ?? 0) / 1000,
        meanUs > 0 ? 1_000_000 / Double(meanUs) : 0))

    print("RESULT recipe=\(r.summary) mode=\(mode) "
        + "rate_mbps=\(opts.bitrate / 1_000_000) frames=\(total) "
        + "bytes=\(collector.bytesOut) "
        + "kbps=\(Int(kbps)) idr=\(collector.keyframes) "
        + "qp_p50=\(percentileInt(qps, 0.50)) "
        + "qp_p95=\(percentileInt(qps, 0.95)) "
        + "qp_last=\(collector.frameQPs.last ?? -1) "
        + "bytes_last=\(collector.frameBytes.last ?? 0) "
        + "enc_us_mean=\(meanUs) "
        + "enc_us_p50=\(percentile(sortedUs, 0.50)) "
        + "enc_us_p95=\(percentile(sortedUs, 0.95)) "
        + "enc_us_p99=\(percentile(sortedUs, 0.99)) "
        + "enc_us_max=\(sortedUs.last ?? 0) "
        + "enc_fps_capacity=\(meanUs > 0 ? 1_000_000 / Int(meanUs) : 0)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
