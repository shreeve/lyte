// EyeVaapiEncoder (E6b): the native VAAPI HEVC encoder — libva
// spoken directly, zero libavcodec. The bitstream authorship lives
// in HostCore's pens (HevcParameterSets, HevcSliceHeader — both
// byte-pinned against the hevc_vaapi oracle); this class is the
// driver plumbing those pens feed: display → config/context →
// surfaces → per-frame parameter buffers → packed headers → coded
// readback. The parameter-buffer fills mirror vaapi_encode_h265.c
// field-for-field (read from the vendored tree, 2026-08-01), so the
// driver sees exactly what it saw from ffmpeg — minus ffmpeg.
//
// Dialect: HEVC Main 8-bit 4:2:0 — or, with chroma444 (the Best
// tier), Rext Main 4:4:4 8-bit on AYUV surfaces — IPPP with one
// reference, CTB 64.
// The entrypoint is queried at open (EncSlice preferred, EncSliceLP
// accepted — pup's Arc offers LP/VDENC); the driver's
// PredictionDirection attribute decides GPB (BI_NOT_EMPTY → inter
// frames are B slices with both lists = previous picture, the iHD
// quirk the slice pen mirrors).
//
// Rate control: CQP (qp) or VBR (bitrateBitsPerSecond > 0 — target
// 70% of cap, the E1 envelope). setRateBitsPerSecond() re-sends the
// RC misc buffer with the NEXT frame — the live directive lever
// libavcodec's wrapper never had (rc at open() only), un-deferring
// the estimator's rate moves.

#if os(Linux)

import CVA
import Foundation
import Glibc
import HostCore

public struct EyeVaapiError: Error, CustomStringConvertible {
    public var description: String
    init(_ what: String, _ status: VAStatus) {
        description = "\(what): VAStatus \(status) "
            + "(\(String(cString: vaErrorStr(status))))"
    }
    init(_ what: String) { description = what }
}

public final class EyeVaapiEncoder {
    public let width: Int32
    public let height: Int32
    public let fps: Int32
    public let qp: Int32
    /// The Best tier: Rext Main 4:4:4 on packed AYUV surfaces.
    public let chroma444: Bool
    /// True when the driver demanded GPB (BI_NOT_EMPTY) — the slice
    /// pen's trailGPB dialect. False would mean plain P slices,
    /// which no pen writes yet: open() refuses rather than guesses.
    public private(set) var gpb = true
    /// Input surfaces — the GL blit's render targets, exported via
    /// `exportSurface` exactly like the libavcodec pool was.
    public private(set) var inputSurfaces: [VASurfaceID] = []

    private let drmFd: Int32
    private let display: VADisplay
    private var configID = VAConfigID(VA_INVALID_ID)
    private var contextID = VAContextID(VA_INVALID_ID)
    private var reconSurfaces: [VASurfaceID] = []
    private var codedBuffer = VABufferID(VA_INVALID_ID)
    private let recipe: HevcHeaderRecipe
    private let bitrateBitsPerSecond: Int64
    private var pendingRate: Int64?
    /// The rate the driver currently holds — a directive's move must
    /// survive later IDR re-sends (which rebuild the RC/HRD buffers).
    private var currentRate: Int64 = 0
    private var frameIndex: Int64 = 0
    private var poc: UInt32 = 0
    private var previousRecon = VASurfaceID(VA_INVALID_ID)
    private var previousPoc: UInt32 = 0

    private func check(_ status: VAStatus, _ what: String) throws {
        guard status == VA_STATUS_SUCCESS else {
            throw EyeVaapiError(what, status)
        }
    }

