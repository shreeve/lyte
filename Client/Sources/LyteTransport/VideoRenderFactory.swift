// VideoRenderFactory: HEVC DecodeUnit → CMSampleBuffer. Rebuilds the format
// description from an IDR's in-band VPS/SPS/PPS and converts Annex-B to
// 4-byte length-prefixed NALs, stripping trailing zeros (a NAL's last real
// byte is never zero). The pts is the host capture timestamp (µs).

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

/// Not Sendable by design: LyteVideoPipeline confines it to its serial
/// sample-build queue.
public final class VideoRenderFactory {
    private var formatDescription: CMVideoFormatDescription?
    /// The VPS/SPS/PPS bytes `formatDescription` was built from; an IDR
    /// repeating them reuses the description instead of rebuilding it.
    private var parameterSets: [[UInt8]] = []

    public init() {}

    /// Builds a ready-to-enqueue sample buffer; IDRs refresh the format
    /// description. Returns nil for a P-frame before the first IDR.
    public func makeSampleBuffer(from unit: DecodeUnit) throws -> CMSampleBuffer? {
        let nals = Self.renderableNALs(annexB: unit.annexB)
        if unit.isIDR {
            try refreshFormatDescription(nals: nals, annexB: unit.annexB)
        }
        guard let formatDescription else { return nil }

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

        // Convert directly into CoreMedia-owned storage (no intermediate
        // copy); the sample is independent of DecodeUnit on return.
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
        return sampleBuffer
    }

    // MARK: - Parameter sets

    /// Rebuilds the description from the unit's parameter sets. An IRAP
    /// without in-band VPS/SPS/PPS keeps the current description, as does
    /// one repeating the sets the current description came from.
    private func refreshFormatDescription(
        nals: [RenderableNAL], annexB: [UInt8]
    ) throws {
        func parameterSet(_ type: UInt8) -> [UInt8]? {
            nals.first { $0.type == type }.map { Array(annexB[$0.range]) }
        }
        guard let vps = parameterSet(HevcNalType.vps),
              let sps = parameterSet(HevcNalType.sps),
              let pps = parameterSet(HevcNalType.pps) else { return }
        let sets = [vps, sps, pps]
        guard formatDescription == nil || sets != parameterSets else { return }

        // Manually allocated so the pointers stay valid across the call.
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
        if let desc {
            formatDescription = desc
            parameterSets = sets
        }
    }

    private struct RenderableNAL {
        var type: UInt8
        var range: Range<Int>
    }

    /// One AnnexBCheck walk per unit: each NAL's byte range minus its
    /// trailing-zero padding; NALs that are all padding are dropped.
    private static func renderableNALs(annexB: [UInt8]) -> [RenderableNAL] {
        AnnexBCheck.nalUnits(in: annexB).compactMap { unit in
            var end = unit.offset + unit.length
            while end > unit.offset, annexB[end - 1] == 0 { end -= 1 }
            guard end > unit.offset else { return nil }
            return RenderableNAL(type: unit.type, range: unit.offset..<end)
        }
    }
}
