// E6b: the H.265 VPS/SPS/PPS serializer — the "real project" of
// encoder independence on the VAAPI path (direct-eye plan E6b).
// libavcodec's one irreplaceable service to the eye was writing
// these headers; this file writes them instead, byte-identical to
// what hevc_vaapi emits for the Arc dialect (proven by the pinned
// oracle in HevcParameterSetTests — a real capture's headers,
// decoded field-by-field and mirrored here name-by-name).
//
// SCOPE: this is the iHD/Arc ENCODE dialect — Main profile 8-bit
// 4:2:0, or (the Best tier, recipe.chroma444) Rext Main 4:4:4 8-bit
// — one temporal layer, IPPP with one reference, CTB 64, no
// tiles/PCM/scaling lists — not a general H.265 header library.
// NVENC writes its own headers (E6a); this pen serves VAAPI alone.

import LyteCore

/// What actually varies between sessions. Everything else is the
/// dialect, fixed in the serializers below with the field names the
/// spec uses (§7.3.2) so a byte-diff dispute reads straight back to
/// the standard.
public struct HevcHeaderRecipe: Hashable, Sendable {
    public var width: UInt32
    public var height: UInt32
    /// VUI/VPS timing: time_scale / num_units_in_tick = frame rate.
    public var fpsNumerator: UInt32
    public var fpsDenominator: UInt32
    /// PPS init_qp (26 + init_qp_minus26).
    public var initialQP: Int32
    /// general_level_idc (30 × the level number): 150 = L5.0, which
    /// covers 2048×1280@60 with margin.
    public var levelIdc: UInt32
    /// PPS cu_qp_delta: nil = disabled (CQP — the slice data carries
    /// no per-CU QP syntax). Under brc rate control the driver WRITES
    /// per-CU deltas into the slice data, so the PPS must declare them
    /// or the decoder misparses every coefficient after the first
    /// delta (sharp-text-yellow-wash corruption, caught by eyeball).
    /// The value is diff_cu_qp_delta_depth; the driver dialect uses
    /// log2_diff_max_min_luma_coding_block_size (= 3, 8x8 granularity).
    public var cuQpDeltaDepth: UInt32?
    /// The Best tier (Rext): full-chroma Main 4:4:4, 8-bit. False =
    /// the Main 4:2:0 dialect every prior capture pinned. Probed
    /// 2026-08-03: the Arc encodes it (VAProfileHEVCMain444
    /// EncSlice) and the M5 hardware-decodes it (444v, production
    /// render path).
    public var chroma444: Bool

    public init(
        width: UInt32, height: UInt32,
        fpsNumerator: UInt32 = 60, fpsDenominator: UInt32 = 1,
        initialQP: Int32 = 24, levelIdc: UInt32 = 150,
        cuQpDeltaDepth: UInt32? = nil,
        chroma444: Bool = false
    ) {
        self.width = width
        self.height = height
        self.fpsNumerator = fpsNumerator
        self.fpsDenominator = fpsDenominator
        self.initialQP = initialQP
        self.levelIdc = levelIdc
        self.cuQpDeltaDepth = cuQpDeltaDepth
        self.chroma444 = chroma444
    }
}

public enum HevcParameterSets {

    // MARK: profile_tier_level (§7.3.3) — Main or Rext Main 4:4:4,
    // progressive, frame-only, one layer

    private static func profileTierLevel(
        _ w: inout HevcBitWriter, _ recipe: HevcHeaderRecipe
    ) {
        w.u(0, 2)  // general_profile_space
        w.u(0, 1)  // general_tier_flag (Main tier)
        if recipe.chroma444 {
            w.u(4, 5)  // general_profile_idc = Rext
            // Compatibility: profile 4 only — bit 4 of the MSB-first
            // 32 (a Rext stream is nobody else's business).
            w.u(0x0800_0000, 32)
        } else {
            w.u(1, 5)  // general_profile_idc = Main
            // Compatibility: profiles 1 (Main) and 2 (Main 10
            // decoders accept Main) — bits 1 and 2 of the MSB-first
            // 32.
            w.u(0x6000_0000, 32)
        }
        w.u(1, 1)  // general_progressive_source_flag
        w.u(0, 1)  // general_interlaced_source_flag
        w.u(1, 1)  // general_non_packed_constraint_flag
        w.u(1, 1)  // general_frame_only_constraint_flag
        if recipe.chroma444 {
            // Rext (profile_idc 4): the 43 reserved bits become the
            // constraint flags; these are §A.3.5's "Main 4:4:4" row
            // (8-bit, any chroma, inter allowed, lower bit rate).
            w.u(1, 1)  // general_max_12bit_constraint_flag
            w.u(1, 1)  // general_max_10bit_constraint_flag
            w.u(1, 1)  // general_max_8bit_constraint_flag
            w.u(0, 1)  // general_max_422chroma_constraint_flag
            w.u(0, 1)  // general_max_420chroma_constraint_flag
            w.u(0, 1)  // general_max_monochrome_constraint_flag
            w.u(0, 1)  // general_intra_constraint_flag
            w.u(0, 1)  // general_one_picture_only_constraint_flag
            w.u(1, 1)  // general_lower_bit_rate_constraint_flag
            w.u(0, 32) // general_reserved_zero_34bits (high)
            w.u(0, 2)  // general_reserved_zero_34bits (low)
        } else {
            w.u(0, 32) // general_reserved_zero_43bits (high)
            w.u(0, 11) // general_reserved_zero_43bits (low)
        }
        w.u(0, 1)  // general_reserved_zero_bit / inbld
        w.u(recipe.levelIdc, 8) // general_level_idc
        // sps/vps_max_sub_layers_minus1 == 0: no sub-layer entries.
    }