    /// The startup probe behind the host's chroma declaration (V-4:
    /// declared on PROOF, never a hardcoded claim): does this silicon
    /// offer Rext Main 4:4:4 encode? A short-lived display of its
    /// own — no session, no surfaces, closed before return.
    public static func probesMain444(
        renderNode: String = "/dev/dri/renderD128"
    ) -> Bool {
        let fd = open(renderNode, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard let display = vaGetDisplayDRM(fd) else { return false }
        var major: Int32 = 0, minor: Int32 = 0
        guard vaInitialize(display, &major, &minor)
            == VA_STATUS_SUCCESS else { return false }
        defer { vaTerminate(display) }
        var entrypoints = [VAEntrypoint](
            repeating: VAEntrypointVLD,
            count: Int(vaMaxNumEntrypoints(display))
        )
        var count: Int32 = 0
        guard vaQueryConfigEntrypoints(
            display, VAProfileHEVCMain444, &entrypoints, &count
        ) == VA_STATUS_SUCCESS else { return false }
        return entrypoints.prefix(Int(count)).contains {
            $0 == VAEntrypointEncSlice || $0 == VAEntrypointEncSliceLP
        }
    }

    public init(
        width: Int32, height: Int32, fps: Int32, qp: Int32,
        renderNode: String = "/dev/dri/renderD128",
        bitrateBitsPerSecond: Int64 = 0,
        inputSurfaceCount: Int = 8,
        chroma444: Bool = false
    ) throws {
        self.width = width
        self.height = height
        self.fps = fps
        self.qp = qp
        self.chroma444 = chroma444
        self.bitrateBitsPerSecond = bitrateBitsPerSecond
        self.currentRate = bitrateBitsPerSecond
        // The BRC dialect (pinned to ffmpeg's on this driver): under
        // rate control the PPS baseline is QP 30 and per-CU QP deltas
        // are declared at 8x8 granularity (depth = the SPS's
        // log2_diff_max_min_luma_coding_block_size, 3) — the driver
        // writes deltas into the slice data whether or not the PPS
        // admits it, so the PPS MUST admit it. CQP keeps the caller's
        // qp and no delta syntax.
        self.recipe = HevcHeaderRecipe(
            width: UInt32(width), height: UInt32(height),
            fpsNumerator: UInt32(fps), fpsDenominator: 1,
            initialQP: bitrateBitsPerSecond > 0 ? 30 : qp,
            cuQpDeltaDepth: bitrateBitsPerSecond > 0 ? 3 : nil,
            chroma444: chroma444
        )

        drmFd = open(renderNode, O_RDWR)
        guard drmFd >= 0 else {
            throw EyeVaapiError("open(\(renderNode)) errno \(errno)")
        }
        guard let display = vaGetDisplayDRM(drmFd) else {
            close(drmFd)
            throw EyeVaapiError("vaGetDisplayDRM returned nil")
        }
        self.display = display
        var major: Int32 = 0, minor: Int32 = 0
        try check(vaInitialize(display, &major, &minor), "vaInitialize")

        // Profile: Main, or Rext Main444 for the Best tier (probed
        // on the Arc: VAProfileHEVCMain444 offers EncSlice).
        let profile = chroma444 ? VAProfileHEVCMain444 : VAProfileHEVCMain

        // Entrypoint: EncSlice preferred, LP accepted (pup's Arc is
        // VDENC-only for HEVC).
        var entrypoints = [VAEntrypoint](
            repeating: VAEntrypointVLD,
            count: Int(vaMaxNumEntrypoints(display))
        )
        var entrypointCount: Int32 = 0
        try check(vaQueryConfigEntrypoints(
            display, profile, &entrypoints, &entrypointCount
        ), "vaQueryConfigEntrypoints(HEVC)")
        let available = Set(entrypoints.prefix(Int(entrypointCount)))
        let entrypoint: VAEntrypoint
        if available.contains(VAEntrypointEncSlice) {
            entrypoint = VAEntrypointEncSlice
        } else if available.contains(VAEntrypointEncSliceLP) {
            entrypoint = VAEntrypointEncSliceLP
        } else {
            throw EyeVaapiError(
                "no HEVC encode entrypoint (have \(available))")
        }

        // GPB truth (VA 1.9+): BI_NOT_EMPTY → the driver refuses
        // plain P; the slice pen's dialect. Anything else is a
        // hardware this pen has not met — refuse loudly.
        var prediction = VAConfigAttrib(
            type: VAConfigAttribPredictionDirection, value: 0)
        _ = vaGetConfigAttributes(
            display, profile, entrypoint, &prediction, 1)
        if prediction.value != VA_ATTRIB_NOT_SUPPORTED {
            gpb = prediction.value
                & UInt32(VA_PREDICTION_DIRECTION_BI_NOT_EMPTY) != 0
        }
        guard gpb else {
            throw EyeVaapiError("driver wants plain P slices — the "
                + "slice pen only speaks the iHD GPB dialect yet")
        }

        // Config: NV12 (or packed AYUV at 4:4:4), our RC mode, and
        // packed headers we author.
        let rtFormat = chroma444
            ? UInt32(VA_RT_FORMAT_YUV444) : UInt32(VA_RT_FORMAT_YUV420)
        var attribs = [
            VAConfigAttrib(
                type: VAConfigAttribRTFormat,
                value: rtFormat),
            VAConfigAttrib(
                type: VAConfigAttribRateControl,
                value: bitrateBitsPerSecond > 0
                    ? UInt32(VA_RC_VBR) : UInt32(VA_RC_CQP)),
            VAConfigAttrib(
                type: VAConfigAttribEncPackedHeaders,
                value: UInt32(VA_ENC_PACKED_HEADER_SEQUENCE)
                    | UInt32(VA_ENC_PACKED_HEADER_SLICE)),
        ]
        try check(vaCreateConfig(
            display, profile, entrypoint,
            &attribs, Int32(attribs.count), &configID
        ), "vaCreateConfig")

        // Surfaces: the GL-facing input pool and the driver-facing
        // recon pool (alternating pair — one holds the reference
        // while the other receives the current reconstruction).
        let fourcc = chroma444
            ? Int32(truncatingIfNeeded: 0x5655_5941 as UInt32) // AYUV
            : Int32(truncatingIfNeeded: VA_FOURCC_NV12)
        var pixelFormat = VASurfaceAttrib(
            type: VASurfaceAttribPixelFormat,
            flags: UInt32(VA_SURFACE_ATTRIB_SETTABLE),
            value: VAGenericValue(
                type: VAGenericValueTypeInteger,
                value: .init(i: fourcc)))
        inputSurfaces = [VASurfaceID](
            repeating: VASurfaceID(VA_INVALID_ID),
            count: inputSurfaceCount)
        try check(vaCreateSurfaces(
            display, rtFormat,
            UInt32(width), UInt32(height),
            &inputSurfaces, UInt32(inputSurfaceCount),
            &pixelFormat, 1
        ), "vaCreateSurfaces(input)")
        reconSurfaces = [VASurfaceID](
            repeating: VASurfaceID(VA_INVALID_ID), count: 2)
        try check(vaCreateSurfaces(
            display, rtFormat,
            UInt32(width), UInt32(height),
            &reconSurfaces, 2, &pixelFormat, 1
        ), "vaCreateSurfaces(recon)")

        try check(vaCreateContext(
            display, configID, width, height,
            Int32(VA_PROGRESSIVE),
            &inputSurfaces, Int32(inputSurfaces.count), &contextID
        ), "vaCreateContext")

        var coded = VABufferID(VA_INVALID_ID)
        try check(vaCreateBuffer(
            display, contextID, VAEncCodedBufferType,
            UInt32(chroma444
                ? width * height * 3 + 1 << 16
                : width * height * 3 / 2 + 1 << 16), 1, nil, &coded
        ), "vaCreateBuffer(coded)")
        codedBuffer = coded

        let rc = bitrateBitsPerSecond > 0
            ? "vbr \(bitrateBitsPerSecond / 1_000_000) Mbps cap"
            : "cqp \(qp)"
        print("vaapi-native: \(String(cString: vaQueryVendorString(display))) "
            + "— \(entrypoint == VAEntrypointEncSliceLP ? "LP" : "std")"
            + " entrypoint, GPB, \(rc)"
            + (chroma444 ? ", Rext Main444 (AYUV)" : ""))
    }

    deinit {
        if codedBuffer != VA_INVALID_ID {
            vaDestroyBuffer(display, codedBuffer)
        }
        if contextID != VA_INVALID_ID {
            vaDestroyContext(display, contextID)
        }
        if !inputSurfaces.isEmpty {
            vaDestroySurfaces(
                display, &inputSurfaces, Int32(inputSurfaces.count))
        }
        if !reconSurfaces.isEmpty {
            vaDestroySurfaces(
                display, &reconSurfaces, Int32(reconSurfaces.count))
        }
        if configID != VA_INVALID_ID {
            vaDestroyConfig(display, configID)
        }
        vaTerminate(display)
        close(drmFd)
    }

    /// E6b's lever: takes effect with the NEXT frame's RC misc
    /// buffer — no reset, no IDR, no reopen.
    public func setRateBitsPerSecond(_ bitsPerSecond: Int64) {
        pendingRate = bitsPerSecond
    }

    // MARK: Surface export (the E1 raw-offset parse, verbatim — the
    // imported VADRMPRIMESurfaceDescriptor drops its anonymous-struct
    // arrays, so the bytes are read by documented offset)

    public func exportSurface(
        _ id: VASurfaceID
    ) throws -> (y: ExportedPlane, uv: ExportedPlane) {
        let descriptor = UnsafeMutableRawPointer.allocate(
            byteCount: 512, alignment: 8)
        defer { descriptor.deallocate() }
        descriptor.initializeMemory(
            as: UInt8.self, repeating: 0, count: 512)
        let status = vaExportSurfaceHandle(
            display, id,
            UInt32(VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2),
            UInt32(VA_EXPORT_SURFACE_WRITE_ONLY)
                | UInt32(VA_EXPORT_SURFACE_SEPARATE_LAYERS),
            descriptor
        )
        try check(status, "vaExportSurfaceHandle(\(id))")
        func u32(_ offset: Int) -> UInt32 {
            descriptor.load(fromByteOffset: offset, as: UInt32.self)
        }
        func u64(_ offset: Int) -> UInt64 {
            descriptor.load(fromByteOffset: offset, as: UInt64.self)
        }
        // struct offsets: fourcc@0 w@4 h@8 num_objects@12,
        // objects[4]@16 (elem 16: fd@0 size@4 modifier@8),
        // num_layers@80, layers[4]@84 (elem 56: drm_format@0
        // num_planes@4 object_index[4]@8 offset[4]@24 pitch[4]@40).
        func layer(_ i: Int) -> ExportedPlane {
            let base = 84 + i * 56
            let objectIndex = Int(u32(base + 8))
            return ExportedPlane(
                fourcc: u32(base),
                modifier: u64(16 + objectIndex * 16 + 8),
                fd: Int32(bitPattern: u32(16 + objectIndex * 16)),
                offset: u32(base + 24),
                pitch: u32(base + 40)
            )
        }
        guard u32(80) >= 2 else {
            throw EyeVaapiError(
                "expected 2 exported layers, got \(u32(80))")
        }
        return (layer(0), layer(1))
    }

    /// The 4:4:4 variant: a packed AYUV surface exports as one layer.
    public func exportSurfacePacked(
        _ id: VASurfaceID
    ) throws -> ExportedPlane {
        let descriptor = UnsafeMutableRawPointer.allocate(
            byteCount: 512, alignment: 8)
        defer { descriptor.deallocate() }
        descriptor.initializeMemory(
            as: UInt8.self, repeating: 0, count: 512)
        let status = vaExportSurfaceHandle(
            display, id,
            UInt32(VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2),
            UInt32(VA_EXPORT_SURFACE_WRITE_ONLY)
                | UInt32(VA_EXPORT_SURFACE_SEPARATE_LAYERS),
            descriptor
        )
        try check(status, "vaExportSurfaceHandle(\(id))")
        func u32(_ offset: Int) -> UInt32 {
            descriptor.load(fromByteOffset: offset, as: UInt32.self)
        }
        func u64(_ offset: Int) -> UInt64 {
            descriptor.load(fromByteOffset: offset, as: UInt64.self)
        }
        guard u32(80) >= 1 else {
            throw EyeVaapiError(
                "expected 1 exported layer, got \(u32(80))")
        }
        let objectIndex = Int(u32(84 + 8))
        return ExportedPlane(
            fourcc: u32(84),
            modifier: u64(16 + objectIndex * 16 + 8),
            fd: Int32(bitPattern: u32(16 + objectIndex * 16)),
            offset: u32(84 + 24),
            pitch: u32(84 + 40)
        )
    }

    // MARK: The per-frame drive

    /// Encodes one blitted input surface; returns the complete
    /// access unit (Annex-B, packed headers included — the driver
    /// writes them into the coded buffer ahead of the slice data).
    public func encode(
        surface: VASurfaceID, forceIDR: Bool
    ) throws -> (data: [UInt8], keyframe: Bool) {
        let idr = frameIndex == 0 || forceIDR
        if idr { poc = 0 }
        let recon = reconSurfaces[Int(frameIndex % 2)]
        var buffers: [VABufferID] = []
        defer {
            for buffer in buffers { vaDestroyBuffer(display, buffer) }
        }

        if idr {
            buffers.append(try makeSequenceBuffer())
            buffers.append(try makePackedParam(
                type: VAEncPackedHeaderSequence,
                bitLength: try packedParameterSets().count * 8))
            buffers.append(try makePackedData(try packedParameterSets()))
            if bitrateBitsPerSecond > 0 {
                buffers.append(try makeRateControlBuffer(
                    capBitsPerSecond: currentRate))
                buffers.append(try makeHRDBuffer(
                    capBitsPerSecond: currentRate))
                buffers.append(try makeFrameRateBuffer())
            }
        } else if let rate = pendingRate, bitrateBitsPerSecond > 0 {
            currentRate = rate
            buffers.append(try makeRateControlBuffer(
                capBitsPerSecond: rate))
            buffers.append(try makeHRDBuffer(capBitsPerSecond: rate))
            pendingRate = nil
        }

        buffers.append(try makePictureBuffer(
            idr: idr, recon: recon))
        let sliceNal = idr
            ? HevcSliceHeader.idr(qpDelta: 0)
            : HevcSliceHeader.trailGPB(pocLsb: poc, qpDelta: 0)
        let packedSlice = [0, 0, 0, 1] + sliceNal
        buffers.append(try makePackedParam(
            type: VAEncPackedHeaderSlice,
            bitLength: packedSlice.count * 8))
        buffers.append(try makePackedData(packedSlice))
        buffers.append(try makeSliceBuffer(idr: idr))

        try check(vaBeginPicture(display, contextID, surface),
                  "vaBeginPicture")
        var renderList = buffers
        try check(vaRenderPicture(
            display, contextID, &renderList, Int32(renderList.count)
        ), "vaRenderPicture")
        try check(vaEndPicture(display, contextID), "vaEndPicture")
        try check(vaSyncSurface(display, surface), "vaSyncSurface")

        // Coded readback: a VACodedBufferSegment chain.
        var mapped: UnsafeMutableRawPointer?
        try check(vaMapBuffer(display, codedBuffer, &mapped),
                  "vaMapBuffer(coded)")
        var out: [UInt8] = []
        var segment = mapped?.assumingMemoryBound(
            to: VACodedBufferSegment.self)
        while let s = segment {
            let seg = s.pointee
            if let buf = seg.buf, seg.size > 0 {
                out.append(contentsOf: UnsafeRawBufferPointer(
                    start: buf, count: Int(seg.size)))
            }
            segment = seg.next?.assumingMemoryBound(
                to: VACodedBufferSegment.self)
        }
        _ = vaUnmapBuffer(display, codedBuffer)

        previousRecon = recon
        previousPoc = poc
        poc &+= 1
        frameIndex += 1
        return (out, idr)
    }

    // MARK: Buffer builders (vaapi_encode_h265.c's fills, mirrored)

    private func makeBuffer<T>(
        _ type: VABufferType, _ value: inout T, _ what: String
    ) throws -> VABufferID {
        var id = VABufferID(VA_INVALID_ID)
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(vaCreateBuffer(
                display, contextID, type,
                UInt32(MemoryLayout<T>.size), 1, pointer, &id
            ), what)
        }
        return id
    }

