// VideoReadbackTap: a VTDecompressionSession readback of the samples
// the production factory builds — the §7 corpus harness's client half
// (H4 V-2), committed for V-3 per the plan. The display path
// (AVSampleBufferDisplayLayer) decodes internally and never hands the
// pixels back; gate math (RGB PSNR, chroma integrity, color truth)
// needs the decoded planes, so this tap runs the SAME sample buffers
// through an explicit decompression session and returns the
// CVPixelBuffers. It also answers the question the display layer keeps
// to itself: which decoder actually engaged (hardware or software) —
// kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
// read from the live session, is the plan's "hardware-path property
// asserted" evidence.
//
// Decode is synchronous (no async flag → the output handler runs
// before DecodeFrame returns) and 1:1 in stream order — Lyte's wire is
// low-delay HEVC with no reordering (I+P only), so decode order IS
// display order. Not Sendable by design: harness legs are
// single-threaded; confine an instance to one thread.

import CoreMedia
import CoreVideo
import VideoToolbox

public enum VideoReadbackError: Error, Sendable {
    /// The sample buffer carries no format description.
    case missingFormatDescription
    case sessionCreateFailed(OSStatus)
    case decodeFailed(OSStatus)
    /// Decode reported success but delivered no image buffer (a frame
    /// was dropped or the decoder emitted nothing).
    case noImageBuffer
}

public final class VideoReadbackTap {
    /// Requested output pixel format (kCVPixelFormatType_*), or nil to
    /// take the decoder's native output — the honest probe posture:
    /// what comes out when nobody asks for anything.
    private let outputPixelFormat: OSType?
    /// When true the session demands hardware
    /// (kVTVideoDecoderSpecification_Require…) and creation FAILS on a
    /// software-only path — the loud-reject posture for gates that
    /// must never silently measure a software decode.
    private let requireHardware: Bool

    private var session: VTDecompressionSession?
    private var sessionFormat: CMFormatDescription?

    public init(outputPixelFormat: OSType? = nil, requireHardware: Bool = false) {
        self.outputPixelFormat = outputPixelFormat
        self.requireHardware = requireHardware
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Whether the live session decodes on hardware. Nil before the
    /// first decode (no session yet) or when VideoToolbox declines to
    /// answer; the value refreshes with every session rebuild.
    public private(set) var isHardwareAccelerated: Bool?

    /// Decodes one factory-built sample buffer and returns its pixel
    /// buffer with the presentation timestamp alongside. Rebuilds the
    /// session when the stream's format description changes (the
    /// factory rebuilds ITS description from in-band parameter sets on
    /// IDR — mid-stream resolution changes arrive that way).
    public func decode(
        _ sample: CMSampleBuffer
    ) throws -> (imageBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) {
        guard let format = CMSampleBufferGetFormatDescription(sample) else {
            throw VideoReadbackError.missingFormatDescription
        }
        try ensureSession(for: format)
        guard let session else {
            throw VideoReadbackError.sessionCreateFailed(-1)
        }

        var output: CVPixelBuffer?
        var outputPts = CMTime.invalid
        var decodeStatus = noErr
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { frameStatus, _, imageBuffer, pts, _ in
            decodeStatus = frameStatus
            output = imageBuffer
            outputPts = pts
        }
        guard status == noErr else {
            throw VideoReadbackError.decodeFailed(status)
        }
        guard decodeStatus == noErr else {
            throw VideoReadbackError.decodeFailed(decodeStatus)
        }
        guard let output else {
            throw VideoReadbackError.noImageBuffer
        }
        return (output, outputPts)
    }

    // MARK: - Session lifecycle

    private func ensureSession(for format: CMFormatDescription) throws {
        if let session, let sessionFormat {
            if CMFormatDescriptionEqual(format, otherFormatDescription: sessionFormat) {
                return
            }
            if VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format) {
                self.sessionFormat = format
                return
            }
            VTDecompressionSessionInvalidate(session)
            self.session = nil
            self.sessionFormat = nil
            self.isHardwareAccelerated = nil
        }

        // Hardware is always ENABLED; Require is the opt-in loud mode.
        // With enable-only, a software fallback still decodes — and the
        // property read below is what tells the truth about it.
        var spec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
        ]
        if requireHardware {
            spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true
        }
        var imageAttrs: [CFString: Any] = [:]
        if let outputPixelFormat {
            imageAttrs[kCVPixelBufferPixelFormatTypeKey] = outputPixelFormat
        }

        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: imageAttrs.isEmpty ? nil : imageAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created)
        guard status == noErr, let created else {
            throw VideoReadbackError.sessionCreateFailed(status)
        }
        session = created
        sessionFormat = format

        var value: CFTypeRef?
        if VTSessionCopyProperty(
            created,
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault,
            valueOut: &value) == noErr,
           let flag = value as? Bool {
            isHardwareAccelerated = flag
        } else {
            isHardwareAccelerated = nil
        }
    }
}
