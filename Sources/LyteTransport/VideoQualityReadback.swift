import CoreVideo
import Foundation
import VideoToolbox

public enum VideoQualityReadbackError: Error, Sendable {
    case invalidDimensions
    case invalidReferenceSize(expected: Int, actual: Int)
    case pixelBufferLockFailed(CVReturn)
    case pixelBufferCreateFailed(CVReturn)
    case pixelTransferSessionCreateFailed(OSStatus)
    case pixelTransferFailed(OSStatus)
}

/// Native-resolution readback and corpus scoring for the production renderer.
/// AppKit never participates: callers pass the renderer's decoded pixel buffer,
/// and viewport geometry is recorded separately by the app benchmark.
public enum VideoQualityReadback {
    public struct Frame: Sendable {
        public let width: Int
        public let height: Int
        /// Packed BGRA, tightly row-strided.
        public let bgra: [UInt8]
        public let sourcePixelFormat: String
        public let sourceBytesPerRow: Int
        public let yCbCrMatrix: String?
        public let colorPrimaries: String?
        public let transferFunction: String?

        public init(
            width: Int, height: Int, bgra: [UInt8],
            sourcePixelFormat: String = "BGRA",
            sourceBytesPerRow: Int? = nil,
            yCbCrMatrix: String? = nil,
            colorPrimaries: String? = nil,
            transferFunction: String? = nil
        ) {
            self.width = width
            self.height = height
            self.bgra = bgra
            self.sourcePixelFormat = sourcePixelFormat
            self.sourceBytesPerRow = sourceBytesPerRow ?? width * 4
            self.yCbCrMatrix = yCbCrMatrix
            self.colorPrimaries = colorPrimaries
            self.transferFunction = transferFunction
        }
    }

    public struct Score: Sendable {
        public let rgbPSNR: CorpusGates.ChannelPSNR
        public let lumaSSIM: Double
    }

    public static func read(_ pixelBuffer: CVPixelBuffer) throws -> Frame {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            throw VideoQualityReadbackError.invalidDimensions
        }

        if CVPixelBufferGetPixelFormatType(pixelBuffer)
            == kCVPixelFormatType_32BGRA {
            return try readBGRA(pixelBuffer, width: width, height: height)
        }

        var destination: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary,
            &destination)
        guard createStatus == kCVReturnSuccess, let destination else {
            throw VideoQualityReadbackError.pixelBufferCreateFailed(createStatus)
        }
        var transfer: VTPixelTransferSession?
        let sessionStatus = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &transfer)
        guard sessionStatus == noErr, let transfer else {
            throw VideoQualityReadbackError
                .pixelTransferSessionCreateFailed(sessionStatus)
        }
        defer { VTPixelTransferSessionInvalidate(transfer) }
        let transferStatus = VTPixelTransferSessionTransferImage(
            transfer,
            from: pixelBuffer,
            to: destination)
        guard transferStatus == noErr else {
            throw VideoQualityReadbackError.pixelTransferFailed(transferStatus)
        }
        let converted = try readBGRA(
            destination, width: width, height: height)
        return Frame(
            width: width,
            height: height,
            bgra: converted.bgra,
            sourcePixelFormat: fourCC(
                CVPixelBufferGetPixelFormatType(pixelBuffer)),
            sourceBytesPerRow: converted.sourceBytesPerRow,
            yCbCrMatrix: attachment(
                pixelBuffer, key: kCVImageBufferYCbCrMatrixKey),
            colorPrimaries: attachment(
                pixelBuffer, key: kCVImageBufferColorPrimariesKey),
            transferFunction: attachment(
                pixelBuffer, key: kCVImageBufferTransferFunctionKey))
    }

    public static func score(
        referenceBGRX: [UInt8],
        referenceWidth: Int,
        referenceHeight: Int,
        decoded: Frame
    ) throws -> Score {
        guard decoded.width == referenceWidth,
              decoded.height == referenceHeight else {
            throw VideoQualityReadbackError.invalidDimensions
        }
        let expected = referenceWidth * referenceHeight * 4
        guard referenceBGRX.count == expected else {
            throw VideoQualityReadbackError.invalidReferenceSize(
                expected: expected, actual: referenceBGRX.count)
        }
        guard decoded.bgra.count == expected else {
            throw VideoQualityReadbackError.invalidReferenceSize(
                expected: expected, actual: decoded.bgra.count)
        }
        return Score(
            rgbPSNR: CorpusGates.rgbPSNR(
                reference: referenceBGRX,
                decoded: decoded.bgra,
                width: referenceWidth,
                height: referenceHeight),
            lumaSSIM: CorpusGates.ssim(
                reference: referenceBGRX,
                decoded: decoded.bgra,
                width: referenceWidth,
                height: referenceHeight))
    }

    private static func readBGRA(
        _ pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) throws -> Frame {
        let status = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard status == kCVReturnSuccess else {
            throw VideoQualityReadbackError.pixelBufferLockFailed(status)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw VideoQualityReadbackError.invalidDimensions
        }
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destinationStride = width * 4
        var bytes = [UInt8](repeating: 0, count: destinationStride * height)
        bytes.withUnsafeMutableBytes { destination in
            for row in 0..<height {
                destination.baseAddress!
                    .advanced(by: row * destinationStride)
                    .copyMemory(
                        from: base.advanced(by: row * sourceStride),
                        byteCount: destinationStride)
            }
        }
        return frame(
            pixelBuffer, width: width, height: height,
            bytesPerRow: sourceStride, bgra: bytes)
    }

    private static func frame(
        _ pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bgra: [UInt8]
    ) -> Frame {
        Frame(
            width: width,
            height: height,
            bgra: bgra,
            sourcePixelFormat: fourCC(
                CVPixelBufferGetPixelFormatType(pixelBuffer)),
            sourceBytesPerRow: bytesPerRow,
            yCbCrMatrix: attachment(
                pixelBuffer, key: kCVImageBufferYCbCrMatrixKey),
            colorPrimaries: attachment(
                pixelBuffer, key: kCVImageBufferColorPrimariesKey),
            transferFunction: attachment(
                pixelBuffer, key: kCVImageBufferTransferFunctionKey))
    }

    private static func attachment(
        _ pixelBuffer: CVPixelBuffer,
        key: CFString
    ) -> String? {
        var mode = CVAttachmentMode.shouldNotPropagate
        guard let value = CVBufferCopyAttachment(pixelBuffer, key, &mode) else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        return String(describing: value)
    }

    private static func fourCC(_ value: OSType) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii)
            ?? String(format: "0x%08x", value)
    }
}