    private func makeSequenceBuffer() throws -> VABufferID {
        var seq = VAEncSequenceParameterBufferHEVC()
        seq.general_profile_idc = 1
        seq.general_level_idc = UInt8(recipe.levelIdc)
        seq.general_tier_flag = 0
        seq.intra_period = 0xFFFF_FFFF // infinite GOP
        seq.intra_idr_period = 0xFFFF_FFFF
        seq.ip_period = 1
        seq.bits_per_second = bitrateBitsPerSecond > 0
            ? UInt32(bitrateBitsPerSecond) : 0
        seq.pic_width_in_luma_samples = UInt16(width)
        seq.pic_height_in_luma_samples = UInt16(height)
        seq.seq_fields.bits.chroma_format_idc = chroma444 ? 3 : 1
        seq.seq_fields.bits.amp_enabled_flag = 1
        seq.seq_fields.bits.sample_adaptive_offset_enabled_flag = 1
        seq.seq_fields.bits.sps_temporal_mvp_enabled_flag = 1
        seq.log2_min_luma_coding_block_size_minus3 = 0
        seq.log2_diff_max_min_luma_coding_block_size = 3
        seq.log2_min_transform_block_size_minus2 = 0
        seq.log2_diff_max_min_transform_block_size = 3
        seq.max_transform_hierarchy_depth_inter = 2
        seq.max_transform_hierarchy_depth_intra = 2
        seq.vui_parameters_present_flag = 0 // the packed SPS carries VUI
        return try makeBuffer(
            VAEncSequenceParameterBufferType, &seq, "seq buffer")
    }

