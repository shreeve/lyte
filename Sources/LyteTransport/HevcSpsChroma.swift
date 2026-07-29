// HevcSpsChroma (H4 V-5): the minimal HEVC SPS read the chroma audit
// needs — `chroma_format_idc`, parsed from the in-band SPS an IDR
// carries. Deliberately NOT a general SPS parser: the walk stops at
// the first field past profile_tier_level, everything before it is
// fixed-width or exp-Golomb by the spec (ITU-T H.265 §7.3.2.2.1), and
// hostile bytes return nil rather than throwing — a malformed SPS is
// the decoder's problem to reject; the audit just has nothing to say.
//
// Client-side (root) rather than Wire/ because it serves the client's
// posture audit only; a wire-level SPS vocabulary would be a Wire/
// slice with its own vector discussion.

import LyteWire

public enum HevcSpsChroma {
    /// Parses `chroma_format_idc` from the FIRST SPS NAL found in the
    /// Annex-B blob (idc 0 = 4:0:0, 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4).
    /// Nil when no SPS is present or the bytes run out mid-walk.
    public static func chromaFormatIdc(inAnnexB annexB: [UInt8]) -> UInt32? {
        let units = AnnexBCheck.nalUnits(in: annexB)
        guard let sps = units.first(where: { $0.type == HevcNalType.sps })
        else { return nil }
        let nal = Array(annexB[sps.offset..<sps.offset + sps.length])
        return chromaFormatIdc(inSpsNal: nal)
    }

    /// The same read on one SPS NAL (2-byte NAL header + RBSP with
    /// emulation-prevention bytes still in place).
    public static func chromaFormatIdc(inSpsNal nal: [UInt8]) -> UInt32? {
        guard nal.count > 2 else { return nil }
        let rbsp = stripEmulationPrevention(Array(nal.dropFirst(2)))
        var reader = BitReader(rbsp)
        // sps_video_parameter_set_id u(4), sps_max_sub_layers_minus1
        // u(3), sps_temporal_id_nesting_flag u(1)
        guard reader.skip(bits: 4),
              let maxSubLayersMinus1 = reader.read(bits: 3),
              reader.skip(bits: 1),
              skipProfileTierLevel(
                  &reader, maxSubLayersMinus1: Int(maxSubLayersMinus1)),
              reader.readUe() != nil,          // sps_seq_parameter_set_id
              let idc = reader.readUe()        // chroma_format_idc
        else { return nil }
        return idc
    }

    // MARK: - profile_tier_level (§7.3.3), skipped not decoded

    /// The general block is 88 fixed bits + 8 level bits; each present
    /// sub-layer repeats the same widths behind its presence flags.
    private static func skipProfileTierLevel(
        _ reader: inout BitReader, maxSubLayersMinus1: Int
    ) -> Bool {
        guard reader.skip(bits: 88 + 8) else { return false }
        guard maxSubLayersMinus1 > 0 else { return true }
        var profilePresent: [Bool] = []
        var levelPresent: [Bool] = []
        for _ in 0..<maxSubLayersMinus1 {
            guard let p = reader.read(bits: 1),
                  let l = reader.read(bits: 1) else { return false }
            profilePresent.append(p == 1)
            levelPresent.append(l == 1)
        }
        // reserved_zero_2bits pads the flag block to 8 sub-layers.
        guard reader.skip(bits: (8 - maxSubLayersMinus1) * 2)
        else { return false }
        for i in 0..<maxSubLayersMinus1 {
            if profilePresent[i], !reader.skip(bits: 88) { return false }
            if levelPresent[i], !reader.skip(bits: 8) { return false }
        }
        return true
    }

    // MARK: - RBSP extraction

    /// Drops each emulation-prevention 0x03 (a 00 00 03 whose next
    /// byte is ≤ 0x03 — the spec's insertion rule, inverted).
    static func stripEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if zeros >= 2, byte == 3, i + 1 < bytes.count,
               bytes[i + 1] <= 3 {
                zeros = 0
                i += 1
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
            i += 1
        }
        return out
    }
}

/// MSB-first bit reader over an RBSP byte array. Reads past the end
/// answer nil/false — hostile bytes never trap.
struct BitReader {
    private let bytes: [UInt8]
    private var bitIndex = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    private var bitsRemaining: Int { bytes.count * 8 - bitIndex }

    /// Reads up to 32 bits, MSB first.
    mutating func read(bits count: Int) -> UInt32? {
        guard count >= 0, count <= 32, bitsRemaining >= count else {
            return nil
        }
        var value: UInt32 = 0
        for _ in 0..<count {
            let byte = bytes[bitIndex >> 3]
            let bit = (byte >> (7 - UInt8(bitIndex & 7))) & 1
            value = (value << 1) | UInt32(bit)
            bitIndex += 1
        }
        return value
    }

    mutating func skip(bits count: Int) -> Bool {
        guard count >= 0, bitsRemaining >= count else { return false }
        bitIndex += count
        return true
    }

    /// ue(v) exp-Golomb. Prefixes past 31 leading zeros are refused —
    /// no legitimate SPS field this walk touches gets near that.
    mutating func readUe() -> UInt32? {
        var leadingZeros = 0
        while true {
            guard let bit = read(bits: 1) else { return nil }
            if bit == 1 { break }
            leadingZeros += 1
            guard leadingZeros <= 31 else { return nil }
        }
        guard leadingZeros > 0 else { return 0 }
        guard let suffix = read(bits: leadingZeros) else { return nil }
        return (1 << UInt32(leadingZeros)) - 1 + suffix
    }
}
