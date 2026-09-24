// One shared HEVC Annex-B vocabulary and walker: allocation-free when
// classifying a borrowed byte collection, and free of Foundation and IO.

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

    public static func isVcl(_ type: UInt8) -> Bool {
        type < 32
    }

    public static func isIrap(_ type: UInt8) -> Bool {
        (blaWLp...rsvIrapVcl23).contains(type)
    }

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

/// One NAL unit inside an Annex-B byte blob. Offsets are relative to the
/// blob's start; the range covers the two-byte NAL header and payload but
/// excludes its start code.
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

public struct AnnexBFrameClassification: Hashable, Sendable {
    public let isFrameShaped: Bool
    public let containsIrap: Bool

    public init(isFrameShaped: Bool, containsIrap: Bool) {
        self.isFrameShaped = isFrameShaped
        self.containsIrap = containsIrap
    }
}

/// The Annex-B walker. Every entry point borrows its bytes contiguously and
/// runs one non-generic raw-buffer scan compiled inside LyteCore; only a
/// non-contiguous collection is copied.
public enum AnnexBCheck {
    public static func nalUnits(in data: ArraySlice<UInt8>) -> [HevcNalUnit] {
        data.withUnsafeBufferPointer(nalUnitsRaw)
    }

    public static func nalUnits(in data: [UInt8]) -> [HevcNalUnit] {
        data.withUnsafeBufferPointer(nalUnitsRaw)
    }

    public static func leadingStartCodeLength<C>(_ data: C) -> Int?
    where C: RandomAccessCollection, C.Element == UInt8, C.Index == Int {
        let base = data.startIndex
        guard data.count >= 4, data[base] == 0, data[base + 1] == 0 else {
            return nil
        }
        if data[base + 2] == 1 { return 3 }
        if data[base + 2] == 0, data.count >= 5, data[base + 3] == 1 {
            return 4
        }
        return nil
    }

    @inlinable
    public static func classifyFrame<C>(
        _ data: C
    ) -> AnnexBFrameClassification
    where C: RandomAccessCollection, C.Element == UInt8, C.Index == Int {
        if let classification = data.withContiguousStorageIfAvailable(
            classifyRaw) {
            return classification
        }
        return Array(data).withUnsafeBufferPointer(classifyRaw)
    }

    public static func classifyFrame(_ data: [UInt8]) -> AnnexBFrameClassification {
        data.withUnsafeBufferPointer(classifyRaw)
    }

    public static func isFrameShaped(_ data: ArraySlice<UInt8>) -> Bool {
        classifyFrame(data).isFrameShaped
    }

    public static func isFrameShaped(_ data: [UInt8]) -> Bool {
        classifyFrame(data).isFrameShaped
    }

    public static func containsIrap(_ data: ArraySlice<UInt8>) -> Bool {
        classifyFrame(data).containsIrap
    }

    public static func containsIrap(_ data: [UInt8]) -> Bool {
        classifyFrame(data).containsIrap
    }

    public static func startsWithParameterSetsAndIrap(_ data: [UInt8]) -> Bool {
        var types = Set<UInt8>()
        var hasIrap = false
        data.withUnsafeBufferPointer { buffer in
            walkNalUnits(in: buffer) { unit in
                types.insert(unit.type)
                hasIrap = hasIrap || HevcNalType.isIrap(unit.type)
            }
        }
        return types.contains(HevcNalType.vps)
            && types.contains(HevcNalType.sps)
            && types.contains(HevcNalType.pps)
            && hasIrap
    }

    public static func summary(of data: ArraySlice<UInt8>) -> String {
        nalUnits(in: data).map { HevcNalType.name($0.type) }.joined(separator: " ")
    }

    public static func summary(of data: [UInt8]) -> String {
        summary(of: data[...])
    }