    private func makePictureBuffer(
        idr: Bool, recon: VASurfaceID
    ) throws -> VABufferID {
        var pic = VAEncPictureParameterBufferHEVC()
        pic.decoded_curr_pic = VAPictureHEVC(
            picture_id: recon, pic_order_cnt: Int32(poc),
            flags: 0, va_reserved: (0, 0, 0, 0))
        let invalid = VAPictureHEVC(
            picture_id: VASurfaceID(VA_INVALID_ID), pic_order_cnt: 0,
            flags: UInt32(VA_PICTURE_HEVC_INVALID),
            va_reserved: (0, 0, 0, 0))
        withUnsafeMutableBytes(of: &pic.reference_frames) { raw in
            let refs = raw.bindMemory(to: VAPictureHEVC.self)
            for i in 0..<refs.count { refs[i] = invalid }
            if !idr {
                refs[0] = VAPictureHEVC(
                    picture_id: previousRecon,
                    pic_order_cnt: Int32(previousPoc),
                    flags: 0, va_reserved: (0, 0, 0, 0))
            }
        }
        pic.coded_buf = codedBuffer
        pic.collocated_ref_pic_index = 0 // tmvp on
        pic.last_picture = 0
        pic.pic_init_qp = UInt8(recipe.initialQP)
        if let depth = recipe.cuQpDeltaDepth {
            pic.diff_cu_qp_delta_depth = UInt8(depth)
            pic.pic_fields.bits.cu_qp_delta_enabled_flag = 1
        }
        pic.log2_parallel_merge_level_minus2 = 0
        pic.nal_unit_type = idr ? 19 : 1 // IDR_W_RADL / TRAIL_R
        pic.pic_fields.bits.idr_pic_flag = idr ? 1 : 0
        pic.pic_fields.bits.coding_type = idr ? 1 : 2 // I / P (GPB at slice)
        pic.pic_fields.bits.reference_pic_flag = 1
        pic.pic_fields.bits.transform_skip_enabled_flag = 1
        pic.pic_fields.bits.pps_loop_filter_across_slices_enabled_flag = 1
        return try makeBuffer(
            VAEncPictureParameterBufferType, &pic, "pic buffer")
    }

