// AnnexBAccessUnits: access-unit boundaries in an HEVC Annex-B
// elementary stream — the file-in seam of the §7 harness's client half
// (H4 V-2). The wire never needs this (the packetizer frames per
// picture already); it exists for offline legs that replay encoder
// output from a FILE through the production render path: V-1's probe
// bitstreams today, the V-3 corpus harness next.
//
// Boundary rule (H.265 §7.4.2.4.4, the practical subset): a new access
// unit begins at a VCL NAL whose first_slice_segment_in_pic_flag is set
// (the first bit after the 2-byte NAL header), and any run of non-VCL
// prefix NALs immediately before it (VPS/SPS/PPS/AUD/prefix SEI…)
// belongs to the NEW unit; suffix SEI stays with the picture it
// follows. That covers every conformant low-delay encoder stream —
// hevc_nvenc's output shape included.

import LyteWire

public enum AnnexBAccessUnits {
    /// Byte ranges of the access units in `bytes`, in stream order.
    /// Each range opens on its start code (leading zeros of a 4-byte
    /// start code included) so the slices are frame-shaped for
    /// DecodeUnit/VideoRenderFactory as-is. Bytes before the first
    /// start code are not part of any unit; a stream with no VCL NAL
    /// yields no ranges.
    public static func ranges(in bytes: [UInt8]) -> [Range<Int>] {
        let nals = AnnexBCheck.nalUnits(in: bytes)
        guard nals.contains(where: { HevcNalType.isVcl($0.type) }) else {
            return []
        }

        // The NAL indices where access units begin.
        var starts: [Int] = [0]
        var lastVclIndex: Int?
        for (i, nal) in nals.enumerated() {
            guard HevcNalType.isVcl(nal.type) else { continue }
            if firstSliceFlag(of: nal, in: bytes), let lastVcl = lastVclIndex {
                // Attach the contiguous non-VCL prefix run to this unit.
                var b = i
                while b - 1 > lastVcl,
                      !HevcNalType.isVcl(nals[b - 1].type),
                      nals[b - 1].type != HevcNalType.suffixSei {
                    b -= 1
                }
                if starts.last != b { starts.append(b) }
            }
            lastVclIndex = i
        }

        var out: [Range<Int>] = []
        out.reserveCapacity(starts.count)
        for (n, s) in starts.enumerated() {
            let lower = startCodeStart(of: nals[s], in: bytes)
            let upper = n + 1 < starts.count
                ? startCodeStart(of: nals[starts[n + 1]], in: bytes)
                : bytes.count
            out.append(lower..<upper)
        }
        return out
    }

    /// first_slice_segment_in_pic_flag — the first slice-header bit,
    /// i.e. the MSB of the byte after the 2-byte NAL header. False for
    /// a truncated NAL (header only), which no conformant slice is.
    private static func firstSliceFlag(
        of nal: HevcNalUnit, in bytes: [UInt8]
    ) -> Bool {
        guard nal.length >= 3 else { return false }
        return bytes[nal.offset + 2] & 0x80 != 0
    }

    /// The start-code start for a NAL whose `offset` names the payload
    /// start: back over `00 00 01`, then over every leading zero (4-byte
    /// start codes and encoder zero-padding alike — trailing zeros of
    /// the previous NAL are inter-NAL padding per the RBSP stop-bit
    /// guarantee, so attributing them here is harmless).
    private static func startCodeStart(
        of nal: HevcNalUnit, in bytes: [UInt8]
    ) -> Int {
        var start = nal.offset - 3
        while start > 0, bytes[start - 1] == 0 {
            start -= 1
        }
        return max(start, 0)
    }
}
