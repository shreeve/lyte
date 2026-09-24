// Access-unit splitting for corpus tooling (not wire contract): a captured
// Annex-B stream in, per-frame byte ranges out. A new access unit begins at
// the first leading NAL (VPS/SPS/PPS/AUD/prefix SEI or VCL) after the
// previous unit's VCL NAL; splits land on start codes, so concatenating
// the ranges reproduces the stream byte-exact.

import LyteCore

public enum AnnexBStream {
    /// Byte ranges of the stream's access units, covering the stream
    /// exactly (offset 0 through the last byte, contiguous). Bytes
    /// before the first start code, if any, ride with the first unit.
    public static func accessUnitRanges(in data: [UInt8]) -> [Range<Int>] {
        let nals = AnnexBCheck.nalUnits(in: data)
        guard !nals.isEmpty else { return data.isEmpty ? [] : [0..<data.count] }

        var boundaries: [Int] = [0]
        var sawVcl = false
        for nal in nals {
            let isVcl = HevcNalType.isVcl(nal.type)
            let isLeading = isVcl || [
                HevcNalType.vps, HevcNalType.sps, HevcNalType.pps,
                HevcNalType.aud, HevcNalType.prefixSei,
            ].contains(nal.type)
            if sawVcl, isLeading {
                boundaries.append(startCodeStart(before: nal.offset, in: data))
                sawVcl = false
            }
            if isVcl { sawVcl = true }
        }

        var ranges: [Range<Int>] = []
        for (i, start) in boundaries.enumerated() {
            let end = i + 1 < boundaries.count ? boundaries[i + 1] : data.count
            ranges.append(start..<end)
        }
        return ranges
    }

    /// The start of the start code preceding a NAL payload offset:
    /// 3 bytes back, or 4 when a leading zero makes it a 4-byte code.
    private static func startCodeStart(before offset: Int, in data: [UInt8]) -> Int {
        var start = offset - 3
        if start > 0, data[start - 1] == 0 { start -= 1 }
        return start
    }
}
