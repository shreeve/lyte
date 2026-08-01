// EyeEncoder: the vendored libavcodec hevc_vaapi leaf, in Swift — a
// VAAPI device + NV12 frame pool, surface export to dmabuf (the GL
// blit's render targets), and Annex-B packets out. Consent to a
// little unsafety is explicit and localized: one documented layout
// read (AVVAAPIDeviceContext.display is the struct's first field —
// stable public ABI) keeps VA types out of the libav module.

#if os(Linux)

import CLibAV
import CVA
import Foundation
import Glibc

public struct EyeEncoderError: Error, CustomStringConvertible {
    public var description: String
    init(_ d: String) { description = d }
}

/// One exported NV12 plane of a VAAPI surface.
public struct ExportedPlane {
    public var fourcc: UInt32
    public var modifier: UInt64
    public var fd: Int32
    public var offset: UInt32
    public var pitch: UInt32
}

private let AVERROR_EAGAIN: Int32 = -11  // Linux EAGAIN
private let AVERROR_EOF_V: Int32 = -541_478_725  // FFERRTAG('E','O','F',' ')

public final class EyeEncoder {
    private var deviceRef: UnsafeMutablePointer<AVBufferRef>?
    private var framesRef: UnsafeMutablePointer<AVBufferRef>?
    private var ctx: UnsafeMutablePointer<AVCodecContext>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var vaDisplay: VADisplay?
    public let width: Int32
    public let height: Int32

    public init(width: Int32, height: Int32, fps: Int32, qp: Int32,
         renderNode: String) throws {
        self.width = width
        self.height = height

        var dev: UnsafeMutablePointer<AVBufferRef>?
        guard av_hwdevice_ctx_create(
            &dev, AV_HWDEVICE_TYPE_VAAPI, renderNode, nil, 0) >= 0,
            let dev
        else { throw EyeEncoderError("VAAPI device on \(renderNode) failed") }
        deviceRef = dev

        // The one layout read: AVHWDeviceContext.hwctx →
        // AVVAAPIDeviceContext, whose FIRST member is `VADisplay display`
        // (libavutil/hwcontext_vaapi.h, stable across every release we
        // pin). Including that header here would mint duplicate Swift
        // types against CLibAV — this single documented load is the
        // lesser evil.
        let devCtx = UnsafeMutableRawPointer(dev.pointee.data)!
            .assumingMemoryBound(to: AVHWDeviceContext.self)
        vaDisplay = devCtx.pointee.hwctx?
            .load(as: VADisplay?.self) ?? nil
        guard vaDisplay != nil else {
            throw EyeEncoderError("no VADisplay in device context")
        }

        guard let frames = av_hwframe_ctx_alloc(dev) else {
            throw EyeEncoderError("av_hwframe_ctx_alloc failed")
        }
        framesRef = frames
        let fc = UnsafeMutableRawPointer(frames.pointee.data)!
            .assumingMemoryBound(to: AVHWFramesContext.self)
        fc.pointee.format = AV_PIX_FMT_VAAPI
        fc.pointee.sw_format = AV_PIX_FMT_NV12
        fc.pointee.width = width
        fc.pointee.height = height
        fc.pointee.initial_pool_size = 8
        guard av_hwframe_ctx_init(frames) >= 0 else {
            throw EyeEncoderError("av_hwframe_ctx_init failed")
        }

        guard let codec = avcodec_find_encoder_by_name("hevc_vaapi") else {
            throw EyeEncoderError(
                "hevc_vaapi missing from the vendored libavcodec — "
                + "re-run Host/Scripts/vendor-ffmpeg.sh")
        }
        ctx = avcodec_alloc_context3(codec)
        guard let ctx else { throw EyeEncoderError("alloc ctx failed") }
        ctx.pointee.width = width
        ctx.pointee.height = height
        ctx.pointee.time_base = AVRational(num: 1, den: fps)
        ctx.pointee.framerate = AVRational(num: fps, den: 1)
        ctx.pointee.pix_fmt = AV_PIX_FMT_VAAPI
        ctx.pointee.hw_frames_ctx = av_buffer_ref(frames)
        ctx.pointee.gop_size = 120
        ctx.pointee.max_b_frames = 0
        ctx.pointee.color_range = AVCOL_RANGE_MPEG
        ctx.pointee.colorspace = AVCOL_SPC_BT709
        ctx.pointee.color_primaries = AVCOL_PRI_BT709
        ctx.pointee.color_trc = AVCOL_TRC_BT709
        av_opt_set_int(ctx.pointee.priv_data, "qp", Int64(qp), 0)
        guard avcodec_open2(ctx, codec, nil) >= 0 else {
            throw EyeEncoderError("avcodec_open2(hevc_vaapi) failed")
        }
        packet = av_packet_alloc()
    }

    /// A pooled NV12 VAAPI frame; data[3] carries the VASurfaceID.
    public func nextFrame() throws -> UnsafeMutablePointer<AVFrame> {
        guard let frame = av_frame_alloc() else {
            throw EyeEncoderError("av_frame_alloc failed")
        }
        guard av_hwframe_get_buffer(framesRef, frame, 0) >= 0 else {
            av_frame_free_swift(frame)
            throw EyeEncoderError("av_hwframe_get_buffer failed (pool dry?)")
        }
        return frame
    }

