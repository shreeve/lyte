// Full-frame image-quality metrics for the diagnostic benchmark. Both
// compare in RGB after full decode: YUV-domain PSNR hides exactly the
// chroma and range bugs a readback exists to catch.
//
// Buffers are 4 bytes per pixel with B,G,R in bytes 0/1/2 (packed BGRX
// reference, packed BGRA readback); byte 3 is never compared.

import Foundation

public enum CorpusGates {
    public struct ChannelPSNR: Sendable {
        public let r: Double
        public let g: Double
        public let b: Double
        public var minChannel: Double { min(r, min(g, b)) }
    }

    /// Per-channel PSNR over the whole frame. Infinity means
    /// byte-identical in that channel.
    public static func rgbPSNR(reference: [UInt8], decoded: [UInt8],
                               width: Int, height: Int) -> ChannelPSNR {
        var sums = [0.0, 0.0, 0.0] // b, g, r channel order (byte order)
        let count = width * height
        reference.withUnsafeBufferPointer { ref in
            decoded.withUnsafeBufferPointer { dec in
                for pixel in 0..<count {
                    let i = pixel * 4
                    for c in 0..<3 {
                        let d = Double(Int(ref[i + c]) - Int(dec[i + c]))
                        sums[c] += d * d
                    }
                }
            }
        }
        func psnr(_ sum: Double) -> Double {
            guard count > 0 else { return 0 }
            let mse = sum / Double(count)
            guard mse > 0 else { return .infinity }
            return 10 * log10(255.0 * 255.0 / mse)
        }
        return ChannelPSNR(r: psnr(sums[2]), g: psnr(sums[1]), b: psnr(sums[0]))
    }

    // MARK: - SSIM (luma, 8×8 windows, stride 4 — the ffmpeg shape)

    /// Global SSIM on BT.709 luma over 8×8 windows stepped by 4.
    public static func ssim(reference: [UInt8], decoded: [UInt8],
                            width: Int, height: Int) -> Double {
        func luma(_ px: [UInt8]) -> [Double] {
            var out = [Double](repeating: 0, count: width * height)
            px.withUnsafeBufferPointer { p in
                for i in 0..<(width * height) {
                    let j = i * 4
                    out[i] = 0.0722 * Double(p[j]) + 0.7152 * Double(p[j + 1])
                        + 0.2126 * Double(p[j + 2])
                }
            }
            return out
        }
        let a = luma(reference)
        let b = luma(decoded)
        let c1 = (0.01 * 255) * (0.01 * 255)
        let c2 = (0.03 * 255) * (0.03 * 255)
        let win = 8, step = 4
        var total = 0.0
        var windows = 0
        var wy = 0
        while wy + win <= height {
            var wx = 0
            while wx + win <= width {
                var sumA = 0.0, sumB = 0.0, sumAA = 0.0, sumBB = 0.0, sumAB = 0.0
                for y in wy..<(wy + win) {
                    for x in wx..<(wx + win) {
                        let va = a[y * width + x]
                        let vb = b[y * width + x]
                        sumA += va
                        sumB += vb
                        sumAA += va * va
                        sumBB += vb * vb
                        sumAB += va * vb
                    }
                }
                let n = Double(win * win)
                let muA = sumA / n
                let muB = sumB / n
                let varA = sumAA / n - muA * muA
                let varB = sumBB / n - muB * muB
                let cov = sumAB / n - muA * muB
                total += ((2 * muA * muB + c1) * (2 * cov + c2))
                    / ((muA * muA + muB * muB + c1) * (varA + varB + c2))
                windows += 1
                wx += step
            }
            wy += step
        }
        return windows > 0 ? total / Double(windows) : 0
    }
}