    private func makeSliceBuffer(idr: Bool) throws -> VABufferID {
        var slice = VAEncSliceParameterBufferHEVC()
        let ctusX = (Int(width) + 63) / 64
        let ctusY = (Int(height) + 63) / 64
        slice.slice_segment_address = 0
        slice.num_ctu_in_slice = UInt32(ctusX * ctusY)
        slice.slice_type = idr ? 2 : 0 // I / B (GPB)
        slice.slice_pic_parameter_set_id = 0
        slice.max_num_merge_cand = 5
        slice.slice_qp_delta = 0
        let invalid = VAPictureHEVC(
            picture_id: VASurfaceID(VA_INVALID_ID), pic_order_cnt: 0,
            flags: UInt32(VA_PICTURE_HEVC_INVALID),
            va_reserved: (0, 0, 0, 0))
        let reference = VAPictureHEVC(
            picture_id: previousRecon, pic_order_cnt: Int32(previousPoc),
            flags: 0, va_reserved: (0, 0, 0, 0))
        withUnsafeMutableBytes(of: &slice.ref_pic_list0) { raw in
            let refs = raw.bindMemory(to: VAPictureHEVC.self)
            for i in 0..<refs.count { refs[i] = invalid }
            if !idr { refs[0] = reference }
        }
        withUnsafeMutableBytes(of: &slice.ref_pic_list1) { raw in
            let refs = raw.bindMemory(to: VAPictureHEVC.self)
            for i in 0..<refs.count { refs[i] = invalid }
            if !idr { refs[0] = reference } // GPB: L1 == L0
        }
        slice.slice_fields.bits.last_slice_of_pic_flag = 1
        slice.slice_fields.bits.slice_temporal_mvp_enabled_flag =
            idr ? 0 : 1
        slice.slice_fields.bits.slice_sao_luma_flag = 1
        slice.slice_fields.bits.slice_sao_chroma_flag = 1
        slice.slice_fields.bits.collocated_from_l0_flag = 1
        return try makeBuffer(
            VAEncSliceParameterBufferType, &slice, "slice buffer")
    }

