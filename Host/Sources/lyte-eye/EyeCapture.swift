// EyeCapture: milestone 2's conductor — the doorbell paces the loop,
// each flip becomes a scanout ticket, the 3D engine blits it into an
// exported VAAPI surface, the native VAAPI pens emit Annex-B, bytes
// hit the file. Cadence is a consequence of content: an idle desktop
// encodes ~1 fps, motion encodes at panel rate, a blank screen
// encodes zero. The libav seat was demolished after first-light;
// native is the only encoder (--native is accepted as a no-op).

#if os(Linux)

import LyteIO
import Foundation
import Glibc
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
/// libavcodec. Everything else — doorbell, GETFB2, EGL import, the
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
    var frames = 0
    var bytes = 0
    var keyframes = 0
    var missedGrabs = 0
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
        guard let change = screen.poll() else {
            usleep(1000)
            if t >= nextReport {
                print("  t=\(String(format: "%2.0f", t - t0))s "
                    + "frames_this_sec=\(framesThisSecond) total=\(frames)")
                framesThisSecond = 0
                nextReport += 1.0
            }
            continue
        }
        guard let ticket = screen.capture(change) else {
            missedGrabs += 1
            continue
        }

        var ticketReleased = false
        do {
            let tBlit = SystemMonotonicClock.nowSeconds
            var source = try gl.importTexture(
                width: Int32(ticket.width),
                height: Int32(ticket.height),
                fourcc: ticket.fourcc, modifier: ticket.modifier,
                planes: ticket.planes)
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
                    srcWidth: Int32(ticket.width),
                    srcHeight: Int32(ticket.height),
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
                    srcWidth: Int32(ticket.width),
                    srcHeight: Int32(ticket.height),
                    into: targets[surface]!)
            }
            gl.destroy(&source)
            ticket.release()
            ticketReleased = true
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
            if !ticketReleased { ticket.release() }
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

    let duration = SystemMonotonicClock.nowSeconds - t0
    print(String(
        format: "RESULT capture: %d frames in %.1fs = %.2f fps, "
            + "%d bytes (%.1f KB/frame), %d IDRs, missed_grabs=%d "
            + "[NATIVE]",
        frames, duration, Double(frames) / duration, bytes,
        frames > 0 ? Double(bytes) / Double(frames) / 1024 : 0,
        keyframes, missedGrabs))
    if frames > 0 {
        print(String(
            format: "RESULT timing: blit %.2f ms/frame, "
                + "encode %.2f ms/frame",
            blitMs / Double(frames), encodeMs / Double(frames)))
    }
    exit(0)
}

#endif
