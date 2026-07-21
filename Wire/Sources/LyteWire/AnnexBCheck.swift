// Annex-B HEVC integrity checks — the NAL-walking core carried over from
// the frozen client depacketizer (VideoDepacketizer.swift's Cursor walk)
// and HostCore's AnnexB helpers, stripped of every GameStream artifact:
// no 8/24-byte Sunshine frame header, no AUD/SEI stripping, no
// streamPacketIndex. LyteWire only needs what reassembly correctness
// needs: locate NAL units, classify them, and vouch that a byte blob is
// frame-shaped before the packetizer sends it or the assembler emits it.
//
// Types are named HevcNalType/HevcNalUnit/AnnexBCheck — deliberately
// distinct from HostCore's HevcNal/NalUnit/AnnexB so both modules can
// meet in the host's build graph without qualification fights.

public enum HevcNalType {
    public static let trailN: UInt8 = 0
    public static let trailR: UInt8 = 1
    public static let blaWLp: UInt8 = 16
    public static let idrWRadl: UInt8 = 19
    public static let idrNLp: UInt8 = 20
    public static let craNut: UInt8 = 21
    public static let rsvIrapVcl23: UInt8 = 23
    public static let vps: UInt8 = 32
    public static let sps: UInt8 = 33
    public static let pps: UInt8 = 34
    public static let aud: UInt8 = 35
    public static let prefixSei: UInt8 = 39
    public static let suffixSei: UInt8 = 40

    /// VCL NAL types — the picture-carrying range.
    public static func isVcl(_ type: UInt8) -> Bool {
        type < 32
    }

    /// IRAP picture NAL types (BLA/IDR/CRA and the reserved IRAP range) —
    /// the "safe to start decoding here" property the isIDR flag carries.
    public static func isIrap(_ type: UInt8) -> Bool {
        (blaWLp...rsvIrapVcl23).contains(type)
    }

    /// IDR picture NAL types specifically.
    public static func isIdr(_ type: UInt8) -> Bool {
        type == idrWRadl || type == idrNLp
    }

    public static func name(_ type: UInt8) -> String {
        switch type {
        case trailN: return "TRAIL_N"
        case trailR: return "TRAIL_R"
        case blaWLp: return "BLA_W_LP"
        case idrWRadl: return "IDR_W_RADL"
        case idrNLp: return "IDR_N_LP"
        case craNut: return "CRA_NUT"
        case vps: return "VPS"
        case sps: return "SPS"
        case pps: return "PPS"
        case aud: return "AUD"
        case prefixSei: return "PREFIX_SEI"
        case suffixSei: return "SUFFIX_SEI"
        default: return "NAL(\(type))"
        }
    }
}

/// One NAL unit located inside an Annex-B byte blob. `offset`/`length`
/// cover the NAL payload including its 2-byte header, excluding the start
/// code; offsets are relative to the blob's start, not its slice indices.
public struct HevcNalUnit: Hashable, Sendable {
    public let offset: Int
    public let length: Int
    public let type: UInt8

    public init(offset: Int, length: Int, type: UInt8) {
        self.offset = offset
        self.length = length
        self.type = type
    }
}

public enum AnnexBCheck {
    /// Splits an Annex-B byte blob on start codes (00 00 01, with or
    /// without a leading zero) and returns the contained NAL units in
    /// order — the proven walker from the frozen depacketizer's Cursor /
    /// HostCore's AnnexB, including the skip-3 fast path and the
    /// leading-zero attribution of 4-byte start codes. Bytes before the
    /// first start code are not a NAL unit; units shorter than the 2-byte
    /// NAL header are dropped.
    public static func nalUnits(in data: ArraySlice<UInt8>) -> [HevcNalUnit] {
        let base = data.startIndex
        var payloadStarts: [Int] = []
        var i = base
        while i + 2 < data.endIndex {
            if data[i + 2] > 1 {
                i += 3
            } else if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                payloadStarts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }

        var units: [HevcNalUnit] = []
        units.reserveCapacity(payloadStarts.count)
        for (n, start) in payloadStarts.enumerated() {
            var end: Int
            if n + 1 < payloadStarts.count {
                end = payloadStarts[n + 1] - 3
                // A 4-byte start code's leading zero belongs to the next
                // start code, not this payload.
                if end > start, data[end - 1] == 0 { end -= 1 }
            } else {
                end = data.endIndex
            }
            let length = end - start
            guard length >= 2 else { continue }
            let type = (data[start] >> 1) & 0x3F
            units.append(HevcNalUnit(offset: start - base, length: length, type: type))
        }
        return units
    }

    public static func nalUnits(in data: [UInt8]) -> [HevcNalUnit] {
        nalUnits(in: data[...])
    }

    /// The Annex-B start-code length at the blob's first byte: 3, 4, or
    /// nil when the blob does not open on a start code.
    public static func leadingStartCodeLength(_ data: ArraySlice<UInt8>) -> Int? {
        let base = data.startIndex
        guard data.count >= 4, data[base] == 0, data[base + 1] == 0 else {
            return nil
        }
        if data[base + 2] == 1 { return 3 }
        if data[base + 2] == 0, data.count >= 5, data[base + 3] == 1 { return 4 }
        return nil
    }

    /// The frame-boundary integrity check both video endpoints apply: a
    /// frame's bytes must open on a start code (nothing rides before the
    /// first NAL) and contain at least one VCL NAL unit. The packetizer
    /// refuses input that fails this; the assembler suppresses recovered
    /// output that fails it — correct bytes or nothing, never garbage.
    public static func isFrameShaped(_ data: ArraySlice<UInt8>) -> Bool {
        guard leadingStartCodeLength(data) != nil else { return false }
        return nalUnits(in: data).contains { HevcNalType.isVcl($0.type) }
    }

    public static func isFrameShaped(_ data: [UInt8]) -> Bool {
        isFrameShaped(data[...])
    }

    /// True when the frame carries an IRAP picture — how the assembler
    /// derives `DecodeUnit.isIDR` from recovered bytes, and how the
    /// packetizer audits the encoder's claimed flag.
    public static func containsIrap(_ data: ArraySlice<UInt8>) -> Bool {
        nalUnits(in: data).contains { HevcNalType.isIrap($0.type) }
    }

    public static func containsIrap(_ data: [UInt8]) -> Bool {
        containsIrap(data[...])
    }

    /// Human-readable NAL type sequence, for logs and gate evidence.
    public static func summary(of data: ArraySlice<UInt8>) -> String {
        nalUnits(in: data).map { HevcNalType.name($0.type) }.joined(separator: " ")
    }

    public static func summary(of data: [UInt8]) -> String {
        summary(of: data[...])
    }
}
