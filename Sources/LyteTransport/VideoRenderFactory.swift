// VideoRenderFactory: LyteWire DecodeUnit → CMSampleBuffer for
// AVSampleBufferDisplayLayer — CL-2's copy-adaptation of the GameStream
// stack's proven construction (LyteKit's VideoSampleFactory, deleted at
// the H2 demolition; git history keeps the original):
// the CMBlockBuffer/CMSampleBuffer assembly, the format-description
// rebuild on IDR parameter sets and the Annex-B → 4-byte length-prefix
// conversion with the
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
//   - pts begins as the host capture timestamp (µs); the app's adaptive
//     playout seam re-stamps it into the local CM host-clock domain.

import CoreMedia
import Foundation
import LyteCore
import LyteWire

public enum VideoRenderError: Error, Sendable {
    case formatDescriptionCreateFailed(OSStatus)
    case blockBufferCreateFailed(OSStatus)
    case blockBufferFillFailed(OSStatus)
    case sampleBufferCreateFailed(OSStatus)
}

public struct VideoRenderCopyMetrics: Equatable, Sendable {
    /// Bytes in the final HVCC sample storage.
    public var destinationBytes: Int
    /// Full payload-sized temporary storage allocated during conversion.
    public var intermediateBytes: Int
    /// Source-to-owned-destination passes over NAL payload bytes.
    public var payloadCopyPasses: Int

    public init(
        destinationBytes: Int,
        intermediateBytes: Int,
        payloadCopyPasses: Int
    ) {
        self.destinationBytes = destinationBytes
        self.intermediateBytes = intermediateBytes
        self.payloadCopyPasses = payloadCopyPasses
    }
}

/// Not Sendable by design: LyteVideoPipeline confines it behind its lock.
public final class VideoRenderFactory {
    private var formatDescription: CMVideoFormatDescription?
    public private(set) var lastCopyMetrics: VideoRenderCopyMetrics?

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

        let nals = Self.renderableNALs(annexB: unit.annexB)
        let sampleByteCount = nals.reduce(0) { $0 + 4 + $1.range.count }
        guard sampleByteCount > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: sampleByteCount,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: sampleByteCount, flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else {
            throw VideoRenderError.blockBufferCreateFailed(status)
        }

        // Convert directly into CoreMedia-owned storage. The former path
        // first built a full HVCC [UInt8], then copied it wholesale into
        // this block. Writing prefixes and NAL slices here removes that
        // payload-sized allocation and one complete copy while retaining
        // simple ownership: the sample owns immutable CoreMedia memory,
        // independent of DecodeUnit as soon as this method returns.
        var destinationOffset = 0
        for nal in nals {
            var length = UInt32(nal.range.count).bigEndian
            status = withUnsafeBytes(of: &length) { bytes in
                CMBlockBufferReplaceDataBytes(
                    with: bytes.baseAddress!, blockBuffer: blockBuffer,
                    offsetIntoDestination: destinationOffset,
                    dataLength: bytes.count)
            }
            guard status == noErr else {
                throw VideoRenderError.blockBufferFillFailed(status)
            }
            destinationOffset += 4
            status = unit.annexB[nal.range].withUnsafeBytes { bytes in
                CMBlockBufferReplaceDataBytes(
                    with: bytes.baseAddress!, blockBuffer: blockBuffer,
                    offsetIntoDestination: destinationOffset,
                    dataLength: bytes.count)
            }
            guard status == noErr else {
                throw VideoRenderError.blockBufferFillFailed(status)
            }
            destinationOffset += nal.range.count
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            // Host-clock µs; bit-pattern so a hostile timestamp near the
            // Int64 boundary orders wrong instead of trapping.
            presentationTimeStamp: CMTime(
                value: Int64(bitPattern: unit.timestamp.microseconds),
                timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sampleSize = sampleByteCount
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
        lastCopyMetrics = VideoRenderCopyMetrics(
            destinationBytes: sampleByteCount,
            intermediateBytes: 0,
            payloadCopyPasses: 1)

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
        let nals = renderableNALs(annexB: annexB)
        var out = [UInt8]()
        out.reserveCapacity(nals.reduce(0) { $0 + 4 + $1.range.count })
        for nal in nals {
            let length = nal.range.count
            out.append(contentsOf: [
                UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
                UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
            ])
            out.append(contentsOf: annexB[nal.range])
        }
        return out
    }

    private struct RenderableNAL {
        var range: Range<Int>
    }

    /// One validated AnnexBCheck walk shared by the diagnostic converter
    /// and the direct-to-CoreMedia path. Empty NALs and RBSP padding have
    /// exactly the prior semantics.
    private static func renderableNALs(annexB: [UInt8]) -> [RenderableNAL] {
        AnnexBCheck.nalUnits(in: annexB).compactMap { unit in
            var end = unit.offset + unit.length
            while end > unit.offset, annexB[end - 1] == 0 { end -= 1 }
            guard end > unit.offset else { return nil }
            return RenderableNAL(range: unit.offset..<end)
        }
    }
}
