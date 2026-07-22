// VideoRenderFactory: LyteWire DecodeUnit → CMSampleBuffer for
// AVSampleBufferDisplayLayer — CL-2's copy-adaptation of the GameStream
// stack's proven construction (LyteKit's VideoSampleFactory, deleted at
// the H2 demolition; git history keeps the original):
// the CMBlockBuffer/CMSampleBuffer assembly, the format-description
// rebuild on IDR parameter sets, the DisplayImmediately attachment
// (present-ASAP — Work mode's default, no jitter buffer per the timing
// doc), and the Annex-B → 4-byte length-prefix conversion with the
// trailing-zero strip (RBSP stop-bit guarantee: a NAL's last real byte
// is never zero, so trailing zeros are inter-NAL padding).
//
// Copied rather than imported because the original factory was entangled
// with the GameStream DecodeUnit (typed buffer chains, RTP 90 kHz
// timestamps, Sunshine frame headers). Deliberate differences from the
// original:
//   - parameter sets and NAL boundaries come from AnnexBCheck's walker
//     over the recovered Annex-B bytes, not typed buffer chains;
//   - HEVC only — Lyte's wire carries hevc_nvenc output; the H.264 leg
//     died with the GameStream stack;
//   - pts is the host capture timestamp (µs, host clock domain) instead
//     of an RTP tick; with DisplayImmediately it orders, not paces.

import CoreMedia
import Foundation
import LyteWire

public enum VideoRenderError: Error, Sendable {
    case formatDescriptionCreateFailed(OSStatus)
    case blockBufferCreateFailed(OSStatus)
    case blockBufferFillFailed(OSStatus)
    case sampleBufferCreateFailed(OSStatus)
}

/// Not Sendable by design: LyteVideoPipeline confines it behind its lock.
public final class VideoRenderFactory {
    private var formatDescription: CMVideoFormatDescription?

    public init() {}

    /// Whether the IDR/parameter-set bootstrap has happened — before the
    /// first IDR every P-frame's sample is withheld (returns nil).
    public var hasFormatDescription: Bool { formatDescription != nil }

    /// Builds a ready-to-enqueue sample buffer. IDR units refresh the
    /// format description from their in-band VPS/SPS/PPS (host
    /// resolution changes arrive as new parameter sets mid-stream).
    /// Returns nil for units that cannot render yet (P-frame before the
    /// first IDR).
    public func makeSampleBuffer(from unit: DecodeUnit) throws -> CMSampleBuffer? {
        if unit.isIDR {
            try rebuildFormatDescription(from: unit.annexB)
        }
        guard let formatDescription else { return nil }

        let hvcc = Self.lengthPrefixed(annexB: unit.annexB)
        guard !hvcc.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: hvcc.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: hvcc.count, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else {
            throw VideoRenderError.blockBufferCreateFailed(status)
        }
        status = hvcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: hvcc.count)
        }
        guard status == noErr else {
            throw VideoRenderError.blockBufferFillFailed(status)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            // Host-clock µs; bit-pattern so a hostile timestamp near the
            // Int64 boundary orders wrong instead of trapping.
            presentationTimeStamp: CMTime(
                value: Int64(bitPattern: unit.timestamp.microseconds),
                timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sampleSize = hvcc.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            throw VideoRenderError.sampleBufferCreateFailed(status)
        }

        // Present-ASAP: display as fast as frames arrive.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }

    // MARK: - Parameter sets

    private func rebuildFormatDescription(from annexB: [UInt8]) throws {
        let units = AnnexBCheck.nalUnits(in: annexB)
        func parameterSet(_ type: UInt8) -> [UInt8]? {
            guard let unit = units.first(where: { $0.type == type }) else { return nil }
            var bytes = Array(annexB[unit.offset..<unit.offset + unit.length])
            while let last = bytes.last, last == 0 { bytes.removeLast() }
            return bytes.isEmpty ? nil : bytes
        }
        // An IRAP without in-band parameter sets keeps the current
        // description (same behavior as the frozen factory's guard).
        guard let vps = parameterSet(HevcNalType.vps),
              let sps = parameterSet(HevcNalType.sps),
              let pps = parameterSet(HevcNalType.pps) else { return }
        let sets = [vps, sps, pps]

        // Manually allocated so the pointers stay valid across the call
        // (copied from the frozen factory's withParameterSets).
        let buffers = sets.map { bytes -> UnsafeMutableBufferPointer<UInt8> in
            let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
            _ = buf.initialize(from: bytes)
            return buf
        }
        defer { buffers.forEach { $0.deallocate() } }

        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
            parameterSetPointers: buffers.map { UnsafePointer($0.baseAddress!) },
            parameterSetSizes: sets.map(\.count),
            nalUnitHeaderLength: 4, extensions: nil,
            formatDescriptionOut: &desc)
        guard status == noErr else {
            throw VideoRenderError.formatDescriptionCreateFailed(status)
        }
        if let desc { formatDescription = desc }
    }

    /// Annex-B (3- or 4-byte start codes) → 4-byte big-endian
    /// length-prefixed NALs (the HVCC sample layout VideoToolbox wants).
    /// Rides AnnexBCheck's proven walker; trailing zeros of each NAL are
    /// stripped as padding per the RBSP stop-bit guarantee.
    public static func lengthPrefixed(annexB: [UInt8]) -> [UInt8] {
        let units = AnnexBCheck.nalUnits(in: annexB)
        var out = [UInt8]()
        out.reserveCapacity(annexB.count + units.count * 4)
        for unit in units {
            var end = unit.offset + unit.length
            while end > unit.offset, annexB[end - 1] == 0 { end -= 1 }
            let length = end - unit.offset
            guard length > 0 else { continue }
            out.append(contentsOf: [
                UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
                UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
            ])
            out.append(contentsOf: annexB[unit.offset..<end])
        }
        return out
    }
}