import Foundation
import CoreMedia

/// Turns decode units into CMSampleBuffers for AVSampleBufferDisplayLayer /
/// VTDecompressionSession. Owns the CMVideoFormatDescription, rebuilding it
/// whenever an IDR frame carries new parameter sets (host resolution/HDR
/// changes arrive as VPS/SPS/PPS changes mid-stream).
public final class VideoSampleFactory: @unchecked Sendable {   // confine to one thread
    public enum Codec: Sendable { case h264, hevc }

    private let codec: Codec
    private var formatDescription: CMVideoFormatDescription?

    public init(codec: Codec) {
        self.codec = codec
    }

    /// Build a sample buffer. IDR units refresh the format description from
    /// their parameter sets. Returns nil for units that can't be decoded yet
    /// (e.g. P-frame before the first IDR).
    public func makeSampleBuffer(from du: DecodeUnit) throws -> CMSampleBuffer? {
        if du.frameType == .idr {
            try rebuildFormatDescription(from: du)
        }
        guard let formatDescription else { return nil }

        // Concatenate picture data and convert Annex-B → 4-byte length prefixes
        var annexB = Data(capacity: du.fullLength)
        for buffer in du.buffers where buffer.type == .picdata {
            annexB.append(buffer.data)
        }
        let avcc = Self.annexBToLengthPrefixed(annexB)
        guard !avcc.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else {
            throw LyteError.host("video: CMBlockBuffer create failed (\(status))")
        }
        status = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == noErr else {
            throw LyteError.host("video: CMBlockBuffer fill failed (\(status))")
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(du.rtpTimestamp), timescale: 90_000),
            decodeTimeStamp: .invalid)
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            throw LyteError.host("video: CMSampleBuffer create failed (\(status))")
        }

        // M3: display as fast as frames arrive; pacing comes with M7
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }

    // MARK: - Parameter sets

    private func rebuildFormatDescription(from du: DecodeUnit) throws {
        func parameterSet(_ type: DecodeUnit.BufferType) -> Data? {
            guard let buf = du.buffers.first(where: { $0.type == type }) else { return nil }
            return Self.stripStartCodeAndPadding(buf.data)
        }

        var desc: CMVideoFormatDescription?
        switch codec {
        case .hevc:
            guard let vps = parameterSet(.vps), let sps = parameterSet(.sps),
                  let pps = parameterSet(.pps) else { return }
            let sets = [vps, sps, pps]
            try withParameterSets(sets) { pointers, sizes in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil,
                    formatDescriptionOut: &desc)
            }
        case .h264:
            guard let sps = parameterSet(.sps), let pps = parameterSet(.pps) else { return }
            let sets = [sps, pps]
            try withParameterSets(sets) { pointers, sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc)
            }
        }
        if let desc { formatDescription = desc }
    }

    private func withParameterSets(_ sets: [Data],
                                   _ body: ([UnsafePointer<UInt8>], [Int]) -> OSStatus) throws {
        // Manually allocated so the pointers stay valid across the call
        let buffers = sets.map { data -> UnsafeMutableBufferPointer<UInt8> in
            let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: data.count)
            _ = buf.initialize(from: data)
            return buf
        }
        defer { buffers.forEach { $0.deallocate() } }
        let status = body(buffers.map { UnsafePointer($0.baseAddress!) }, sets.map(\.count))
        guard status == noErr else {
            throw LyteError.host("video: format description create failed (\(status))")
        }
    }

    /// Strip the Annex-B start code and trailing zero padding from a parameter
    /// set NAL. (RBSP always ends in a stop bit, so the last real byte is
    /// non-zero; trailing zeros are inter-NAL padding.)
    static func stripStartCodeAndPadding(_ data: Data) -> Data? {
        var bytes = [UInt8](data)
        // Strip start code (3 or 4 bytes)
        if bytes.count > 4, bytes[0] == 0, bytes[1] == 0 {
            if bytes[2] == 1 {
                bytes.removeFirst(3)
            } else if bytes[2] == 0, bytes[3] == 1 {
                bytes.removeFirst(4)
            } else {
                return nil
            }
        } else {
            return nil
        }
        while let last = bytes.last, last == 0 { bytes.removeLast() }
        return bytes.isEmpty ? nil : Data(bytes)
    }

    /// Convert an Annex-B bitstream (3- or 4-byte start codes) to 4-byte
    /// big-endian length-prefixed NALs (AVCC/HVCC sample layout). Trailing
    /// zeros of each NAL are stripped: they are either inter-NAL padding or
    /// FEC zero-fill, never part of the NAL (RBSP stop-bit guarantee).
    static func annexBToLengthPrefixed(_ annexB: Data) -> Data {
        let bytes = [UInt8](annexB)
        var out = Data(capacity: bytes.count + 64)
        var i = 0
        let n = bytes.count

        @inline(__always) func startCodeLength(at p: Int) -> Int? {
            guard p + 3 < n, bytes[p] == 0, bytes[p+1] == 0 else { return nil }
            if bytes[p+2] == 1 { return 3 }
            if bytes[p+2] == 0, p + 4 < n, bytes[p+3] == 1 { return 4 }
            return nil
        }

        // Find the first start code
        while i < n, startCodeLength(at: i) == nil { i += 1 }

        while i < n {
            guard let sc = startCodeLength(at: i) else { break }
            let nalStart = i + sc
            var j = nalStart
            while j < n, startCodeLength(at: j) == nil { j += 1 }
            var nalEnd = j
            while nalEnd > nalStart, bytes[nalEnd - 1] == 0 { nalEnd -= 1 }
            let length = nalEnd - nalStart
            if length > 0 {
                out.append(contentsOf: [
                    UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
                    UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
                ])
                out.append(contentsOf: bytes[nalStart..<nalEnd])
            }
            i = j
        }
        return out
    }
}
