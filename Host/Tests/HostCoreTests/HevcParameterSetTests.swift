import XCTest
import HostCore

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

    // MARK: The bit-writer laws

    func testExpGolombAnchors() {
        // ue: 0→1, 1→010, 2→011, 3→00100, 4→00101 (§9.2 table).
        var w = HevcBitWriter()
        w.ue(0); w.ue(1); w.ue(2); w.ue(3); w.ue(4)
        // 1 010 011 00100 00101 → 1010 0110 0100 0010 1(000)
        w.rbspTrailingBits() // appended stop bit lands mid-byte
        XCTAssertEqual(Array(w.rbsp.prefix(2)), [0b1010_0110, 0b0100_0010])

        // se: 1→ue(1), −1→ue(2), 2→ue(3), −2→ue(4) (§9.2.2).
        var s1 = HevcBitWriter(); s1.se(-2); s1.rbspTrailingBits()
        var u4 = HevcBitWriter(); u4.ue(4); u4.rbspTrailingBits()
        XCTAssertEqual(s1.rbsp, u4.rbsp)
        var s2 = HevcBitWriter(); s2.se(1); s2.rbspTrailingBits()
        var u1 = HevcBitWriter(); u1.ue(1); u1.rbspTrailingBits()
        XCTAssertEqual(s2.rbsp, u1.rbsp)
    }

    func testEmulationPrevention() {
        // 00 00 00 → 00 00 03 00; 00 00 01/02/03 likewise; 00 00 04
        // untouched (only x ≤ 3 needs the escape).
        XCTAssertEqual(
            HevcBitWriter.nal(type: 32, rbsp: [0, 0, 0]),
            [0x40, 0x01, 0, 0, 3, 0]
        )
        XCTAssertEqual(
            HevcBitWriter.nal(type: 32, rbsp: [0, 0, 1]),
            [0x40, 0x01, 0, 0, 3, 1]
        )
        XCTAssertEqual(
            HevcBitWriter.nal(type: 32, rbsp: [0, 0, 4]),
            [0x40, 0x01, 0, 0, 4]
        )
        // A run of four zeros escapes once mid-run, then again when
        // the next pair completes: 00 00 03 00 00 03 ….
        XCTAssertEqual(
            HevcBitWriter.nal(type: 32, rbsp: [0, 0, 0, 0, 2]),
            [0x40, 0x01, 0, 0, 3, 0, 0, 3, 2]
        )
        // The escape counter RESETS after inserting (00 00 03 00 00
        // needs a second 03 only after two MORE zeros).
        XCTAssertEqual(
            HevcBitWriter.nal(type: 33, rbsp: [0, 0, 2, 0, 2]),
            [0x42, 0x01, 0, 0, 3, 2, 0, 2]
        )
    }

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

    /// A minimal bit reader: NAL header stripped, emulation
    /// prevention un-escaped, MSB-first u(n) and §9.2 ue(v).
    private struct BitReader {
        private let bytes: [UInt8]
        private var bit = 0
        init(nal: [UInt8]) {
            var rbsp: [UInt8] = []
            var zeros = 0
            for byte in nal.dropFirst(2) {
                if zeros >= 2, byte == 3 { zeros = 0; continue }
                zeros = byte == 0 ? zeros + 1 : 0
                rbsp.append(byte)
            }
            bytes = rbsp
        }
        mutating func u(_ n: Int) -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<n {
                let byte = bytes[bit >> 3]
                value = (value << 1)
                    | UInt32((byte >> (7 - bit % 8)) & 1)
                bit += 1
            }
            return value
        }
        mutating func ue() -> UInt32 {
            var zeros = 0
            while u(1) == 0 { zeros += 1 }
            return zeros == 0 ? 0
                : (1 << zeros) - 1 + u(zeros)
        }
    }

    /// Walks the Rext SPS field-by-field: profile_idc 4, the §A.3.5
    /// "Main 4:4:4" constraint row, chroma_format_idc 3 with joint
    /// colour planes, and the untouched geometry.
    func testRextSpsFieldsAreTheMain444Row() {
        let recipe = HevcHeaderRecipe(
            width: 2048, height: 1280, chroma444: true)
        var r = BitReader(nal: HevcParameterSets.sps(recipe))
        _ = r.u(4)  // sps_video_parameter_set_id
        _ = r.u(3)  // sps_max_sub_layers_minus1
        _ = r.u(1)  // sps_temporal_id_nesting_flag
        XCTAssertEqual(r.u(2), 0, "general_profile_space")
        XCTAssertEqual(r.u(1), 0, "general_tier_flag")
        XCTAssertEqual(r.u(5), 4, "general_profile_idc = Rext")
        XCTAssertEqual(r.u(32), 0x0800_0000, "compat: profile 4 only")
        XCTAssertEqual(r.u(1), 1, "progressive_source")
        XCTAssertEqual(r.u(1), 0, "interlaced_source")
        XCTAssertEqual(r.u(1), 1, "non_packed")
        XCTAssertEqual(r.u(1), 1, "frame_only")
        XCTAssertEqual(r.u(1), 1, "max_12bit")
        XCTAssertEqual(r.u(1), 1, "max_10bit")
        XCTAssertEqual(r.u(1), 1, "max_8bit")
        XCTAssertEqual(r.u(1), 0, "max_422chroma")
        XCTAssertEqual(r.u(1), 0, "max_420chroma")
        XCTAssertEqual(r.u(1), 0, "max_monochrome")
        XCTAssertEqual(r.u(1), 0, "intra_only")
        XCTAssertEqual(r.u(1), 0, "one_picture_only")
        XCTAssertEqual(r.u(1), 1, "lower_bit_rate")
        XCTAssertEqual(r.u(32), 0, "reserved_zero_34 high")
        XCTAssertEqual(r.u(2), 0, "reserved_zero_34 low")
        XCTAssertEqual(r.u(1), 0, "reserved_zero_bit")
        XCTAssertEqual(r.u(8), 150, "level_idc = L5.0")
        XCTAssertEqual(r.ue(), 0, "sps_seq_parameter_set_id")
        XCTAssertEqual(r.ue(), 3, "chroma_format_idc = 4:4:4")
        XCTAssertEqual(r.u(1), 0, "separate_colour_plane_flag")
        XCTAssertEqual(r.ue(), 2048, "pic_width_in_luma_samples")
        XCTAssertEqual(r.ue(), 1280, "pic_height_in_luma_samples")
        XCTAssertEqual(r.u(1), 0, "conformance_window_flag")
        XCTAssertEqual(r.ue(), 0, "bit_depth_luma_minus8")
        XCTAssertEqual(r.ue(), 0, "bit_depth_chroma_minus8")
    }

    /// The Rext VPS carries the same profile row (the PTL is shared
    /// serializer code, but the pin proves the VPS actually calls it
    /// with the Rext recipe).
    func testRextVpsCarriesTheRextProfile() {
        let recipe = HevcHeaderRecipe(
            width: 2048, height: 1280, chroma444: true)
        var r = BitReader(nal: HevcParameterSets.vps(recipe))
        _ = r.u(4); _ = r.u(1); _ = r.u(1)  // vps ids/flags
        _ = r.u(6); _ = r.u(3); _ = r.u(1)
        XCTAssertEqual(r.u(16), 0xFFFF, "vps_reserved_0xffff")
        XCTAssertEqual(r.u(2), 0, "profile_space")
        XCTAssertEqual(r.u(1), 0, "tier")
        XCTAssertEqual(r.u(5), 4, "profile_idc = Rext")
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
