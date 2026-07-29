// CorpusPNG (H4 V-3): lossless PNG in/out for the §7 harness's visual
// goldens and corpus previews. Everything rides the harness's one
// buffer convention — 4 bytes per pixel, B,G,R in bytes 0/1/2 — and
// the round trip is byte-exact on those three channels (gate-tested):
// the write context and the read context use the identical sRGB
// BGRX layout, so no color conversion ever touches the samples.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CorpusPNGError: Error, CustomStringConvertible {
    case contextCreateFailed
    case imageCreateFailed
    case writeFailed(String)
    case readFailed(String)
    case sizeMismatch(String, expected: String, got: String)

    public var description: String {
        switch self {
        case .contextCreateFailed: return "CGContext creation failed"
        case .imageCreateFailed: return "CGImage creation failed"
        case .writeFailed(let path): return "PNG write failed: \(path)"
        case .readFailed(let path): return "PNG read failed: \(path)"
        case .sizeMismatch(let path, let expected, let got):
            return "\(path): expected \(expected), got \(got)"
        }
    }
}

public enum CorpusPNG {
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
        | CGImageAlphaInfo.noneSkipFirst.rawValue

    /// Writes a packed BGRX/BGRA buffer as an opaque sRGB PNG.
    public static func write(bgrx: [UInt8], width: Int, height: Int, to path: String) throws {
        var pixels = bgrx
        guard let context = pixels.withUnsafeMutableBytes({ buf -> CGContext? in
            CGContext(data: buf.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: bitmapInfo)
        }) else {
            throw CorpusPNGError.contextCreateFailed
        }
        guard let image = context.makeImage() else {
            throw CorpusPNGError.imageCreateFailed
        }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(
            url, UTType.png.identifier as CFString, 1, nil) else {
            throw CorpusPNGError.writeFailed(path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CorpusPNGError.writeFailed(path)
        }
    }

    /// Reads a PNG back into the same packed BGRX layout. The draw
    /// target matches the write context exactly — byte-stable round
    /// trip on B/G/R.
    public static func read(from path: String, expectedWidth: Int? = nil,
                     expectedHeight: Int? = nil) throws
        -> (bgrx: [UInt8], width: Int, height: Int) {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CorpusPNGError.readFailed(path)
        }
        let width = image.width
        let height = image.height
        if let ew = expectedWidth, let eh = expectedHeight,
           width != ew || height != eh {
            throw CorpusPNGError.sizeMismatch(
                path, expected: "\(ew)x\(eh)", got: "\(width)x\(height)")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buf in
            guard let context = CGContext(
                data: buf.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: bitmapInfo) else {
                throw CorpusPNGError.contextCreateFailed
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (pixels, width, height)
    }
}