    /// VPS ‖ SPS ‖ PPS, Annex-B with 4-byte start codes — the pens'
    /// bytes, packed as one VAEncPackedHeaderSequence blob.
    private func packedParameterSets() throws -> [UInt8] {
        let start: [UInt8] = [0, 0, 0, 1]
        return start + HevcParameterSets.vps(recipe)
            + start + HevcParameterSets.sps(recipe)
            + start + HevcParameterSets.pps(recipe)
    }

    private func makePackedParam(
        type: VAEncPackedHeaderType, bitLength: Int
    ) throws -> VABufferID {
        var param = VAEncPackedHeaderParameterBuffer(
            type: UInt32(type.rawValue),
            bit_length: UInt32(bitLength),
            has_emulation_bytes: 1,
            va_reserved: (0, 0, 0, 0))
        return try makeBuffer(
            VAEncPackedHeaderParameterBufferType, &param,
            "packed param")
    }

    private func makePackedData(_ data: [UInt8]) throws -> VABufferID {
        var id = VABufferID(VA_INVALID_ID)
        var bytes = data
        try bytes.withUnsafeMutableBytes { raw in
            try check(vaCreateBuffer(
                display, contextID, VAEncPackedHeaderDataBufferType,
                UInt32(raw.count), 1, raw.baseAddress, &id
            ), "packed data")
        }
        return id
    }

