// CorpusGates (H4 V-3): the §7 acceptance math with the pillar's
// thresholds PINNED IN CODE (docs/20260720-191701-lyte-protocol-
// image-quality.md §7) — "gate thresholds pinned in code, not prose"
// is the V-3 gate. Every metric compares in RGB space after full
// decode (YUV-domain PSNR hides exactly the chroma and range bugs the
// harness exists to catch).
//
// Buffer convention throughout: 4 bytes per pixel with B,G,R in bytes
// 0/1/2 — packed BGRX (the corpus reference) and packed BGRA (the
// VideoToolbox readback via decode-probe --pixel-format bgra) share
// that layout, so reference and decoded index identically. Byte 3
// (X/alpha) is never compared.

import Foundation

public enum CorpusGates {
    // MARK: - The pinned thresholds (§7 verbatim)

    /// Text-region RGB PSNR (per-channel min), Work-mode active phase.
    public static let textActiveMinDB = 40.0
    /// Text-region RGB PSNR (per-channel min), post-ratchet.
    public static let textConvergedMinDB = 50.0
    /// Full-frame SSIM post-ratchet, corpus kinds (a)–(c).
    public static let ssimConvergedMin = 0.995
    /// Per-channel error at grating edges, Work mode, in codes.
    public static let gratingMaxCodes = 2
    /// Ratchet convergence budget at LAN surplus: ≤ 3 s at 60 fps.
    public static let convergenceMaxFrames = 180
    /// Owner decision 2 (2026-07-29): rgb_mode 601-limited ships and
    /// the byte-exact range round-trip is NAMED-AND-QUEUED (the
    /// full-range conversion leaf / 10-bit rung). Under the limited601
    /// posture the patch gate allows one extra code — the measured
    /// cost of the limited-range quantization round trip — while the
    /// raw deltas keep being reported against the pillar's exact bar.
    public static let limited601PatchAllowance = 1
    /// Patch interiors are measured inset from the authored rect —
    /// codec ringing at a patch EDGE is not a range-round-trip failure.
    public static let patchInset = 16
    /// Grating regions are inset to keep neighbor-region blend out.
    public static let gratingInset = 8

    // MARK: - RGB PSNR (per-channel, region-scoped)

    public struct ChannelPSNR: Sendable {
        public let r: Double
        public let g: Double
        public let b: Double
        public var minChannel: Double { min(r, min(g, b)) }
    }

