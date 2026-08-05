// EyeCapture: milestone 2's conductor — a stable 60 Hz beat observes the
// whole scanout through a compact GPU fingerprint. Changed pixels are blitted
// into an exported VAAPI surface, the native VAAPI pens emit Annex-B, and the
// bytes hit the file. An idle desktop is observed but not encoded; motion is
// encoded at panel cadence. Framebuffer identity only invalidates the cached
// dmabuf import. The libav seat was demolished after first-light; native is
// the only encoder (--native is accepted as a no-op).

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
        // midpoint via setRateBitsPerSecond — the gate is 1 IDR.
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

/// The capture loop with EyeVaapiEncoder in the encoder seat: zero
/// libavcodec. Everything else — screen beat, GETFB2, EGL import, the
/// NV12 blit into exported surfaces — is E1's machinery verbatim.
/// Gates: the file decode-probes on the Mac; the books print the
/// same shape as the libav leg for A/B reading.
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
    print("capture: \(device) \(width)x\(height) → \(output) "
        + "(qp \(qp), \(Int(seconds))s) [NATIVE — no libavcodec]"
        + (chroma444 ? " [Rext 4:4:4]" : ""))

    let gl: EyeGL
    let encoder: EyeVaapiEncoder
    do {
        gl = try EyeGL(renderNode: render)
        encoder = try EyeVaapiEncoder(
            width: width, height: height, fps: 60, qp: qp,
            renderNode: render,
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

    var targets: [UInt32: NV12Target] = [:]
    var targets444: [UInt32: AyuvTarget] = [:]
    var scanoutSource: ImportedTexture?
    var scanoutIdentity: UInt32?
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
            encoder.setRateBitsPerSecond(bitrateBitsPerSecond / 2)
            print("  live-rate: \(bitrateBitsPerSecond / 1_000_000) → "
                + "\(bitrateBitsPerSecond / 2_000_000) Mbps at midpoint "
                + "(no reset, no IDR expected)")
        }
        let observationClock = SystemMonotonicClock.nowMicroseconds
        guard case .sample(let skippedBeats) = samplingCadence.poll(
            nowMicroseconds: observationClock)
        else {
            usleep(1000)
            if t >= nextReport {
                print("  t=\(String(format: "%2.0f", t - t0))s "
                    + "frames_this_sec=\(framesThisSecond) total=\(frames)")
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

        if scanoutSource == nil
            || scanoutIdentity != observation.framebufferIdentity {
            guard let ticket = screen.capture(observation) else {
                missedGrabs += 1
                continue
            }
            guard Int32(ticket.width) == width,
                  Int32(ticket.height) == height else {
                FileHandle.standardError.write(Data(
                    "display geometry changed during capture\n".utf8))
                ticket.release()
                exit(1)
            }
            do {
                let imported = try gl.importTexture(
                    width: Int32(ticket.width),
                    height: Int32(ticket.height),
                    fourcc: ticket.fourcc,
                    modifier: ticket.modifier,
                    planes: ticket.planes)
                ticket.release()
                if var old = scanoutSource { gl.destroy(&old) }
                scanoutSource = imported
                scanoutIdentity = observation.framebufferIdentity
                gl.resetFingerprint()
            } catch {
                ticket.release()
                FileHandle.standardError.write(
                    Data("scanout import: \(error)\n".utf8))
                exit(1)
            }
        }
        guard let source = scanoutSource else { continue }
        do {
            let tFingerprint = SystemMonotonicClock.nowSeconds
            let changed = try gl.scanoutChanged(
                source: source, width: width, height: height)
            fingerprintMs +=
                (SystemMonotonicClock.nowSeconds - tFingerprint) * 1e3
            guard changed else { continue }
            changedObservations += 1
            let tBlit = SystemMonotonicClock.nowSeconds
            let surface = encoder.inputSurfaces[
                frames % encoder.inputSurfaces.count]
            if chroma444 {
                if targets444[surface] == nil {
                    let plane = try encoder.exportSurfacePacked(surface)
                    let target = try gl.makeAyuvTarget(
                        width: width, height: height,
                        modifier: plane.modifier,
                        plane: (plane.fd, plane.offset, plane.pitch))
                    close(plane.fd)
                    targets444[surface] = target
                }
                gl.blit444(
                    source: source,
                    srcWidth: width,
                    srcHeight: height,
                    into: targets444[surface]!)
            } else {
                if targets[surface] == nil {
                    let exported = try encoder.exportSurface(surface)
                    let target = try gl.makeNV12Target(
                        width: width, height: height,
                        yFourcc: exported.y.fourcc,
                        yModifier: exported.y.modifier,
                        yPlane: (exported.y.fd, exported.y.offset,
                                 exported.y.pitch),
                        uvFourcc: exported.uv.fourcc,
                        uvModifier: exported.uv.modifier,
                        uvPlane: (exported.uv.fd, exported.uv.offset,
                                  exported.uv.pitch))
                    close(exported.y.fd)
                    if exported.uv.fd != exported.y.fd {
                        close(exported.uv.fd)
                    }
                    targets[surface] = target
                }
                gl.blit(
                    source: source,
                    srcWidth: width,
                    srcHeight: height,
                    into: targets[surface]!)
            }
            blitMs += (SystemMonotonicClock.nowSeconds - tBlit) * 1e3

            let tEnc = SystemMonotonicClock.nowSeconds
            let (data, keyframe) = try encoder.encode(
                surface: surface, forceIDR: false)
            encodeMs += (SystemMonotonicClock.nowSeconds - tEnc) * 1e3
            file.write(Data(data))
            bytes += data.count
            if keyframe { keyframes += 1 }
            frames += 1
            framesThisSecond += 1
        } catch {
            FileHandle.standardError.write(
                Data("frame \(frames): \(error)\n".utf8))
            exit(1)
        }

        if t >= nextReport {
            print("  t=\(String(format: "%2.0f", t - t0))s "
                + "frames_this_sec=\(framesThisSecond) total=\(frames)")
            framesThisSecond = 0
            nextReport += 1.0
        }
    }
    try? file.close()
    if var source = scanoutSource { gl.destroy(&source) }

    let duration = SystemMonotonicClock.nowSeconds - t0
    print(String(
        format: "RESULT capture: %d frames in %.1fs = %.2f fps, "
            + "%d bytes (%.1f KB/frame), %d IDRs, missed_grabs=%d "
            + "[NATIVE]",
        frames, duration, Double(frames) / duration, bytes,
        frames > 0 ? Double(bytes) / Double(frames) / 1024 : 0,
        keyframes, missedGrabs))
    print("RESULT observation: beats=\(observations), "
        + "framebuffer_transitions=\(framebufferTransitions), "
        + "pixel_changes=\(changedObservations), "
        + "skipped_beats=\(skippedObservationBeats)")
    if observations > 0 {
        print(String(
            format: "RESULT fingerprint: %.2f ms/observation",
            fingerprintMs / Double(observations)))
    }
    if frames > 0 {
        print(String(
            format: "RESULT timing: blit %.2f ms/frame, "
                + "encode %.2f ms/frame",
            blitMs / Double(frames), encodeMs / Double(frames)))
    }
    exit(0)
}

#endif
