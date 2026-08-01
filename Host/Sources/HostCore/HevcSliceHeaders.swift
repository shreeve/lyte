// E6b: the slice-segment-header pen (§7.3.6.1) — the second and last
// thing libavcodec writes on the VAAPI path that the native encoder
// must write itself (iHD consumes VPS/SPS/PPS and slice headers as
// app-packed bytes; slice DATA is the engine's).
//
// SCOPE: the iHD/Arc dialect the parameter-set pen fixed, plus the
// driver's GPB quirk mirrored from vaapi_encode_h265.c (p_to_gpb):
// every inter frame is a B slice whose two lists both point at the
// previous frame — slice_type 0, collocated_from_l0 = 1,
// mvd_l1_zero = 0, no override, merge cand 5, SAO on, and the
// slice-level loop-filter-across flag OFF (the zero-init ffmpeg
// never touches). Oracle-pinned in HevcParameterSetTests against a
// real capture's IDR and TRAIL_R headers, decoded bit-by-bit.

public enum HevcSliceHeader {

    /// The opening IDR_W_RADL (NAL type 19) slice-segment header.
    /// `qpDelta` is slice QP − PPS init_qp (CQP: 0).
    public static func idr(qpDelta: Int32) -> [UInt8] {
        var w = HevcBitWriter()
        w.u(1, 1)      // first_slice_segment_in_pic_flag
        w.u(0, 1)      // no_output_of_prior_pics_flag
        w.ue(0)        // slice_pic_parameter_set_id
        w.ue(2)        // slice_type = I
        w.u(1, 1)      // slice_sao_luma_flag
        w.u(1, 1)      // slice_sao_chroma_flag
        w.se(qpDelta)  // slice_qp_delta
        w.u(0, 1)      // slice_loop_filter_across_slices_enabled_flag
        w.rbspTrailingBits() // byte_alignment: one, then zeros
        return HevcBitWriter.nal(type: 19, rbsp: w.rbsp)
    }

    /// A GPB inter frame (NAL type 1, TRAIL_R): B slice, both lists
    /// = the previous frame (the iHD p_to_gpb dialect). `pocLsb` is
    /// the picture order count's low 12 bits (log2_max_poc_lsb = 12,
    /// the SPS's law); IDR resets it to 0 and each frame adds one.
    public static func trailGPB(
        pocLsb: UInt32, qpDelta: Int32
    ) -> [UInt8] {
        var w = HevcBitWriter()
        w.u(1, 1)              // first_slice_segment_in_pic_flag
        w.ue(0)                // slice_pic_parameter_set_id
        w.ue(0)                // slice_type = B (GPB)
        w.u(pocLsb & 0xFFF, 12) // slice_pic_order_cnt_lsb
        w.u(0, 1)              // short_term_ref_pic_set_sps_flag
        // st_ref_pic_set(0), inline: exactly the previous picture.
        w.ue(1)                // num_negative_pics
        w.ue(0)                // num_positive_pics
        w.ue(0)                // delta_poc_s0_minus1[0]
        w.u(1, 1)              // used_by_curr_pic_s0_flag[0]
        w.u(1, 1)              // slice_temporal_mvp_enabled_flag
        w.u(1, 1)              // slice_sao_luma_flag
        w.u(1, 1)              // slice_sao_chroma_flag
        w.u(0, 1)              // num_ref_idx_active_override_flag
        w.u(0, 1)              // mvd_l1_zero_flag
        w.u(1, 1)              // collocated_from_l0_flag
        w.ue(0)                // five_minus_max_num_merge_cand (5)
        w.se(qpDelta)          // slice_qp_delta
        w.u(0, 1)              // slice_loop_filter_across_slices_enabled_flag
        w.rbspTrailingBits()   // byte_alignment
        return HevcBitWriter.nal(type: 1, rbsp: w.rbsp)
    }
}