    /// The RC misc buffer: header + VAEncMiscParameterRateControl,
    /// assembled as raw bytes (the C flexible-array tail does not
    /// import). 70%-of-cap target — the E1 envelope.
    /// The VBV the libav seat proved out (E1's envelope, byte-for-
    /// byte): target 70% of cap, buffer FOUR FRAMES of cap — a ~66 ms
    /// window at 60 fps. Without the matching HRD buffer the iHD
    /// driver's VBR math degenerates and inter-frame quality collapses
    /// (the yellow-smear artifact — caught by eyeball, not by decode).
    private func vbvBufferBits(capBitsPerSecond: Int64) -> Int64 {
        capBitsPerSecond * 4 / Int64(fps)
    }

    private func makeRateControlBuffer(
        capBitsPerSecond: Int64
    ) throws -> VABufferID {
        var rc = VAEncMiscParameterRateControl()
        rc.bits_per_second = UInt32(capBitsPerSecond)
        rc.target_percentage = 70
        rc.window_size = UInt32(
            vbvBufferBits(capBitsPerSecond: capBitsPerSecond) * 1000
                / capBitsPerSecond)
        // 2 = macroblock-level RC explicitly OFF — ffmpeg sends this
        // whenever blbrc is not requested; 0 leaves it driver-chosen.
        rc.rc_flags.bits.mb_rate_control = 2
        return try makeMiscBuffer(
            VAEncMiscParameterTypeRateControl, &rc, "rc misc")
    }

