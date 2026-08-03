// HS-14 verification harness: desktop-monitor audio → 5 ms Opus packets,
// with a decode-back path so verification is trivial. Captures the default
// sink's monitor via CPipeWireAudio, slices to exact 240-sample frames,
// encodes with COpusEncode (CELT restricted-lowdelay, DTX off), and writes
//   /tmp/lyte-audio-check.pkts — length-prefixed packets:
//                                 [u32le size][u64le graph-ts µs][bytes]
//   /tmp/lyte-audio-check.wav  — the packets decoded straight back to
//                                 PCM s16, so ffprobe/ffmpeg judge the loop.
// Prints cadence/size/timestamp stats and exits nonzero if the HS-14 gate
// is violated: ~200 pkt/s, strictly monotonic graph-clock timestamps,
// every packet loop-decodes. No wire, no envelope — that is HS-15.
//
// usage: lyte-audio-check [seconds] [bitrate] [--vbr]
// (--vbr is evidence mode: silence-vs-signal packet sizes prove the
//  pipeline carries real audio; the dialect itself is hard CBR.)

import LyteIO
import COpusEncode
import CPipeWireAudio
import Foundation

struct CheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Decodes a NUL-terminated C error buffer.
func errString(_ buf: [CChar]) -> String {
    let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

let packetFrames = Int(LYTE_OPUS_FRAME)   // 240 samples/ch = 5 ms
let channels = Int(LYTE_OPUS_CHANNELS)
let sampleRate = Int(LYTE_OPUS_RATE)
let packetUS = UInt64(packetFrames * 1_000_000 / sampleRate) // 5000

// MARK: - Sink (all state lives on the capture loop thread)

final class Sink {
    let encoder: OpaquePointer
    let decoder: OpaquePointer

    // Pending PCM not yet sliced into a full 5 ms frame, and the graph-clock
    // marks needed to timestamp a packet by the buffer its first sample
    // arrived in: (global frame index of buffer start, graph µs of it).
    var pending: [Float] = []
    var pendingStartFrame = 0
    var marks: [(startFrame: Int, us: UInt64)] = []
    var framesSeen = 0

    // Evidence.
    var packetSizes: [Int] = []
    var packetTS: [UInt64] = []
    var packetData = Data()
    var decodedPCM: [Float] = []
    var negotiated: (rate: UInt32, channels: UInt32)?
    var negotiationError: String?
    var callbackError: String?
    var firstBufferWall: Double = 0
    var lastBufferWall: Double = 0

    var capture: OpaquePointer?

    init(encoder: OpaquePointer, decoder: OpaquePointer) {
        self.encoder = encoder
        self.decoder = decoder
        pending.reserveCapacity(8192)
    }

    func onAudio(samples: UnsafePointer<Float>, nFrames: UInt32,
                 chans: UInt32, rate: UInt32, graphUS: UInt64) {
        if negotiated == nil {
            negotiated = (rate, chans)
            firstBufferWall = SystemMonotonicClock.nowSeconds
            if rate != UInt32(sampleRate) || chans != UInt32(channels) {
                negotiationError =
                    "negotiated \(rate) Hz \(chans)ch, need \(sampleRate)/\(channels)"
                if let capture { lyte_pw_audio_quit(capture) }
                return
            }
        }
        guard negotiationError == nil else { return }
        lastBufferWall = SystemMonotonicClock.nowSeconds

        marks.append((startFrame: framesSeen, us: graphUS))
        framesSeen += Int(nFrames)
        pending.append(contentsOf: UnsafeBufferPointer(
            start: samples, count: Int(nFrames) * channels))

        while pending.count >= packetFrames * channels {
            emitPacket()
            if callbackError != nil {
                if let capture { lyte_pw_audio_quit(capture) }
                return
            }
        }
    }

    private func emitPacket() {
        // Timestamp: the mark of the buffer containing this packet's first
        // sample, advanced by the sample offset within it — pure graph clock.
        let startFrame = pendingStartFrame
        var ts: UInt64 = 0
        while marks.count > 1, marks[1].startFrame <= startFrame {
            marks.removeFirst()
        }
        if let m = marks.first {
            ts = m.us + UInt64(startFrame - m.startFrame)
                * 1_000_000 / UInt64(sampleRate)
        }

        var err = [CChar](repeating: 0, count: 256)
        var packet = [UInt8](repeating: 0, count: Int(LYTE_OPUS_MAX_PACKET))
        let n = pending.withUnsafeBufferPointer { pcm in
            lyte_opus_enc_encode(encoder, pcm.baseAddress, &packet,
                                 Int32(packet.count), &err, err.count)
        }
        guard n > 0 else {
            callbackError = "encode failed at packet \(packetSizes.count): "
                + errString(err)
            return
        }

        var decoded = [Float](repeating: 0, count: packetFrames * channels)
        let frames = lyte_opus_dec_decode(decoder, packet, n, &decoded,
                                          Int32(packetFrames), &err, err.count)
        guard frames == Int32(packetFrames) else {
            callbackError = "loop decode failed at packet \(packetSizes.count) "
                + "(\(frames) frames): " + errString(err)
            return
        }

        packetSizes.append(Int(n))
        packetTS.append(ts)
        var size32 = UInt32(n).littleEndian
        var ts64 = ts.littleEndian
        withUnsafeBytes(of: &size32) { packetData.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts64) { packetData.append(contentsOf: $0) }
        packetData.append(contentsOf: packet.prefix(Int(n)))
        decodedPCM.append(contentsOf: decoded)

        pending.removeFirst(packetFrames * channels)
        pendingStartFrame += packetFrames
    }
}

private func audioTrampoline(user: UnsafeMutableRawPointer?,
                             samples: UnsafePointer<Float>?, nFrames: UInt32,
                             chans: UInt32, rate: UInt32, graphUS: UInt64) {
    guard let user, let samples else { return }
    let sink = Unmanaged<Sink>.fromOpaque(user).takeUnretainedValue()
    sink.onAudio(samples: samples, nFrames: nFrames, chans: chans,
                 rate: rate, graphUS: graphUS)
}

// MARK: - WAV writer (PCM s16le, the decode-back evidence file)

func writeWAV(_ pcm: [Float], to path: String) throws {
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let byteCount = pcm.count * 2
    data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + byteCount))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(16)
    u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
    u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(UInt32(byteCount))
    var samples = [Int16](repeating: 0, count: pcm.count)
    for (i, f) in pcm.enumerated() {
        samples[i] = Int16(max(-32768, min(32767, (f * 32767).rounded())))
    }
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: URL(fileURLWithPath: path))
}