    // MARK: - VPS (§7.3.2.1)

    public static func vps(_ recipe: HevcHeaderRecipe) -> [UInt8] {
        var w = HevcBitWriter()
        w.u(0, 4)      // vps_video_parameter_set_id
        w.u(1, 1)      // vps_base_layer_internal_flag
        w.u(1, 1)      // vps_base_layer_available_flag
        w.u(0, 6)      // vps_max_layers_minus1
        w.u(0, 3)      // vps_max_sub_layers_minus1
        w.u(1, 1)      // vps_temporal_id_nesting_flag
        w.u(0xFFFF, 16) // vps_reserved_0xffff_16bits
        profileTierLevel(&w, recipe)
        w.u(0, 1)      // vps_sub_layer_ordering_info_present_flag
        w.ue(1)        // vps_max_dec_pic_buffering_minus1[0] (dpb 2)
        w.ue(0)        // vps_max_num_reorder_pics[0] (IPPP: none)
        w.ue(0)        // vps_max_latency_increase_plus1[0]
        w.u(0, 6)      // vps_max_layer_id
        w.ue(0)        // vps_num_layer_sets_minus1
        w.u(1, 1)      // vps_timing_info_present_flag
        w.u(recipe.fpsDenominator, 32) // vps_num_units_in_tick
        w.u(recipe.fpsNumerator, 32)   // vps_time_scale
        w.u(1, 1)      // vps_poc_proportional_to_timing_flag
        w.ue(0)        // vps_num_ticks_poc_diff_one_minus1
        w.ue(0)        // vps_num_hrd_parameters
        w.u(0, 1)      // vps_extension_flag
        w.rbspTrailingBits()
        return HevcBitWriter.nal(type: 32, rbsp: w.rbsp)
    }

    // MARK: - SPS (§7.3.2.2)