    /// Per-channel PSNR over `regions` (nil = full frame). Infinity
    /// means byte-identical in that channel.
    public static func rgbPSNR(reference: [UInt8], decoded: [UInt8],
                               width: Int, height: Int,
                               regions: [CorpusRect]? = nil) -> ChannelPSNR {
        var sums = [0.0, 0.0, 0.0] // b, g, r channel order (byte order)
        var count = 0
        let rects = regions ?? [CorpusRect(x: 0, y: 0, width: width, height: height)]
        reference.withUnsafeBufferPointer { ref in
            decoded.withUnsafeBufferPointer { dec in
                for rect in rects {
                    for y in rect.y..<min(rect.y + rect.height, height) {
                        for x in rect.x..<min(rect.x + rect.width, width) {
                            let i = (y * width + x) * 4
                            for c in 0..<3 {
                                let d = Double(Int(ref[i + c]) - Int(dec[i + c]))
                                sums[c] += d * d
                            }
                            count += 1
                        }
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

    // MARK: - Range round-trip (patches) and chroma fidelity (gratings)

    public struct RegionError: Sendable {
        /// Max |decoded − expected| per channel, in codes.
        public let maxR: Int
        public let maxG: Int
        public let maxB: Int
        /// Pixels with any channel beyond the gate's tolerance.
        public let offendersBeyondGate: Int
        public var maxChannel: Int { max(maxR, max(maxG, maxB)) }
    }

    /// Max per-channel deviation of `decoded` from the patch's AUTHORED
    /// color over the inset patch interior — the range witness compares
    /// against intent, not against the reference frame. `tolerance`
    /// overrides the patch's authored bar (the limited601 posture).
    public static func patchError(decoded: [UInt8], width: Int, height: Int,
                                  patch: CorpusPatch,
                                  inset: Int = patchInset,
                                  tolerance: Int? = nil) -> RegionError {
        regionError(decoded: decoded, width: width, height: height,
                    rect: insetRect(patch.rect, by: inset),
                    tolerance: tolerance ?? patch.tolerance) { _, _ in
            (patch.red, patch.green, patch.blue)
        }
    }

    /// Max per-channel deviation of `decoded` from `reference` over the
    /// inset grating region — every pixel of a 1-px grating is an edge.
    public static func gratingError(reference: [UInt8], decoded: [UInt8],
                                    width: Int, height: Int, rect: CorpusRect,
                                    inset: Int = gratingInset) -> RegionError {
        reference.withUnsafeBufferPointer { ref in
            regionError(decoded: decoded, width: width, height: height,
                        rect: insetRect(rect, by: inset),
                        tolerance: gratingMaxCodes) { x, y in
                let i = (y * width + x) * 4
                return (Int(ref[i + 2]), Int(ref[i + 1]), Int(ref[i]))
            }
        }
    }

    private static func insetRect(_ rect: CorpusRect, by inset: Int) -> CorpusRect {
        CorpusRect(x: rect.x + inset, y: rect.y + inset,
                   width: max(0, rect.width - 2 * inset),
                   height: max(0, rect.height - 2 * inset))
    }

    private static func regionError(
        decoded: [UInt8], width: Int, height: Int, rect: CorpusRect,
        tolerance: Int,
        expected: (Int, Int) -> (r: Int, g: Int, b: Int)
    ) -> RegionError {
        var maxR = 0, maxG = 0, maxB = 0, offenders = 0
        decoded.withUnsafeBufferPointer { dec in
            for y in rect.y..<min(rect.y + rect.height, height) {
                for x in rect.x..<min(rect.x + rect.width, width) {
                    let i = (y * width + x) * 4
                    let (er, eg, eb) = expected(x, y)
                    let dr = abs(Int(dec[i + 2]) - er)
                    let dg = abs(Int(dec[i + 1]) - eg)
                    let db = abs(Int(dec[i]) - eb)
                    maxR = max(maxR, dr)
                    maxG = max(maxG, dg)
                    maxB = max(maxB, db)
                    if dr > tolerance || dg > tolerance || db > tolerance {
                        offenders += 1
                    }
                }
            }
        }
        return RegionError(maxR: maxR, maxG: maxG, maxB: maxB,
                           offendersBeyondGate: offenders)
    }

    // MARK: - Ratchet convergence (from the encoder's per-frame size books)

    public struct SizeBookEntry: Sendable {
        public let bytes: Int
        public let qp: Int
        public init(bytes: Int, qp: Int) {
            self.bytes = bytes
            self.qp = qp
        }
    }

    /// The convergence detector on a static-repeat leg's size books:
    /// the first frame index from which every later frame sits on the
    /// keepalive plateau — QP-identical to the last frame and within
    /// ±⅛ (min ±16 B) of its byte size. Synthetic corpus keepalives
    /// are byte-IDENTICAL; natural content (the photo frame) hovers by
    /// a few bytes at converged QP, and that hover is convergence, not
    /// a walk. Requires the plateau to run at least `minStableTail`
    /// frames (1 s at 60 fps) — a trivially stable final frame is not
    /// convergence. Nil = never converged.
    public static func convergenceFrame(sizes: [SizeBookEntry],
                                        minStableTail: Int = 60) -> Int? {
        guard let last = sizes.last else { return nil }
        let tolerance = max(16, last.bytes / 8)
        var start = sizes.count - 1
        while start > 0,
              abs(sizes[start - 1].bytes - last.bytes) <= tolerance,
              sizes[start - 1].qp == last.qp {
            start -= 1
        }
        guard sizes.count - start >= minStableTail else { return nil }
        return start
    }

    /// Parses lyte-encode-check --sizes books ("idx key bytes qp" rows).
    public static func parseSizeBook(_ text: String) -> [SizeBookEntry] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ")
            guard f.count >= 4, let bytes = Int(f[2]), let qp = Int(f[3]) else {
                return nil
            }
            return SizeBookEntry(bytes: bytes, qp: qp)
        }
    }

    // MARK: - Golden diff

    public struct GoldenDiff: Sendable {
        public let maxAbs: Int
        public let differingPixels: Int
        public var isEmpty: Bool { differingPixels == 0 }
    }

    /// Byte-compare of two 4-byte-per-pixel images on the B/G/R
    /// channels (byte 3 skipped). A non-empty diff is the "human
    /// looks" trigger, never an automatic failure by itself.
    public static func goldenDiff(candidate: [UInt8], golden: [UInt8]) -> GoldenDiff? {
        guard candidate.count == golden.count, candidate.count % 4 == 0 else {
            return nil
        }
        var maxAbs = 0
        var differing = 0
        candidate.withUnsafeBufferPointer { a in
            golden.withUnsafeBufferPointer { b in
                var i = 0
                while i < a.count {
                    let d0 = abs(Int(a[i]) - Int(b[i]))
                    let d1 = abs(Int(a[i + 1]) - Int(b[i + 1]))
                    let d2 = abs(Int(a[i + 2]) - Int(b[i + 2]))
                    let m = max(d0, max(d1, d2))
                    if m > 0 {
                        differing += 1
                        maxAbs = max(maxAbs, m)
                    }
                    i += 4
                }
            }
        }
        return GoldenDiff(maxAbs: maxAbs, differingPixels: differing)
    }
}