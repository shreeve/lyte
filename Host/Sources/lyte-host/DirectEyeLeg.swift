// DirectEyeLeg (direct-eye plan E1): the fused capture+encode backend
// — the doorbell paces it, HostEye grabs/blits/encodes on the Arc
// media engine, and encoded access units go straight to the session's
// sendFrame (or the probe file). No PipeWire, no portal, no Mutter:
// the compositor cannot wedge a register read.
//
// Honored session levers:
//   - forced-IDR demands (0x0302 / opening) → forceIDR encode
//   - capture timestamps: monotonic µs at ticket grab
// Deliberately NOT honored yet (logged, consumed, counted):
//   - encoder rate directives — libavcodec's hevc_vaapi wrapper takes
//     rate control at open() only; the direct leg runs CQP until
//     E6-VAAPI (native parameter buffers) gives per-frame control.
//     The plan records this as E1's known limitation.

#if os(Linux)

import CDRM
import Foundation
import Glibc
import HostEye

final class DirectEyeLeg {
    struct Config {
        var device = "/dev/dri/card1"
        var renderNode = "/dev/dri/renderD128"
        var seconds: Double
        var qp: Int32 = 24
        var pollUs: UInt32 = 1000
    }

    private let config: Config
    private let wire: SessionWire?
    private let file: UnsafeMutablePointer<FILE>?
    private(set) var frames = 0
    private(set) var firstPacket: [UInt8] = []
    private(set) var bytes = 0
    private(set) var keyframes = 0
    private(set) var missedGrabs = 0
    private(set) var directivesDeferred = 0
    var lastError: String?

    init(config: Config, wire: SessionWire?,
         file: UnsafeMutablePointer<FILE>?) {
        self.config = config
        self.wire = wire
        self.file = file
    }

    /// Blocking loop, portal-run-shaped: returns when the clock (or a
    /// session end / failure) says so.
    func run() {
        let fd = open(config.device, O_RDWR)
        guard fd >= 0 else {
            lastError = "direct: open(\(config.device)) errno \(errno)"
            return
        }
        defer { close(fd) }
        drmSetClientCap(fd, UInt64(DRM_CLIENT_CAP_UNIVERSAL_PLANES), 1)
        guard let planes = findActivePlanes(fd: fd) else {
            lastError = "direct: no active primary plane"
            return
        }
        guard let probe = grabTicket(fd: fd, fbId: planes.primary.fb) else {
            lastError = "direct: GETFB2 refused — the direct backend "
                + "needs CAP_SYS_ADMIN (run under sudo or the E4 unit)"
            return
        }
        let width = Int32(probe.width)
        let height = Int32(probe.height)
        probe.release()

        let gl: EyeGL
        let encoder: EyeEncoder
        do {
            gl = try EyeGL(renderNode: config.renderNode)
            encoder = try EyeEncoder(
                width: width, height: height, fps: 60, qp: config.qp,
                renderNode: config.renderNode)
        } catch {
            lastError = "direct: init failed: \(error)"
            return
        }
        print("direct: eye open — \(width)x\(height) on "
            + "\(config.device), hevc_vaapi qp \(config.qp) "
            + "(rate directives deferred to E6-VAAPI)")

        var targets: [UInt32: NV12Target] = [:]
        var lastFB: UInt32 = 0
        var pendingCauses: [String] = []
        let t0 = nowSeconds()

        while nowSeconds() - t0 < config.seconds {
            if wire?.sessionEnded == true { break }

            // Consume (and defer) rate directives so the queue drains.
            if let directive = wire?.takeEncoderRateDirective() {
                directivesDeferred += 1
                if directivesDeferred == 1 {
                    print("direct: rate directive (\(directive.kind.rawValue))"
                        + " deferred — CQP until E6-VAAPI; counting")
                }
            }

            guard let fb = currentFB(fd: fd, planeId: planes.primary.id),
                  fb != lastFB else {
                usleep(config.pollUs)
                continue
            }
            lastFB = fb
            guard let ticket = grabTicket(fd: fd, fbId: fb) else {
                missedGrabs += 1
                continue
            }
            let captureUs = UInt64(nowSeconds() * 1_000_000)

            let demand = wire?.takeForcedIdrDemand() ?? []
            let forceIdr = frames == 0 || !demand.isEmpty
            if frames == 0 { pendingCauses.append("opening") }
            pendingCauses += demand.names

            var ticketReleased = false
            do {
                var source = try gl.importTexture(
                    width: Int32(ticket.width),
                    height: Int32(ticket.height),
                    fourcc: ticket.fourcc, modifier: ticket.modifier,
                    planes: ticket.planes)
                let frame = try encoder.nextFrame()
                let sid = encoder.surfaceID(of: frame)
                if targets[sid] == nil {
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
                    if exported.uv.fd != exported.y.fd {
                        close(exported.uv.fd)
                    }
                    targets[sid] = target
                }
                gl.blit(
                    source: source,
                    srcWidth: Int32(ticket.width),
                    srcHeight: Int32(ticket.height),
                    into: targets[sid]!)
                gl.destroy(&source)
                ticket.release()
                ticketReleased = true

                let packets = try encoder.encode(
                    frame, pts: Int64(frames), forceIDR: forceIdr)
                encoder.release(frame)
                for packet in packets {
                    // The wrapper pipelines by a frame: keyframe truth
                    // rides ON THE PACKET, and the armed causes attach
                    // to the IDR whenever it actually emerges.
                    let causes = packet.keyframe ? pendingCauses : []
                    if packet.keyframe { pendingCauses.removeAll() }
                    deliver(packet.data, keyframe: packet.keyframe,
                            causes: causes, captureUs: captureUs)
                }
                frames += 1
            } catch {
                if !ticketReleased { ticket.release() }
                lastError = "direct: frame \(frames): \(error)"
                return
            }
        }

        if let tail = try? encoder.encode(nil, pts: Int64(frames)) {
            for packet in tail {
                let causes = packet.keyframe ? pendingCauses : []
                if packet.keyframe { pendingCauses.removeAll() }
                deliver(packet.data, keyframe: packet.keyframe,
                        causes: causes,
                        captureUs: UInt64(nowSeconds() * 1_000_000))
            }
        }
        print("direct: eye closed — \(frames) frames, \(bytes) bytes, "
            + "\(keyframes) IDRs, missed_grabs=\(missedGrabs), "
            + "directives_deferred=\(directivesDeferred)")
    }

    private func deliver(_ packet: Data, keyframe: Bool,
                         causes: [String], captureUs: UInt64) {
        packet.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            if firstPacket.isEmpty {
                firstPacket = Array(raw.bindMemory(to: UInt8.self))
            }
            if let wire {
                do {
                    try wire.sendFrame(
                        data: base, size: packet.count,
                        isKeyframe: keyframe, captureMicros: captureUs)
                    wire.annotateLastVideoFrame(
                        averageQP: nil,
                        idrCauses: keyframe
                            ? (causes.isEmpty ? ["spontaneous"] : causes)
                            : [])
                } catch {
                    lastError = "direct: session send failed: \(error)"
                    return
                }
            } else if let file {
                fwrite(base, 1, packet.count, file)
            }
        }
        bytes += packet.count
        if keyframe { keyframes += 1 }
    }
}

#endif
