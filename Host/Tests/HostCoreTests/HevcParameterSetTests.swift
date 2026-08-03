import XCTest
import HostCore
import LyteCore

// THE GATE (E6b milestone 1): the Swift pen writes libavcodec's
// headers byte-for-byte. The oracle bytes below are a REAL capture —
// lyte-eye on pup (hevc_vaapi, iHD on the Arc, 2048×1280@60, QP 24)
// — split into NALs and decoded field-by-field (the session's
// hevc-header-dump); the serializer mirrors every field name-by-name
// and must reproduce the exact bytes. Plus the bit-writer laws the
// serializer stands on: Exp-Golomb anchors and emulation prevention.

final class HevcParameterSetTests: XCTestCase {

    private static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var iterator = s.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            out.append(UInt8(String([high, low]), radix: 16)!)
        }
        return out
    }

    /// The oracle: lyte-eye capture on pup, 2026-08-01 (Annex-B
    /// start codes stripped; the capture used 4-byte start codes, so
    /// the leading 00 of each next start code is NOT part of these).
    private static let oracleVPS = hex(
        "40010c01ffff016000000300b000000300000300962c0c0000030004"
        + "00000300f3a0")
    private static let oracleSPS = hex(
        "420101016000000300b00000030000030096a00100200501624b9246"
        + "daa6a020202080000003008000001e6be10082")
    private static let oraclePPS = hex("4401c065581120")

    // MARK: The oracle — byte-exact against hevc_vaapi's own pen

    func testHeadersMatchTheOracleByteExact() {
        let recipe = HevcHeaderRecipe(width: 2048, height: 1280)
        XCTAssertEqual(HevcParameterSets.vps(recipe), Self.oracleVPS,
                       "VPS must be byte-identical to libavcodec's")
        XCTAssertEqual(HevcParameterSets.sps(recipe), Self.oracleSPS,
                       "SPS must be byte-identical to libavcodec's")
        XCTAssertEqual(HevcParameterSets.pps(recipe), Self.oraclePPS,
                       "PPS must be byte-identical to libavcodec's")
    }

    /// The brc-mode PPS, pinned against a fresh hevc_vaapi VBR capture
    /// (vis-libav-vbr, 2026-08-01): baseline QP 30 and cu_qp_delta at
    /// depth 3 — the driver writes per-CU deltas into brc slice data,
    /// and a PPS that doesn't declare them corrupts every decode
    /// (sharp text, yellow-washed flats; the eyeball bug of 2026-08-01).
    func testBrcPpsMatchesTheOracleByteExact() {
        let recipe = HevcHeaderRecipe(
            width: 2048, height: 1280, initialQP: 30, cuQpDeltaDepth: 3)
        XCTAssertEqual(HevcParameterSets.pps(recipe),
                       Self.hex("4401c06219302240"),
                       "brc PPS must be byte-identical to libavcodec's")
    }

    /// The slice pens against the same capture: the oracle's IDR
    /// slice header is exactly 26 01 AF A0 (decoded bit-by-bit:
    /// I-slice, SAO on, qp_delta 0, loop-filter-across off), and its
    /// first two TRAIL_R headers are 02 01 E0 02 5F 9D / E0 04 5F 9D
    /// — GPB B-slices (the iHD p_to_gpb dialect confirmed in
    /// vaapi_encode_h265.c: slice_type B, collocated_from_l0 1,
    /// mvd_l1_zero 0, merge cand 5), POC 1 then 2.
    func testSliceHeadersMatchTheOracleByteExact() {
        XCTAssertEqual(HevcSliceHeader.idr(qpDelta: 0),
                       [0x26, 0x01, 0xAF, 0xA0])
        XCTAssertEqual(HevcSliceHeader.trailGPB(pocLsb: 1, qpDelta: 0),
                       [0x02, 0x01, 0xE0, 0x02, 0x5F, 0x9D])
        XCTAssertEqual(HevcSliceHeader.trailGPB(pocLsb: 2, qpDelta: 0),
                       [0x02, 0x01, 0xE0, 0x04, 0x5F, 0x9D])
        // The variable fields reach the bytes.
        XCTAssertNotEqual(HevcSliceHeader.idr(qpDelta: 2),
                          HevcSliceHeader.idr(qpDelta: 0))
        XCTAssertNotEqual(
            HevcSliceHeader.trailGPB(pocLsb: 3, qpDelta: 0),
            HevcSliceHeader.trailGPB(pocLsb: 2, qpDelta: 0)
        )
        // POC wraps at the SPS's 12-bit law.
        XCTAssertEqual(
            HevcSliceHeader.trailGPB(pocLsb: 4096 + 2, qpDelta: 0),
            HevcSliceHeader.trailGPB(pocLsb: 2, qpDelta: 0)
        )
    }

    /// The recipe's variable fields actually move their bytes — a
    /// serializer that ignores its inputs would still pass the
    /// oracle pin.
    func testRecipeFieldsReachTheBytes() {
        let base = HevcHeaderRecipe(width: 2048, height: 1280)
        var other = base
        other.width = 1920; other.height = 1080
        XCTAssertNotEqual(HevcParameterSets.sps(other),
                          HevcParameterSets.sps(base))
        var fps = base
        fps.fpsNumerator = 120
        XCTAssertNotEqual(HevcParameterSets.vps(fps),
                          HevcParameterSets.vps(base))
        XCTAssertNotEqual(HevcParameterSets.sps(fps),
                          HevcParameterSets.sps(base))
        var qp = base
        qp.initialQP = 30
        XCTAssertNotEqual(HevcParameterSets.pps(qp),
                          HevcParameterSets.pps(base))
        XCTAssertEqual(HevcParameterSets.sps(qp),
                       HevcParameterSets.sps(base),
                       "QP is PPS business alone")
    }

    // MARK: Rext Main 4:4:4 (the Best tier) — field-verified

    /// Walks the Rext SPS field-by-field: profile_idc 4, the §A.3.5
    /// "Main 4:4:4" constraint row, chroma_format_idc 3 with joint
    /// colour planes, and the untouched geometry.
    func testRextSpsFieldsAreTheMain444Row() {
        let recipe = HevcHeaderRecipe(
            width: 2048, height: 1280, chroma444: true)
        var r = HevcBitReader(nal: HevcParameterSets.sps(recipe))
        _ = r.read(bits: 4)!  // sps_video_parameter_set_id
        _ = r.read(bits: 3)!  // sps_max_sub_layers_minus1
        _ = r.read(bits: 1)!  // sps_temporal_id_nesting_flag
        XCTAssertEqual(r.read(bits: 2)!, 0, "general_profile_space")
        XCTAssertEqual(r.read(bits: 1)!, 0, "general_tier_flag")
        XCTAssertEqual(r.read(bits: 5)!, 4, "general_profile_idc = Rext")
        XCTAssertEqual(r.read(bits: 32)!, 0x0800_0000, "compat: profile 4 only")
        XCTAssertEqual(r.read(bits: 1)!, 1, "progressive_source")
        XCTAssertEqual(r.read(bits: 1)!, 0, "interlaced_source")
        XCTAssertEqual(r.read(bits: 1)!, 1, "non_packed")
        XCTAssertEqual(r.read(bits: 1)!, 1, "frame_only")
        XCTAssertEqual(r.read(bits: 1)!, 1, "max_12bit")
        XCTAssertEqual(r.read(bits: 1)!, 1, "max_10bit")
        XCTAssertEqual(r.read(bits: 1)!, 1, "max_8bit")
        XCTAssertEqual(r.read(bits: 1)!, 0, "max_422chroma")
        XCTAssertEqual(r.read(bits: 1)!, 0, "max_420chroma")
        XCTAssertEqual(r.read(bits: 1)!, 0, "max_monochrome")
        XCTAssertEqual(r.read(bits: 1)!, 0, "intra_only")
        XCTAssertEqual(r.read(bits: 1)!, 0, "one_picture_only")
        XCTAssertEqual(r.read(bits: 1)!, 1, "lower_bit_rate")
        XCTAssertEqual(r.read(bits: 32)!, 0, "reserved_zero_34 high")
        XCTAssertEqual(r.read(bits: 2)!, 0, "reserved_zero_34 low")
        XCTAssertEqual(r.read(bits: 1)!, 0, "reserved_zero_bit")
        XCTAssertEqual(r.read(bits: 8)!, 150, "level_idc = L5.0")
        XCTAssertEqual(r.readUe()!, 0, "sps_seq_parameter_set_id")
        XCTAssertEqual(r.readUe()!, 3, "chroma_format_idc = 4:4:4")
        XCTAssertEqual(r.read(bits: 1)!, 0, "separate_colour_plane_flag")
        XCTAssertEqual(r.readUe()!, 2048, "pic_width_in_luma_samples")
        XCTAssertEqual(r.readUe()!, 1280, "pic_height_in_luma_samples")
        XCTAssertEqual(r.read(bits: 1)!, 0, "conformance_window_flag")
        XCTAssertEqual(r.readUe()!, 0, "bit_depth_luma_minus8")
        XCTAssertEqual(r.readUe()!, 0, "bit_depth_chroma_minus8")
    }

    /// The Rext VPS carries the same profile row (the PTL is shared
    /// serializer code, but the pin proves the VPS actually calls it
    /// with the Rext recipe).
    func testRextVpsCarriesTheRextProfile() {
        let recipe = HevcHeaderRecipe(
            width: 2048, height: 1280, chroma444: true)
        var r = HevcBitReader(nal: HevcParameterSets.vps(recipe))
        _ = r.read(bits: 4)!; _ = r.read(bits: 1)!; _ = r.read(bits: 1)!  // vps ids/flags
        _ = r.read(bits: 6)!; _ = r.read(bits: 3)!; _ = r.read(bits: 1)!
        XCTAssertEqual(r.read(bits: 16)!, 0xFFFF, "vps_reserved_0xffff")
        XCTAssertEqual(r.read(bits: 2)!, 0, "profile_space")
        XCTAssertEqual(r.read(bits: 1)!, 0, "tier")
        XCTAssertEqual(r.read(bits: 5)!, 4, "profile_idc = Rext")
    }

    /// The 4:2:0 dialect is UNTOUCHED by the Rext branch: the oracle
    /// bytes still reproduce exactly with chroma444 defaulted false.
    func testRextBranchLeaves420OracleUntouched() {
        let recipe = HevcHeaderRecipe(width: 2048, height: 1280)
        XCTAssertEqual(HevcParameterSets.vps(recipe), Self.oracleVPS)
        XCTAssertEqual(HevcParameterSets.sps(recipe), Self.oracleSPS)
        XCTAssertEqual(HevcParameterSets.pps(recipe), Self.oraclePPS)
        // And the PPS is chroma-agnostic at these settings: 8-bit
        // 4:4:4 needs no pps_range_extension fields.
        var rext = recipe
        rext.chroma444 = true
        XCTAssertEqual(HevcParameterSets.pps(rext),
                       HevcParameterSets.pps(recipe),
                       "PPS bytes identical across chroma at 8-bit")
    }
}
