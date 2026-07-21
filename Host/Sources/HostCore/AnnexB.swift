// Annex-B HEVC bitstream helpers: start-code scanning and NAL classification.
// Pure Swift so the contract is testable on any platform.

public enum HevcNal {
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

    /// IRAP picture NAL types (BLA/IDR/CRA and the reserved IRAP range).
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

/// One NAL unit located inside an Annex-B byte stream.
/// `offset`/`length` cover the NAL payload including its 2-byte header,
/// excluding the start code.
public struct NalUnit: Equatable, Sendable {
    public let offset: Int
    public let length: Int
    public let type: UInt8

    public init(offset: Int, length: Int, type: UInt8) {
        self.offset = offset
        self.length = length
        self.type = type
    }
}

public enum AnnexB {
    /// Splits an Annex-B byte stream on start codes (00 00 01, with or
    /// without a leading zero) and returns the contained NAL units in
    /// order. Bytes before the first start code are not a NAL unit and are
    /// ignored; the caller decides whether that is an error. Units shorter
    /// than the 2-byte NAL header are dropped.
    public static func nalUnits(in data: [UInt8]) -> [NalUnit] {
        var payloadStarts: [Int] = []
        var i = 0
        while i + 2 < data.count {
            if data[i + 2] > 1 {
                i += 3
            } else if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                payloadStarts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }

        var units: [NalUnit] = []
        for (n, start) in payloadStarts.enumerated() {
            var end: Int
            if n + 1 < payloadStarts.count {
                end = payloadStarts[n + 1] - 3
                // A 4-byte start code's leading zero belongs to the next
                // start code, not this payload.
                if end > start, data[end - 1] == 0 { end -= 1 }
            } else {
                end = data.count
            }
            let length = end - start
            guard length >= 2 else { continue }
            let type = (data[start] >> 1) & 0x3F
            units.append(NalUnit(offset: start, length: length, type: type))
        }
        return units
    }

    /// True when the stream begins with the parameter sets and an IRAP
    /// picture — the shape the first encoded access unit must have.
    public static func startsWithParameterSetsAndIrap(_ data: [UInt8]) -> Bool {
        let units = nalUnits(in: data)
        let types = Set(units.map(\.type))
        return types.contains(HevcNal.vps)
            && types.contains(HevcNal.sps)
            && types.contains(HevcNal.pps)
            && units.contains { HevcNal.isIrap($0.type) }
    }

    /// Human-readable NAL type sequence, for logs and evidence.
    public static func summary(of data: [UInt8]) -> String {
        nalUnits(in: data).map { HevcNal.name($0.type) }.joined(separator: " ")
    }
}
