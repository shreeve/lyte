// EyeCapture: milestone 2's conductor — the doorbell paces the loop,
// each flip becomes a scanout ticket, the 3D engine blits it into an
// exported VAAPI surface, hevc_vaapi emits Annex-B, bytes hit the
// file. Cadence is a consequence of content: an idle desktop encodes
// ~1 fps, motion encodes at panel rate, a blank screen encodes zero.

#if os(Linux)

import CDRM
import Foundation
import Glibc
import HostEye

/// Per-surface cached GL state: the exported planes only need EGL
/// import once per pooled surface, not once per frame.
private struct TargetCacheEntry {
    var target: NV12Target
}

func runCapture(_ rawArgs: [String]) -> Never {
    var device = "/dev/dri/card1"
    var render = "/dev/dri/renderD128"
    var seconds = 10.0
    var output = "/tmp/lyte-eye.hevc"
    var qp: Int32 = 24
    var native = false
    var it = rawArgs.makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--device": device = it.next() ?? device
        case "--render": render = it.next() ?? render
        case "--seconds": seconds = Double(it.next() ?? "") ?? seconds
        case "--out": output = it.next() ?? output
        case "--qp": qp = Int32(it.next() ?? "") ?? qp
        case "--native": native = true
        default:
            FileHandle.standardError.write(
                Data("unknown arg \(arg)\n".utf8))
            exit(2)
        }
    }
    if native {
        runNativeCapture(
            device: device, render: render, seconds: seconds,
            output: output, qp: qp)
    }

    let fd = open(device, O_RDWR)
    guard fd >= 0 else { perror(device); exit(1) }
    drmSetClientCap(fd, UInt64(DRM_CLIENT_CAP_UNIVERSAL_PLANES), 1)
    guard let planes = findActivePlanes(fd: fd) else {
        FileHandle.standardError.write(
            Data("no active primary plane on \(device)\n".utf8))
        exit(1)
    }

    // Geometry from the current scanout; also the first frame.
    guard let probe = grabTicket(fd: fd, fbId: planes.primary.fb) else {
        FileHandle.standardError.write(Data(
            "GETFB2 failed — capture mode needs privileges (sudo)\n"
                .utf8))
        exit(1)
    }
    let width = Int32(probe.width)
    let height = Int32(probe.height)
    probe.release()
    print("capture: \(device) \(width)x\(height) "
        + "fourcc=0x\(String(probe.fourcc, radix: 16)) "
        + "modifier=0x\(String(probe.modifier, radix: 16)) "
        + "→ \(output) (qp \(qp), \(Int(seconds))s) [swift]")

    let gl: EyeGL
    let encoder: EyeEncoder
    do {
        gl = try EyeGL(renderNode: render)
        encoder = try EyeEncoder(
            width: width, height: height, fps: 60, qp: qp,
            renderNode: render)
    } catch {
        FileHandle.standardError.write(Data("init: \(error)\n".utf8))
        exit(1)
    }

    FileManager.default.createFile(atPath: output, contents: nil)
    guard let file = FileHandle(forWritingAtPath: output) else {
        FileHandle.standardError.write(
            Data("cannot open \(output)\n".utf8))
        exit(1)
    }

    var targetCache: [UInt32: TargetCacheEntry] = [:]
    var lastFB: UInt32 = 0  // ≠ current → first pass encodes immediately
    var frames = 0
    var bytes = 0
    var missedGrabs = 0
    var blitMs = 0.0
    var encodeMs = 0.0
    let t0 = nowSeconds()
    var nextReport = t0 + 1.0
    var framesThisSecond = 0

    while true {
        let t = nowSeconds()
        guard t - t0 < seconds else { break }

        guard let fb = currentFB(fd: fd, planeId: planes.primary.id),
              fb != lastFB else {
            usleep(1000)
            if t >= nextReport {
                print("  t=\(String(format: "%2.0f", t - t0))s "
                    + "frames_this_sec=\(framesThisSecond) total=\(frames)")
                framesThisSecond = 0
                nextReport += 1.0
            }
            continue
        }
        lastFB = fb

        // The flip may already be stale (compositor moved on) — skip,
        // never stall. The dmabuf fds we DO get keep their buffer
        // alive regardless of what the compositor does next.
        guard let ticket = grabTicket(fd: fd, fbId: fb) else {
            missedGrabs += 1
            continue
        }

        var ticketReleased = false
        do {
            let tBlit = nowSeconds()
            var source = try gl.importTexture(
                width: Int32(ticket.width), height: Int32(ticket.height),
                fourcc: ticket.fourcc, modifier: ticket.modifier,
                planes: ticket.planes)
            let frame = try encoder.nextFrame()
            let sid = encoder.surfaceID(of: frame)
            if targetCache[sid] == nil {
                let exported = try encoder.exportSurface(sid)
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
                if exported.uv.fd != exported.y.fd { close(exported.uv.fd) }
                targetCache[sid] = TargetCacheEntry(target: target)
            }
            gl.blit(
                source: source,
                srcWidth: Int32(ticket.width),
                srcHeight: Int32(ticket.height),
                into: targetCache[sid]!.target)
            gl.destroy(&source)
            ticket.release()
            ticketReleased = true
            blitMs += (nowSeconds() - tBlit) * 1e3

            let tEnc = nowSeconds()
            let packets = try encoder.encode(frame, pts: Int64(frames))
            encoder.release(frame)
            encodeMs += (nowSeconds() - tEnc) * 1e3
            for p in packets {
                file.write(p.data)
                bytes += p.data.count
            }
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

    // Drain the encoder.
    if let tail = try? encoder.encode(nil, pts: Int64(frames)) {
        for p in tail {
            file.write(p.data)
            bytes += p.data.count
        }
    }
    try? file.close()

    let duration = nowSeconds() - t0
    print(String(
        format: "RESULT capture: %d frames in %.1fs = %.2f fps, "
            + "%d bytes (%.1f KB/frame), missed_grabs=%d",
        frames, duration, Double(frames) / duration, bytes,
        frames > 0 ? Double(bytes) / Double(frames) / 1024 : 0,
        missedGrabs))
    if frames > 0 {
        print(String(
            format: "RESULT timing: blit %.2f ms/frame, "
                + "encode %.2f ms/frame",
            blitMs / Double(frames), encodeMs / Double(frames)))
    }
    close(fd)
    exit(0)
}

// MARK: - E6b: the native leg — same eye, libva spoken directly

/// The capture loop with EyeVaapiEncoder in the encoder seat: zero
/// libavcodec. Everything else — doorbell, GETFB2, EGL import, the
/// NV12 blit into exported surfaces — is E1's machinery verbatim.
/// Gates: the file decode-probes on the Mac; the books print the
/// same shape as the libav leg for A/B reading.
func runNativeCapture(
    device: String, render: String, seconds: Double,
    output: String, qp: Int32
) -> Never {
    let fd = open(device, O_RDWR)
    guard fd >= 0 else { perror(device); exit(1) }
    drmSetClientCap(fd, UInt64(DRM_CLIENT_CAP_UNIVERSAL_PLANES), 1)
    guard let planes = findActivePlanes(fd: fd) else {
        FileHandle.standardError.write(
            Data("no active primary plane on \(device)\n".utf8))
        exit(1)
    }
    guard let probe = grabTicket(fd: fd, fbId: planes.primary.fb) else {
        FileHandle.standardError.write(Data(
            "GETFB2 failed — capture mode needs privileges\n".utf8))
        exit(1)
    }
    let width = Int32(probe.width)
    let height = Int32(probe.height)
    probe.release()
    print("capture: \(device) \(width)x\(height) → \(output) "
        + "(qp \(qp), \(Int(seconds))s) [NATIVE — no libavcodec]")

    let gl: EyeGL
    let encoder: EyeVaapiEncoder
    do {
        gl = try EyeGL(renderNode: render)
        encoder = try EyeVaapiEncoder(
            width: width, height: height, fps: 60, qp: qp,
            renderNode: render)
    } catch {
        FileHandle.standardError.write(Data("init: \(error)\n".utf8))
        exit(1)
    }

    FileManager.default.createFile(atPath: output, contents: nil)
    guard let file = FileHandle(forWritingAtPath: output) else {
        FileHandle.standardError.write(
            Data("cannot open \(output)\n".utf8))
        exit(1)
    }

    var targets: [UInt32: NV12Target] = [:]
    var lastFB: UInt32 = 0
    var frames = 0
    var bytes = 0
    var keyframes = 0
    var missedGrabs = 0
    var blitMs = 0.0
    var encodeMs = 0.0
    let t0 = nowSeconds()
    var nextReport = t0 + 1.0
    var framesThisSecond = 0

    while true {
        let t = nowSeconds()
        guard t - t0 < seconds else { break }
        guard let fb = currentFB(fd: fd, planeId: planes.primary.id),
              fb != lastFB else {
            usleep(1000)
            if t >= nextReport {
                print("  t=\(String(format: "%2.0f", t - t0))s "
                    + "frames_this_sec=\(framesThisSecond) total=\(frames)")
                framesThisSecond = 0
                nextReport += 1.0
            }
            continue
        }
        lastFB = fb
        guard let ticket = grabTicket(fd: fd, fbId: fb) else {
            missedGrabs += 1
            continue
        }

        var ticketReleased = false
        do {
            let tBlit = nowSeconds()
            var source = try gl.importTexture(
                width: Int32(ticket.width),
                height: Int32(ticket.height),
                fourcc: ticket.fourcc, modifier: ticket.modifier,
                planes: ticket.planes)
            let surface = encoder.inputSurfaces[
                frames % encoder.inputSurfaces.count]
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
            gl.destroy(&source)
            ticket.release()
            ticketReleased = true
            blitMs += (nowSeconds() - tBlit) * 1e3

            let tEnc = nowSeconds()
            let (data, keyframe) = try encoder.encode(
                surface: surface, forceIDR: false)
            encodeMs += (nowSeconds() - tEnc) * 1e3
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

    let duration = nowSeconds() - t0
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
    close(fd)
    exit(0)
}

#endif
