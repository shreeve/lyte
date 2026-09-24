// The slice-segment-header pen (§7.3.6.1). iHD consumes parameter sets
// and slice headers as app-packed bytes; slice data is the engine's.
//
// Scope: the parameter-set pen's dialect plus the driver's GPB quirk
// (vaapi_encode_h265.c p_to_gpb): every inter frame is a B slice whose
// two lists both point at the previous frame. Oracle-pinned in
// HevcParameterSetTests.

import LyteCore

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

    /// A GPB inter frame (NAL type 1, TRAIL_R): B slice, both lists =
    /// the previous frame. `pocLsb` is the POC's low 12 bits (the SPS's
    /// log2_max_poc_lsb); IDR resets it to 0 and each frame adds one.
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
