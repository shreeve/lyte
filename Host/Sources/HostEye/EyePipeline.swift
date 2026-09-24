// EyePipeline: the direct eye's GPU pipeline from an observed scanout to
// an encoded access unit — the dmabuf import of the current scanout (one
// cached import per framebuffer identity), the pixel fingerprint, the
// blit into an exported VAAPI input surface (NV12, or packed AYUV for
// Rext 4:4:4), and the native encode. The production leg and the
// standalone lyte-eye witness drive the same pipeline; pacing, damage
// policy, and delivery stay with them.

#if os(Linux)

import CVA
import Glibc
import LyteIO

public final class EyePipeline {
    public enum ScanoutUpdate: Equatable {
        /// The imported scanout already matches the observation.
        case current
        /// A new framebuffer was imported; the fingerprint restarts.
        case imported
        /// The framebuffer vanished between observation and grab.
        case missedGrab
        /// The display geometry no longer matches the pipeline's.
        case geometryChanged(width: UInt32, height: UInt32)
    }

    public let width: Int32
    public let height: Int32
    public private(set) var chroma444: Bool
    /// The input surface the last encode read — a static screen's
    /// retained frame, re-encodable without a new observation.
    public private(set) var retainedSurface: VASurfaceID?
    /// Microseconds the last fresh encode spent blitting and encoding.
    public private(set) var lastBlitMicroseconds: UInt64 = 0
    public private(set) var lastEncodeMicroseconds: UInt64 = 0

    private let gl: EyeGL
    private var encoder: EyeVaapiEncoder
    private let renderNode: String
    private let qp: Int32
    private let bitrateBitsPerSecond: Int64
    private var nv12Targets: [VASurfaceID: NV12Target] = [:]
    private var ayuvTargets: [VASurfaceID: AyuvTarget] = [:]
    private var scanout: ImportedTexture?
    private var scanoutIdentity: UInt32?
    private var freshEncodes = 0

    public init(
        width: Int32, height: Int32, renderNode: String, qp: Int32,
        bitrateBitsPerSecond: Int64, chroma444: Bool = false
    ) throws {
        self.width = width
        self.height = height
        self.renderNode = renderNode
        self.qp = qp
        self.bitrateBitsPerSecond = bitrateBitsPerSecond
        self.chroma444 = chroma444
        gl = try EyeGL(renderNode: renderNode)
        encoder = try EyeVaapiEncoder(
            width: width, height: height, fps: 60, qp: qp,
            renderNode: renderNode,
            bitrateBitsPerSecond: bitrateBitsPerSecond,
            chroma444: chroma444)
    }

    deinit {
        releaseGPUState()
    }

    /// Imports the observation's scanout when its framebuffer identity
    /// differs from the cached import.
    public func refreshScanout(
        _ observation: ScreenSourceObservation, from screen: some ScreenSource
    ) throws -> ScanoutUpdate {
        if scanout != nil, scanoutIdentity == observation.framebufferIdentity {
            return .current
        }
        guard let ticket = screen.capture(observation) else {
            return .missedGrab
        }
        defer { ticket.release() }
        guard Int32(ticket.width) == width, Int32(ticket.height) == height else {
            return .geometryChanged(width: ticket.width, height: ticket.height)
        }
        let imported = try gl.importTexture(
            width: Int32(ticket.width),
            height: Int32(ticket.height),
            fourcc: ticket.fourcc,
            modifier: ticket.modifier,
            planes: ticket.planes)
        if var old = scanout { gl.destroy(&old) }
        scanout = imported
        scanoutIdentity = observation.framebufferIdentity
        gl.resetFingerprint()
        return .imported
    }

    /// Whether the imported scanout's pixels differ from the last
    /// fingerprint (always true after an import or a reset).
    public func pixelsChanged() throws -> Bool {
        guard let scanout else {
            throw EyeGLError("scanout import disappeared")
        }
        return try gl.scanoutChanged(
            source: scanout, width: width, height: height)
    }

    /// Makes the current scanout fresh on the next fingerprint.
    public func resetFingerprint() {
        gl.resetFingerprint()
    }

