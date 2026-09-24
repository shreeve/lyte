// EyeCapture: milestone 2's conductor — a stable 60 Hz beat observes the
// whole scanout through a compact GPU fingerprint. Changed pixels are blitted
// into an exported VAAPI surface, the native VAAPI pens emit Annex-B, and the
// bytes hit the file. An idle desktop is observed but not encoded; motion is
// encoded at panel cadence. Framebuffer identity only invalidates the cached
// dmabuf import. The native VAAPI encoder is the only encoder (--native is
// accepted as a no-op).

#if os(Linux)

import LyteIO
import Foundation
import Glibc
import HostCore
import HostEye

func runCapture(_ rawArgs: [String]) -> Never {
    var device = "/dev/dri/card1"
    var render = "/dev/dri/renderD128"
    var seconds = 10.0
    var output = "/tmp/lyte-eye.hevc"
    var qp: Int32 = 24
    var bitrateMbps: Int64 = 0
    var chroma444 = false
    var it = rawArgs.makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--device": device = it.next() ?? device
        case "--render": render = it.next() ?? render
        case "--seconds": seconds = Double(it.next() ?? "") ?? seconds
        case "--out": output = it.next() ?? output
        case "--qp": qp = Int32(it.next() ?? "") ?? qp
        case "--native": break  // the only seat now; kept for scripts
        // Live-rate probe: VBR at this cap, then HALVED at the
        // midpoint via setRateControl — the gate is 1 IDR.
        case "--bitrate-mbps":
            bitrateMbps = Int64(it.next() ?? "") ?? bitrateMbps
        // The Rext probe: 444 encodes Main 4:4:4 on AYUV surfaces.
        case "--chroma":
            let value = it.next() ?? "420"
            guard value == "420" || value == "444" else {
                FileHandle.standardError.write(
                    Data("--chroma takes 420 or 444\n".utf8))
                exit(2)
            }
            chroma444 = value == "444"
        default:
            FileHandle.standardError.write(
                Data("unknown arg \(arg)\n".utf8))
            exit(2)
        }
    }
    runNativeCapture(
        device: device, render: render, seconds: seconds,
        output: output, qp: qp,
        bitrateBitsPerSecond: bitrateMbps * 1_000_000,
        chroma444: chroma444)
}

// MARK: - E6b: the native leg — same eye, libva spoken directly