    private func makeHRDBuffer(
        capBitsPerSecond: Int64
    ) throws -> VABufferID {
        let buffer = vbvBufferBits(capBitsPerSecond: capBitsPerSecond)
        var hrd = VAEncMiscParameterHRD()
        hrd.buffer_size = UInt32(buffer)
        hrd.initial_buffer_fullness = UInt32(buffer * 3 / 4)
        return try makeMiscBuffer(
            VAEncMiscParameterTypeHRD, &hrd, "hrd misc")
    }

    private func makeFrameRateBuffer() throws -> VABufferID {
        var framerate = VAEncMiscParameterFrameRate()
        framerate.framerate = UInt32(fps) | (1 << 16)
        return try makeMiscBuffer(
            VAEncMiscParameterTypeFrameRate, &framerate, "framerate misc")
    }

    private func makeMiscBuffer<T>(
        _ type: VAEncMiscParameterType, _ value: inout T,
        _ what: String
    ) throws -> VABufferID {
        // VAEncMiscParameterBuffer { type; uint32 data[]; } — build
        // the blob by hand: 4-byte type + padding + payload (the
        // header struct is 4 bytes but the payload aligns to it
        // directly per libva's own usage).
        let headerSize = MemoryLayout<VAEncMiscParameterBuffer>.size
        var blob = [UInt8](
            repeating: 0, count: headerSize + MemoryLayout<T>.size)
        blob.withUnsafeMutableBytes { raw in
            raw.storeBytes(
                of: UInt32(type.rawValue), toByteOffset: 0,
                as: UInt32.self)
            withUnsafeBytes(of: value) { payload in
                raw.baseAddress!.advanced(by: headerSize)
                    .copyMemory(
                        from: payload.baseAddress!,
                        byteCount: payload.count)
            }
        }
        var id = VABufferID(VA_INVALID_ID)
        try blob.withUnsafeMutableBytes { raw in
            try check(vaCreateBuffer(
                display, contextID, VAEncMiscParameterBufferType,
                UInt32(raw.count), 1, raw.baseAddress, &id
            ), what)
        }
        return id
    }
}

#endif
