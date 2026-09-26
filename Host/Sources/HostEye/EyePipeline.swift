// The direct eye's GPU pipeline from an observed scanout to an encoded
// access unit: dmabuf import (cached per framebuffer identity), pixel
// fingerprint, blit into a VAAPI input surface (NV12, or packed AYUV for
// 4:4:4), and native encode. Pacing, damage policy and delivery stay
// with the callers.

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

    /// The encoder's frame rate: one frame per screen beat.
    public static let fps = 60

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
    /// The opening HRD buffer, restored for every new session.
    private let openingHrdBufferBits: Int64?
    private var nv12Targets: [VASurfaceID: NV12Target] = [:]
    private var ayuvTargets: [VASurfaceID: AyuvTarget] = [:]
    private var scanout: ImportedTexture?
    private var scanoutIdentity: UInt32?
    /// The imported buffer's `ScanoutTicket.bufferIdentity`.
    private var scanoutBuffer: UInt64?
    private var freshEncodes = 0

    public init(
        width: Int32, height: Int32, renderNode: String, qp: Int32,
        bitrateBitsPerSecond: Int64, hrdBufferBits: Int64? = nil,
        chroma444: Bool = false
    ) throws {
        self.width = width
        self.height = height
        self.renderNode = renderNode
        self.qp = qp
        self.bitrateBitsPerSecond = bitrateBitsPerSecond
        self.openingHrdBufferBits = hrdBufferBits
        self.chroma444 = chroma444
        gl = try EyeGL(renderNode: renderNode)
        encoder = try EyeVaapiEncoder(
            width: width, height: height, fps: Int32(Self.fps), qp: qp,
            renderNode: renderNode,
            bitrateBitsPerSecond: bitrateBitsPerSecond,
            hrdBufferBits: hrdBufferBits,
            chroma444: chroma444)
    }

    deinit {
        releaseGPUState()
    }

    /// Imports the observation's scanout unless the cached import is the
    /// same buffer. The kernel reuses framebuffer ids lowest-first, so a
    /// new buffer can arrive under the cached id within one beat; the id
    /// alone would leave the fingerprint watching the old buffer, a
    /// frozen screen. The buffer's dma-buf identity decides.
    public func refreshScanout(
        _ observation: ScreenSourceObservation, from screen: some ScreenSource
    ) throws -> ScanoutUpdate {
        guard let ticket = screen.capture(observation) else {
            return .missedGrab
        }
        defer { ticket.release() }
        let buffer = ticket.bufferIdentity
        if scanout != nil, buffer != nil, buffer == scanoutBuffer,
           scanoutIdentity == observation.framebufferIdentity {
            return .current
        }
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
        scanoutBuffer = buffer
        gl.resetFingerprint()
        return .imported
    }

    /// Whether the imported scanout's pixels differ from the last
    /// fingerprint (always true after an import or a reset).
    public func scanoutChanged() throws -> Bool {
        guard let scanout else {
            throw EyeGLError("scanout import disappeared")
        }
        return try gl.scanoutChanged(
            source: scanout, width: width, height: height)
    }

    /// Makes the current scanout fresh on the next fingerprint.
    /// The encoder's one-line description (driver, entrypoint, rate).
    public var encoderSummary: String { encoder.summary }

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
                let plane = try encoder.exportLayers(surface, count: 1)[0]
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
                let layers = try encoder.exportLayers(surface, count: 2)
                defer { Set(layers.map(\.fd)).forEach { close($0) } }
                let (y, uv) = (layers[0], layers[1])
                nv12Targets[surface] = try gl.makeNV12Target(
                    width: width, height: height,
                    yFourcc: y.fourcc, yModifier: y.modifier,
                    yPlane: (y.fd, y.offset, y.pitch),
                    uvFourcc: uv.fourcc, uvModifier: uv.modifier,
                    uvPlane: (uv.fd, uv.offset, uv.pitch))
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
    public func setRateControl(
        bitsPerSecond: Int64, hrdBufferBits: Int64? = nil
    ) {
        encoder.setRateControl(
            bitsPerSecond: bitsPerSecond, hrdBufferBits: hrdBufferBits)
    }

    /// Starts the next session's stream on the warm GL context: the
    /// encoder reopens at the opening rate control in the session's
    /// chroma (first frame an IDR with VPS/SPS/PPS). Every GPU target and
    /// the scanout import are rebuilt and the retained surface is
    /// forgotten, so no per-session state survives. This is the only
    /// reopen: chroma never changes mid-stream.
    public func beginSession(chroma444: Bool) throws {
        releaseGPUState()
        retainedSurface = nil
        freshEncodes = 0
        encoder = try EyeVaapiEncoder(
            width: width, height: height, fps: Int32(Self.fps), qp: qp,
            renderNode: renderNode,
            bitrateBitsPerSecond: bitrateBitsPerSecond,
            hrdBufferBits: openingHrdBufferBits,
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
        scanoutBuffer = nil
        gl.resetFingerprint()
    }
}
