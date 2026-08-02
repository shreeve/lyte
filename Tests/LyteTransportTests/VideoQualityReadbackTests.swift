import CoreVideo
import VideoToolbox
import LyteCorpus
import XCTest
@testable import LyteTransport

final class VideoQualityReadbackTests: XCTestCase {
    func testBGRAReadbackPreservesRowsAndScoresCorpusPixels() throws {
        let width = 8
        let height = 8
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                [
                    kCVPixelBufferBytesPerRowAlignmentKey:
                        64
                ] as CFDictionary,
                &pixelBuffer),
            kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        var reference = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = [UInt8(x * 11), UInt8(y * 13), UInt8((x + y) * 7), 0]
                let source = y * stride + x * 4
                let destination = (y * width + x) * 4
                for channel in 0..<4 {
                    base[source + channel] = pixel[channel]
                    reference[destination + channel] = pixel[channel]
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let decoded = try VideoQualityReadback.read(buffer)
        XCTAssertEqual(decoded.width, width)
        XCTAssertEqual(decoded.height, height)
        XCTAssertEqual(decoded.bgra, reference)

        let score = try VideoQualityReadback.score(
            referenceBGRX: reference,
            referenceWidth: width,
            referenceHeight: height,
            decoded: decoded)
        XCTAssertTrue(score.rgbPSNR.minChannel.isInfinite)
        XCTAssertEqual(score.lumaSSIM, 1, accuracy: 0.000_001)
    }

    func testScoreRejectsScalingInsteadOfHidingIt() {
        let decoded = VideoQualityReadback.Frame(
            width: 4,
            height: 4,
            bgra: [UInt8](repeating: 0, count: 4 * 4 * 4))
        XCTAssertThrowsError(
            try VideoQualityReadback.score(
                referenceBGRX: [UInt8](repeating: 0, count: 8 * 8 * 4),
                referenceWidth: 8,
                referenceHeight: 8,
                decoded: decoded))
    }

    func testNative444ReadbackUsesPixelTransferWithoutGreenCollapse() throws {
        let width = 64
        let height = 64
        var source: CVPixelBuffer?
        var native444: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_32BGRA, attrs, &source),
            kCVReturnSuccess)
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
                attrs, &native444),
            kCVReturnSuccess)
        let bgra = try XCTUnwrap(source)
        let yuv = try XCTUnwrap(native444)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(bgra, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(bgra))
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(bgra)
        var reference = [UInt8](repeating: 0, count: width * height * 4)
        let colors: [[UInt8]] = [
            [32, 48, 220, 255],
            [220, 180, 24, 255],
            [180, 32, 128, 255],
            [48, 210, 72, 255],
        ]
        for y in 0..<height {
            for x in 0..<width {
                let pixel = colors[(x / 16 + y / 16) % colors.count]
                let sourceIndex = y * stride + x * 4
                let referenceIndex = (y * width + x) * 4
                for channel in 0..<4 {
                    base[sourceIndex + channel] = pixel[channel]
                    reference[referenceIndex + channel] = pixel[channel]
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(bgra, [])

        var transfer: VTPixelTransferSession?
        XCTAssertEqual(
            VTPixelTransferSessionCreate(
                allocator: kCFAllocatorDefault,
                pixelTransferSessionOut: &transfer),
            noErr)
        let session = try XCTUnwrap(transfer)
        defer { VTPixelTransferSessionInvalidate(session) }
        XCTAssertEqual(
            VTPixelTransferSessionTransferImage(
                session, from: bgra, to: yuv),
            noErr)

        let decoded = try VideoQualityReadback.read(yuv)
        let score = try VideoQualityReadback.score(
            referenceBGRX: reference,
            referenceWidth: width,
            referenceHeight: height,
            decoded: decoded)
        XCTAssertGreaterThan(
            score.rgbPSNR.minChannel, 35,
            "native 4:4:4 conversion must not reintroduce Core Image's "
                + "green-only ~26 dB collapse")
    }
}
