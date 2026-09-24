import XCTest
import HostCore
import LyteCore

// The Swift pen writes libavcodec's headers byte for byte. The oracle
// bytes are hevc_vaapi's own output (iHD, 2048×1280@60, QP 24), split
// into NALs; the serializer mirrors every field by its spec name and
// must reproduce them exactly.

final class HevcParameterSetTests: XCTestCase {

    private static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var iterator = s.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            out.append(UInt8(String([high, low]), radix: 16)!)
        }
        return out
    }

    /// The oracle NALs, Annex-B start codes stripped (the capture used
    /// 4-byte start codes, so the leading 00 of each next start code is
    /// not part of these).
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

    /// The rate-controlled PPS against hevc_vaapi's VBR output: baseline
    /// QP 30 and cu_qp_delta at depth 3 — the driver writes per-CU deltas
    /// into rate-controlled slice data, and a PPS that does not declare
    /// them corrupts every decode.
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

    // MARK: Geometry and level for any display size

    /// The SPS fields up to the conformance window, read back.
    private struct Geometry: Equatable {
        var levelIdc: UInt32
        var codedWidth: UInt32
        var codedHeight: UInt32
        /// left, right, top, bottom in chroma units; nil when absent.
        var window: [UInt32]?
    }

    private func geometry(_ recipe: HevcHeaderRecipe) -> Geometry? {
        var r = HevcBitReader(nal: HevcParameterSets.sps(recipe))
        guard r.skip(bits: 4 + 3 + 1 + 2 + 1 + 5 + 32 + 4 + 43 + 1),
              let level = r.read(bits: 8),
              r.readUe() != nil,
              let chroma = r.readUe(),
              chroma != 3 || r.skip(bits: 1),
              let width = r.readUe(), let height = r.readUe(),
              let flag = r.read(bits: 1)
        else { return nil }
        var window: [UInt32]?
        if flag == 1 {
            window = (0..<4).compactMap { _ in r.readUe() }
        }
        return Geometry(levelIdc: level, codedWidth: width,
                        codedHeight: height, window: window)
    }

    /// A display size off the 8-sample coding block is coded padded and
    /// cropped back by the conformance window (chroma units: halved at
    /// 4:2:0); a size on it carries no window, as in the oracle.
    func testSizesOffTheCodingBlockCarryAConformanceWindow() {
        let cases: [(UInt32, UInt32, Bool, Geometry)] = [
            (1366, 768, false, Geometry(
                levelIdc: 120, codedWidth: 1368, codedHeight: 768,
                window: [0, 1, 0, 0])),
            (1600, 900, false, Geometry(
                levelIdc: 123, codedWidth: 1600, codedHeight: 904,
                window: [0, 0, 0, 2])),
            (1366, 768, true, Geometry(
                levelIdc: 120, codedWidth: 1368, codedHeight: 768,
                window: [0, 2, 0, 0])),
            (1440, 900, true, Geometry(
                levelIdc: 123, codedWidth: 1440, codedHeight: 904,
                window: [0, 0, 0, 4])),
            (2048, 1280, false, Geometry(
                levelIdc: 150, codedWidth: 2048, codedHeight: 1280,
                window: nil)),
        ]
        for (width, height, chroma444, expected) in cases {
            let recipe = HevcHeaderRecipe(
                width: width, height: height, chroma444: chroma444)
            XCTAssertEqual(geometry(recipe), expected,
                           "\(width)×\(height) 4:4:4 \(chroma444)")
            XCTAssertEqual(recipe.codedWidth, expected.codedWidth)
            XCTAssertEqual(recipe.codedHeight, expected.codedHeight)
        }
    }

    /// general_level_idc is the lowest level whose picture size and luma
    /// sample rate cover the stream — 4K60 needs 5.1, 1080p60 fits 4.1 —
    /// and the VPS carries the same level as the SPS.
    func testLevelFollowsPictureSizeAndFrameRate() {
        let cases: [(UInt32, UInt32, UInt32, UInt32)] = [
            (2048, 1280, 60, 150),
            (1920, 1080, 60, 123),
            (1920, 1080, 30, 120),
            (1280, 720, 60, 120),
            (1366, 768, 60, 120),
            (3840, 2160, 30, 150),
            (3840, 2160, 60, 153),
            (3840, 2160, 120, 156),
            (7680, 4320, 60, 183),
            (8448, 1024, 30, 180),
        ]
        for (width, height, fps, level) in cases {
            let recipe = HevcHeaderRecipe(
                width: width, height: height, fpsNumerator: UInt32(fps))
            XCTAssertEqual(recipe.levelIdc, level, "\(width)×\(height)@\(fps)")
            XCTAssertEqual(geometry(recipe)?.levelIdc, level)
            var vps = HevcBitReader(nal: HevcParameterSets.vps(recipe))
            XCTAssertTrue(vps.skip(bits: 4 + 1 + 1 + 6 + 3 + 1 + 16
                                   + 2 + 1 + 5 + 32 + 4 + 43 + 1))
            XCTAssertEqual(vps.read(bits: 8), level)
        }
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

    /// The PPS is chroma-agnostic at 8 bits: 4:4:4 needs no
    /// pps_range_extension fields.
    func testPpsIsIdenticalAcrossChromaAtEightBits() {
        let recipe = HevcHeaderRecipe(width: 2048, height: 1280)
        var rext = recipe
        rext.chroma444 = true
        XCTAssertEqual(HevcParameterSets.pps(rext),
                       HevcParameterSets.pps(recipe),
                       "PPS bytes identical across chroma at 8-bit")
    }
}