    @usableFromInline
    static func classifyRaw(
        _ data: UnsafeBufferPointer<UInt8>
    ) -> AnnexBFrameClassification {
        let opensOnStartCode = leadingStartCodeLength(data) != nil
        var hasVcl = false
        var hasIrap = false
        walkNalUnits(in: data) { unit in
            hasVcl = hasVcl || HevcNalType.isVcl(unit.type)
            hasIrap = hasIrap || HevcNalType.isIrap(unit.type)
        }
        return AnnexBFrameClassification(
            isFrameShaped: opensOnStartCode && hasVcl,
            containsIrap: hasIrap
        )
    }

    private static func nalUnitsRaw(
        _ data: UnsafeBufferPointer<UInt8>
    ) -> [HevcNalUnit] {
        var units: [HevcNalUnit] = []
        walkNalUnits(in: data) { units.append($0) }
        return units
    }

    /// Visits every NAL unit of length ≥ 2 in order. A start code is
    /// `00 00 01`; a zero byte before it (a four-byte start code) is not
    /// part of the preceding unit. Offsets are relative to `data`.
    private static func walkNalUnits(
        in data: UnsafeBufferPointer<UInt8>,
        _ visit: (HevcNalUnit) -> Void
    ) {
        let count = data.count
        var pendingStart: Int?
        var i = 0
        while i + 2 < count {
            // Skip three bytes whenever the third cannot end a start code.
            if data[i + 2] > 1 {
                i += 3
            } else if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                let nextStart = i + 3
                if let start = pendingStart {
                    var end = i
                    if end > start, data[end - 1] == 0 { end -= 1 }
                    let length = end - start
                    if length >= 2 {
                        visit(HevcNalUnit(
                            offset: start,
                            length: length,
                            type: (data[start] >> 1) & 0x3F
                        ))
                    }
                }
                pendingStart = nextStart
                i = nextStart
            } else {
                i += 1
            }
        }

        if let start = pendingStart {
            let length = count - start
            if length >= 2 {
                visit(HevcNalUnit(
                    offset: start,
                    length: length,
                    type: (data[start] >> 1) & 0x3F
                ))
            }
        }
    }
}

/// Production access-unit boundaries for an HEVC Annex-B elementary stream.
/// Prefix NALs attach to the following picture; suffix SEI stays behind.
public enum AnnexBAccessUnits {
    public static func ranges(in bytes: [UInt8]) -> [Range<Int>] {
        let nals = AnnexBCheck.nalUnits(in: bytes)
        guard nals.contains(where: { HevcNalType.isVcl($0.type) }) else {
            return []
        }

        var starts: [Int] = [0]
        var lastVclIndex: Int?
        for (index, nal) in nals.enumerated() {
            guard HevcNalType.isVcl(nal.type) else { continue }
            if firstSliceFlag(of: nal, in: bytes), let lastVcl = lastVclIndex {
                var boundary = index
                while boundary - 1 > lastVcl,
                      !HevcNalType.isVcl(nals[boundary - 1].type),
                      nals[boundary - 1].type != HevcNalType.suffixSei {
                    boundary -= 1
                }
                if starts.last != boundary { starts.append(boundary) }
            }
            lastVclIndex = index
        }

        return starts.enumerated().map { position, startIndex in
            let lower = startCodeStart(of: nals[startIndex], in: bytes)
            let upper = position + 1 < starts.count
                ? startCodeStart(of: nals[starts[position + 1]], in: bytes)
                : bytes.count
            return lower..<upper
        }
    }

    private static func firstSliceFlag(
        of nal: HevcNalUnit,
        in bytes: [UInt8]
    ) -> Bool {
        guard nal.length >= 3 else { return false }
        return bytes[nal.offset + 2] & 0x80 != 0
    }

    private static func startCodeStart(
        of nal: HevcNalUnit,
        in bytes: [UInt8]
    ) -> Int {
        var start = nal.offset - 3
        while start > 0, bytes[start - 1] == 0 { start -= 1 }
        return max(start, 0)
    }
}