/// The capture witness: the production EyePipeline (GETFB2 import,
/// fingerprint, blit, native VAAPI encode) on the 60 Hz screen beat,
/// writing every changed frame to an Annex-B file. The file
/// decode-probes on the Mac.
func runNativeCapture(
    device: String, render: String, seconds: Double,
    output: String, qp: Int32, bitrateBitsPerSecond: Int64 = 0,
    chroma444: Bool = false
) -> Never {
    let screen: DirectScreenSource
    do {
        screen = try DirectScreenSource(device: device)
    } catch DirectScreenSourceError.openDevice(_, let code) {
        errno = code
        perror(device)
        exit(1)
    } catch DirectScreenSourceError.noActivePrimaryPlane(_) {
        FileHandle.standardError.write(
            Data("no active primary plane on \(device)\n".utf8))
        exit(1)
    } catch DirectScreenSourceError.initialTicketDenied(_) {
        FileHandle.standardError.write(Data(
            "GETFB2 failed — capture mode needs privileges\n".utf8))
        exit(1)
    } catch {
        FileHandle.standardError.write(Data(
            "screen source: \(error)\n".utf8))
        exit(1)
    }
    let width = screen.width
    let height = screen.height
    print("""
        capture: \(device) \(width)x\(height) → \(output) \
        (qp \(qp), \(Int(seconds))s) [NATIVE — no libavcodec]\
        \(chroma444 ? " [Rext 4:4:4]" : "")
        """)

    let pipeline: EyePipeline
    do {
        pipeline = try EyePipeline(
            width: width, height: height, renderNode: render, qp: qp,
            bitrateBitsPerSecond: bitrateBitsPerSecond,
            chroma444: chroma444)
    } catch {
        FileHandle.standardError.write(Data("init: \(error)\n".utf8))
        exit(1)
    }

    _ = FileManager.default.createFile(atPath: output, contents: nil)
    guard let file = FileHandle(forWritingAtPath: output) else {
        FileHandle.standardError.write(
            Data("cannot open \(output)\n".utf8))
        exit(1)
    }

    var samplingCadence = ScreenSamplingCadence()
    var observations: UInt64 = 0
    var framebufferTransitions: UInt64 = 0
    var changedObservations: UInt64 = 0
    var skippedObservationBeats: UInt64 = 0
    var frames = 0
    var bytes = 0
    var keyframes = 0
    var missedGrabs = 0
    var fingerprintMs = 0.0
    var blitMs = 0.0
    var encodeMs = 0.0
    let t0 = SystemMonotonicClock.nowSeconds
    var nextReport = t0 + 1.0
    var framesThisSecond = 0

    // The live-rate probe: halve the envelope at the midpoint, no
    // reset, no IDR — the gate that retires the vendor patch's job
    // on the VAAPI side too.
    var rateMoved = false

    while true {
        let t = SystemMonotonicClock.nowSeconds
        guard t - t0 < seconds else { break }
        if bitrateBitsPerSecond > 0, !rateMoved,
           t - t0 > seconds / 2 {
            rateMoved = true
            pipeline.setRateControl(bitsPerSecond: bitrateBitsPerSecond / 2)
            print("""
                  live-rate: \(bitrateBitsPerSecond / 1_000_000) → \
                \(bitrateBitsPerSecond / 2_000_000) Mbps at midpoint \
                (no reset, no IDR expected)
                """)
        }
        let observationClock = SystemMonotonicClock.nowMicroseconds
        guard case .sample(let skippedBeats) = samplingCadence.poll(
            nowMicroseconds: observationClock)
        else {
            usleep(1000)
            if t >= nextReport {
                print("""
                      t=\(String(format: "%2.0f", t - t0))s \
                    frames_this_sec=\(framesThisSecond) total=\(frames)
                    """)
                framesThisSecond = 0
                nextReport += 1.0
            }
            continue
        }
        observations += 1
        skippedObservationBeats += skippedBeats
        guard let observation = screen.observe() else {
            continue
        }
        if observation.identityChanged { framebufferTransitions += 1 }

        do {
            switch try pipeline.refreshScanout(observation, from: screen) {
            case .current, .imported:
                break
            case .missedGrab:
                missedGrabs += 1
                continue
            case .geometryChanged:
                FileHandle.standardError.write(Data(
                    "display geometry changed during capture\n".utf8))
                exit(1)
            }
        } catch {
            FileHandle.standardError.write(
                Data("scanout import: \(error)\n".utf8))
            exit(1)
        }
        do {
            let tFingerprint = SystemMonotonicClock.nowSeconds
            let changed = try pipeline.scanoutChanged()
            fingerprintMs +=
                (SystemMonotonicClock.nowSeconds - tFingerprint) * 1e3
            guard changed else { continue }
            changedObservations += 1
            let (count, keyframe) = try pipeline.encodeFresh(
                forceIDR: false) { bytes, keyframe in
                file.write(Data(bytes))
                return (bytes.count, keyframe)
            }
            blitMs += Double(pipeline.lastBlitMicroseconds) / 1e3
            encodeMs += Double(pipeline.lastEncodeMicroseconds) / 1e3
            bytes += count
            if keyframe { keyframes += 1 }
            frames += 1
            framesThisSecond += 1
        } catch {
            FileHandle.standardError.write(
                Data("frame \(frames): \(error)\n".utf8))
            exit(1)
        }

        if t >= nextReport {
            print("""
                  t=\(String(format: "%2.0f", t - t0))s \
                frames_this_sec=\(framesThisSecond) total=\(frames)
                """)
            framesThisSecond = 0
            nextReport += 1.0
        }
    }
    try? file.close()

    let duration = SystemMonotonicClock.nowSeconds - t0
    print(String(
        format: """
            RESULT capture: %d frames in %.1fs = %.2f fps, \
            %d bytes (%.1f KB/frame), %d IDRs, missed_grabs=%d \
            [NATIVE]
            """,
        frames, duration, Double(frames) / duration, bytes,
        frames > 0 ? Double(bytes) / Double(frames) / 1024 : 0,
        keyframes, missedGrabs))
    print("""
        RESULT observation: beats=\(observations), \
        framebuffer_transitions=\(framebufferTransitions), \
        pixel_changes=\(changedObservations), \
        skipped_beats=\(skippedObservationBeats)
        """)
    if observations > 0 {
        print(String(
            format: "RESULT fingerprint: %.2f ms/observation",
            fingerprintMs / Double(observations)))
    }
    if frames > 0 {
        print(String(
            format: "RESULT timing: blit %.2f ms/frame, encode %.2f ms/frame",
            blitMs / Double(frames), encodeMs / Double(frames)))
    }
    exit(0)
}

#endif