// MARK: - Main

func run() throws {
    var seconds = 10.0
    var bitrate: Int32 = 128_000
    var useVBR = false
    var positional: [String] = []
    for arg in CommandLine.arguments.dropFirst() {
        if arg == "--vbr" { useVBR = true } else { positional.append(arg) }
    }
    if positional.count > 0 {
        guard let s = Double(positional[0]), s > 0 else {
            throw CheckError("usage: lyte-audio-check [seconds] [bitrate] [--vbr]")
        }
        seconds = s
    }
    if positional.count > 1 {
        guard let b = Int32(positional[1]), b > 0 else {
            throw CheckError("bad bitrate \(positional[1])")
        }
        bitrate = b
    }

    let pktsPath = "/tmp/lyte-audio-check.pkts"
    let wavPath = "/tmp/lyte-audio-check.wav"

    var err = [CChar](repeating: 0, count: 256)
    guard let encoder = lyte_opus_enc_new(bitrate, useVBR ? 1 : 0,
                                          &err, err.count) else {
        throw CheckError("opus encoder: \(errString(err))")
    }
    defer { lyte_opus_enc_free(encoder) }
    guard let decoder = lyte_opus_dec_new(&err, err.count) else {
        throw CheckError("opus decoder: \(errString(err))")
    }
    defer { lyte_opus_dec_free(decoder) }

    let sink = Sink(encoder: encoder, decoder: decoder)
    let user = Unmanaged.passUnretained(sink).toOpaque()
    guard let capture = lyte_pw_audio_new(audioTrampoline, user, 0,
                                          &err, err.count) else {
        throw CheckError("pipewire audio setup failed: \(errString(err))")
    }
    defer { lyte_pw_audio_free(capture) }
    sink.capture = capture

    print("audio-check: capturing default-sink monitor for "
        + String(format: "%.1f", seconds) + " s, opus \(bitrate) b/s "
        + (useVBR ? "VBR (evidence mode)" : "hard CBR") + ", 5 ms frames")

    let rc = lyte_pw_audio_run(capture, seconds, &err, err.count)
    guard rc >= 0 else {
        throw CheckError("capture failed: \(errString(err))")
    }
    if let ne = sink.negotiationError { throw CheckError(ne) }
    if let ce = sink.callbackError { throw CheckError(ce) }
    guard let fmt = sink.negotiated else {
        throw CheckError("no audio buffers arrived in \(seconds) s "
            + "(is a default sink present?)")
    }

    try sink.packetData.write(to: URL(fileURLWithPath: pktsPath))
    try writeWAV(sink.decodedPCM, to: wavPath)

    // Stats + gate.
    let count = sink.packetSizes.count
    guard count > 1 else { throw CheckError("only \(count) packets captured") }
    let sizes = sink.packetSizes
    let ts = sink.packetTS
    let graphSpanS = Double(ts.last! - ts.first!) / 1e6
        + Double(packetUS) / 1e6
    let wallSpanS = sink.lastBufferWall - sink.firstBufferWall
    let pktPerSec = Double(count) / graphSpanS

    var deltas: [Int64] = []
    var nonMonotonic = 0
    for i in 1..<count {
        let d = Int64(bitPattern: ts[i] &- ts[i - 1])
        deltas.append(d)
        if d <= 0 { nonMonotonic += 1 }
    }
    let offCadence = deltas.filter { abs($0 - Int64(packetUS)) > 1000 }.count
    let avgSize = Double(sizes.reduce(0, +)) / Double(count)
    let avgDelta = Double(deltas.reduce(0, +)) / Double(deltas.count)

    print("negotiated: F32 interleaved \(fmt.rate) Hz \(fmt.channels)ch")
    print("packets: \(count) over \(String(format: "%.3f", graphSpanS)) s "
        + "graph-clock span (\(String(format: "%.3f", wallSpanS)) s wall) = "
        + String(format: "%.1f", pktPerSec) + " pkt/s")
    print("sizes: min \(sizes.min()!) avg "
        + String(format: "%.1f", avgSize) + " max \(sizes.max()!) bytes")
    print("ts deltas (µs): min \(deltas.min()!) avg "
        + String(format: "%.1f", avgDelta) + " max \(deltas.max()!), "
        + "\(nonMonotonic) non-monotonic, \(offCadence) outside 5000±1000")
    print("wrote \(pktsPath) (\(sink.packetData.count) B) and "
        + "\(wavPath) (\(sink.decodedPCM.count / channels) frames = "
        + String(format: "%.3f",
                 Double(sink.decodedPCM.count / channels) / Double(sampleRate))
        + " s decoded-back)")

    var failures: [String] = []
    if nonMonotonic > 0 { failures.append("\(nonMonotonic) non-monotonic timestamps") }
    if pktPerSec < 190 || pktPerSec > 210 {
        failures.append("cadence \(String(format: "%.1f", pktPerSec)) pkt/s outside 200±10")
    }
    if offCadence > deltas.count / 100 {
        failures.append("\(offCadence) deltas off 5 ms cadence (>1%)")
    }
    guard failures.isEmpty else {
        throw CheckError("gate failed: " + failures.joined(separator: "; "))
    }
    print("audio-check: OK — 5 ms Opus cadence, monotonic graph-clock ts, "
        + "clean loop decode")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("lyte-audio-check: error: \(error)\n".utf8))
    exit(1)
}