    public static func sps(_ recipe: HevcHeaderRecipe) -> [UInt8] {
        var w = HevcBitWriter()
        w.u(0, 4)      // sps_video_parameter_set_id
        w.u(0, 3)      // sps_max_sub_layers_minus1
        w.u(1, 1)      // sps_temporal_id_nesting_flag
        profileTierLevel(&w, recipe)
        w.ue(0)        // sps_seq_parameter_set_id
        if recipe.chroma444 {
            w.ue(3)    // chroma_format_idc = 4:4:4
            w.u(0, 1)  // separate_colour_plane_flag (joint planes)
        } else {
            w.ue(1)    // chroma_format_idc = 4:2:0
        }
        w.ue(recipe.width)  // pic_width_in_luma_samples
        w.ue(recipe.height) // pic_height_in_luma_samples
        // conformance_window_flag: the eye's dimensions are CTB-round
        // already (2048×1280); a recipe needing cropping extends here.
        w.u(0, 1)
        w.ue(0)        // bit_depth_luma_minus8
        w.ue(0)        // bit_depth_chroma_minus8
        w.ue(8)        // log2_max_pic_order_cnt_lsb_minus4 (POC 12 bit)
        w.u(0, 1)      // sps_sub_layer_ordering_info_present_flag
        w.ue(1)        // sps_max_dec_pic_buffering_minus1[0]
        w.ue(0)        // sps_max_num_reorder_pics[0]
        w.ue(0)        // sps_max_latency_increase_plus1[0]
        w.ue(0)        // log2_min_luma_coding_block_size_minus3 (8)
        w.ue(3)        // log2_diff_max_min… (CTB 64)
        w.ue(0)        // log2_min_luma_transform_block_size_minus2 (4)
        w.ue(3)        // log2_diff_max_min… (TB 32)
        w.ue(2)        // max_transform_hierarchy_depth_inter
        w.ue(2)        // max_transform_hierarchy_depth_intra
        w.u(0, 1)      // scaling_list_enabled_flag
        w.u(1, 1)      // amp_enabled_flag
        w.u(1, 1)      // sample_adaptive_offset_enabled_flag
        w.u(0, 1)      // pcm_enabled_flag
        w.ue(0)        // num_short_term_ref_pic_sets (per-slice RPS)
        w.u(0, 1)      // long_term_ref_pics_present_flag
        w.u(1, 1)      // sps_temporal_mvp_enabled_flag
        w.u(0, 1)      // strong_intra_smoothing_enabled_flag
        w.u(1, 1)      // vui_parameters_present_flag
        // — VUI (§E.2.1): the color truth the blit establishes —
        w.u(0, 1)      // aspect_ratio_info_present_flag
        w.u(0, 1)      // overscan_info_present_flag
        w.u(1, 1)      // video_signal_type_present_flag
        w.u(5, 3)      // video_format = unspecified
        w.u(0, 1)      // video_full_range_flag (limited — the blit's law)
        w.u(1, 1)      // colour_description_present_flag
        w.u(1, 8)      // colour_primaries = BT.709
        w.u(1, 8)      // transfer_characteristics = BT.709
        w.u(1, 8)      // matrix_coeffs = BT.709
        w.u(0, 1)      // chroma_loc_info_present_flag
        w.u(0, 1)      // neutral_chroma_indication_flag
        w.u(0, 1)      // field_seq_flag
        w.u(0, 1)      // frame_field_info_present_flag
        w.u(0, 1)      // default_display_window_flag
        w.u(1, 1)      // vui_timing_info_present_flag
        w.u(recipe.fpsDenominator, 32) // vui_num_units_in_tick
        w.u(recipe.fpsNumerator, 32)   // vui_time_scale
        w.u(1, 1)      // vui_poc_proportional_to_timing_flag
        w.ue(0)        // vui_num_ticks_poc_diff_one_minus1
        w.u(0, 1)      // vui_hrd_parameters_present_flag
        w.u(1, 1)      // bitstream_restriction_flag
        w.u(0, 1)      // tiles_fixed_structure_flag
        w.u(1, 1)      // motion_vectors_over_pic_boundaries_flag
        w.u(1, 1)      // restricted_ref_pic_lists_flag
        w.ue(0)        // min_spatial_segmentation_idc
        w.ue(0)        // max_bytes_per_pic_denom
        w.ue(0)        // max_bits_per_min_cu_denom
        w.ue(15)       // log2_max_mv_length_horizontal
        w.ue(15)       // log2_max_mv_length_vertical
        w.u(0, 1)      // sps_extension_present_flag
        w.rbspTrailingBits()
        return HevcBitWriter.nal(type: 33, rbsp: w.rbsp)
    }

    // MARK: - PPS (§7.3.2.3)

    public static func pps(_ recipe: HevcHeaderRecipe) -> [UInt8] {
        var w = HevcBitWriter()
        w.ue(0)        // pps_pic_parameter_set_id
        w.ue(0)        // pps_seq_parameter_set_id
        w.u(0, 1)      // dependent_slice_segments_enabled_flag
        w.u(0, 1)      // output_flag_present_flag
        w.u(0, 3)      // num_extra_slice_header_bits
        w.u(0, 1)      // sign_data_hiding_enabled_flag
        w.u(0, 1)      // cabac_init_present_flag
        w.ue(0)        // num_ref_idx_l0_default_active_minus1
        w.ue(0)        // num_ref_idx_l1_default_active_minus1
        w.se(recipe.initialQP - 26) // init_qp_minus26
        w.u(0, 1)      // constrained_intra_pred_flag
        w.u(1, 1)      // transform_skip_enabled_flag
        if let depth = recipe.cuQpDeltaDepth {
            w.u(1, 1)  // cu_qp_delta_enabled_flag
            w.ue(depth) // diff_cu_qp_delta_depth
        } else {
            w.u(0, 1)  // cu_qp_delta_enabled_flag
        }
        w.se(0)        // pps_cb_qp_offset
        w.se(0)        // pps_cr_qp_offset
        w.u(0, 1)      // pps_slice_chroma_qp_offsets_present_flag
        w.u(0, 1)      // weighted_pred_flag
        w.u(0, 1)      // weighted_bipred_flag
        w.u(0, 1)      // transquant_bypass_enabled_flag
        w.u(0, 1)      // tiles_enabled_flag
        w.u(0, 1)      // entropy_coding_sync_enabled_flag
        w.u(1, 1)      // pps_loop_filter_across_slices_enabled_flag
        w.u(0, 1)      // deblocking_filter_control_present_flag
        w.u(0, 1)      // pps_scaling_list_data_present_flag
        w.u(0, 1)      // lists_modification_present_flag
        w.ue(0)        // log2_parallel_merge_level_minus2
        w.u(0, 1)      // slice_segment_header_extension_present_flag
        w.u(0, 1)      // pps_extension_present_flag
        w.rbspTrailingBits()
        return HevcBitWriter.nal(type: 34, rbsp: w.rbsp)
    }
}