    public func surfaceID(of frame: UnsafeMutablePointer<AVFrame>) -> UInt32 {
        UInt32(UInt(bitPattern: frame.pointee.data.3))
    }

    /// Export the surface as separate NV12 layers for EGL import.
    /// Caller owns (and must close) the returned dmabuf fds AFTER the
    /// EGLImages are created.
    ///
    /// VADRMPRIMESurfaceDescriptor holds ARRAYS OF ANONYMOUS STRUCTS,
    /// which the Swift importer drops entirely (the imported type has
    /// no `objects`/`layers` members and the WRONG size). The function
    /// takes `void *descriptor`, so we pass our own raw buffer and
    /// read the C ABI layout by offset (x86_64, va_drmcommon.h):
    ///   fourcc@0 width@4 height@8 num_objects@12
    ///   objects[4]@16, elem 16: {fd:i32@0, size:u32@4, modifier:u64@8}
    ///   num_layers@80
    ///   layers[4]@84, elem 56: {drm_format@0, num_planes@4,
    ///     object_index[4]@8, offset[4]@24, pitch[4]@40}
    public func exportSurface(_ id: UInt32) throws -> (y: ExportedPlane,
                                                uv: ExportedPlane) {
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: 512, alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: 512)
        let status = vaExportSurfaceHandle(
            vaDisplay, id,
            UInt32(VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2),
            UInt32(VA_EXPORT_SURFACE_WRITE_ONLY
                | VA_EXPORT_SURFACE_SEPARATE_LAYERS),
            raw)
        guard status == VA_STATUS_SUCCESS else {
            throw EyeEncoderError("vaExportSurfaceHandle: \(status)")
        }
        func objectFd(_ i: Int) -> Int32 {
            raw.load(fromByteOffset: 16 + 16 * i, as: Int32.self)
        }
        func objectModifier(_ i: Int) -> UInt64 {
            raw.load(fromByteOffset: 16 + 16 * i + 8, as: UInt64.self)
        }
        let numObjects = Int(raw.load(fromByteOffset: 12, as: UInt32.self))
        let numLayers = Int(raw.load(fromByteOffset: 80, as: UInt32.self))
        guard numLayers >= 2 else {
            for i in 0..<numObjects { close(objectFd(i)) }
            throw EyeEncoderError("expected 2 NV12 layers, got \(numLayers)")
        }
        func plane(_ i: Int) -> ExportedPlane {
            let base = 84 + 56 * i
            let objIndex = Int(raw.load(
                fromByteOffset: base + 8, as: UInt32.self))
            return ExportedPlane(
                fourcc: raw.load(fromByteOffset: base, as: UInt32.self),
                modifier: objectModifier(objIndex),
                fd: objectFd(objIndex),
                offset: raw.load(
                    fromByteOffset: base + 24, as: UInt32.self),
                pitch: raw.load(
                    fromByteOffset: base + 40, as: UInt32.self))
        }
        return (y: plane(0), uv: plane(1))
    }

    /// Encode one frame; returns the Annex-B packets it yielded, each
    /// tagged with the PACKET's own keyframe flag (AV_PKT_FLAG_KEY).
    /// The wrapper pipelines by a frame, so a send-side forceIDR flag
    /// does NOT describe the packet this call returns — the wire's
    /// isKeyframe must come from here, never from the send site.
    public func encode(_ frame: UnsafeMutablePointer<AVFrame>?,
                       pts: Int64,
                       forceIDR: Bool = false) throws
        -> [(data: Data, keyframe: Bool)] {
        if let frame {
            frame.pointee.pts = pts
            // vaapi_encode honors a forced I picture as an IDR — the
            // wire's on-demand keyframe lever (0x0302, loss recovery).
            frame.pointee.pict_type =
                forceIDR ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE
        }
        let sendRc = avcodec_send_frame(ctx, frame)
        guard sendRc >= 0 || sendRc == AVERROR_EOF_V else {
            throw EyeEncoderError("send_frame: \(sendRc)")
        }
        var out: [(data: Data, keyframe: Bool)] = []
        while true {
            let rc = avcodec_receive_packet(ctx, packet)
            if rc == AVERROR_EAGAIN || rc == AVERROR_EOF_V { break }
            guard rc >= 0, let pkt = packet else {
                throw EyeEncoderError("receive_packet: \(rc)")
            }
            out.append((
                data: Data(bytes: pkt.pointee.data,
                           count: Int(pkt.pointee.size)),
                keyframe: pkt.pointee.flags & Int32(AV_PKT_FLAG_KEY) != 0
            ))
            av_packet_unref(packet)
        }
        return out
    }

    public func release(_ frame: UnsafeMutablePointer<AVFrame>) {
        av_frame_free_swift(frame)
    }
}

/// av_frame_free takes AVFrame** — one Swift-side wrapper.
private func av_frame_free_swift(_ frame: UnsafeMutablePointer<AVFrame>) {
    var f: UnsafeMutablePointer<AVFrame>? = frame
    av_frame_free(&f)
}

#endif