    /// Blits the imported scanout into the next input surface and encodes
    /// it, lending the access unit to `body` (see EyeVaapiEncoder.encode).
    public func encodeFresh<R>(
        forceIDR: Bool, _ body: (UnsafeRawBufferPointer, Bool) throws -> R
    ) throws -> R {
        guard let scanout else {
            throw EyeGLError("scanout import disappeared")
        }
        let surface = encoder.inputSurfaces[
            freshEncodes % encoder.inputSurfaces.count]
        let blitStart = SystemMonotonicClock.nowMicroseconds
        if chroma444 {
            if ayuvTargets[surface] == nil {
                let plane = try encoder.exportSurfacePacked(surface)
                defer { close(plane.fd) }
                ayuvTargets[surface] = try gl.makeAyuvTarget(
                    width: width, height: height,
                    modifier: plane.modifier,
                    plane: (plane.fd, plane.offset, plane.pitch))
            }
            gl.blit444(
                source: scanout, srcWidth: width, srcHeight: height,
                into: ayuvTargets[surface]!)
        } else {
            if nv12Targets[surface] == nil {
                let exported = try encoder.exportSurface(surface)
                defer {
                    close(exported.y.fd)
                    if exported.uv.fd != exported.y.fd {
                        close(exported.uv.fd)
                    }
                }
                nv12Targets[surface] = try gl.makeNV12Target(
                    width: width, height: height,
                    yFourcc: exported.y.fourcc,
                    yModifier: exported.y.modifier,
                    yPlane: (exported.y.fd, exported.y.offset,
                             exported.y.pitch),
                    uvFourcc: exported.uv.fourcc,
                    uvModifier: exported.uv.modifier,
                    uvPlane: (exported.uv.fd, exported.uv.offset,
                              exported.uv.pitch))
            }
            gl.blit(
                source: scanout, srcWidth: width, srcHeight: height,
                into: nv12Targets[surface]!)
        }
        let encodeStart = SystemMonotonicClock.nowMicroseconds
        lastBlitMicroseconds = encodeStart - blitStart
        // Synchronous seat: vaSyncSurface inside encode frees the input
        // surface by return, so round-robin reuse never aliases.
        return try encoder.encode(surface: surface, forceIDR: forceIDR) {
            bytes, keyframe in
            lastEncodeMicroseconds =
                SystemMonotonicClock.nowMicroseconds - encodeStart
            freshEncodes += 1
            retainedSurface = surface
            return try body(bytes, keyframe)
        }
    }

    /// Re-encodes the retained surface (a static screen's recovery IDR or
    /// keepalive). Nil when nothing has been encoded yet.
    public func encodeRetained<R>(
        forceIDR: Bool, _ body: (UnsafeRawBufferPointer, Bool) throws -> R
    ) throws -> R? {
        guard let surface = retainedSurface else { return nil }
        return try encoder.encode(surface: surface, forceIDR: forceIDR, body)
    }

    /// Rate directives apply with the next frame's RC misc buffer.
    public func setRateBitsPerSecond(_ bitsPerSecond: Int64) {
        encoder.setRateBitsPerSecond(bitsPerSecond)
    }

    /// Reopens the encoder in the other chroma posture. Every GPU target
    /// and the scanout import are rebuilt, and the retained surface is
    /// forgotten, so the next observation encodes fresh as an IDR.
    public func reopen(chroma444: Bool) throws {
        releaseGPUState()
        retainedSurface = nil
        freshEncodes = 0
        encoder = try EyeVaapiEncoder(
            width: width, height: height, fps: 60, qp: qp,
            renderNode: renderNode,
            bitrateBitsPerSecond: bitrateBitsPerSecond,
            chroma444: chroma444)
        self.chroma444 = chroma444
    }

    private func releaseGPUState() {
        for surface in nv12Targets.keys { gl.destroy(&nv12Targets[surface]!) }
        nv12Targets.removeAll()
        for surface in ayuvTargets.keys { gl.destroy(&ayuvTargets[surface]!) }
        ayuvTargets.removeAll()
        if var source = scanout { gl.destroy(&source) }
        scanout = nil
        scanoutIdentity = nil
        gl.resetFingerprint()
    }
}

#endif
