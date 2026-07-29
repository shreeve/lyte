// CorpusFrames (H4 V-3): the §7 verification corpus as deterministic
// pixel math — the image-quality pillar's test content, versioned
// in-repo (docs/20260720-191701-lyte-protocol-image-quality.md §7):
//
//   (a) dense monospaced terminal text, white-on-black AND
//       syntax-highlighted (saturated single-pixel strokes — the
//       chroma worst case), at 100/125/200% zoom;
//   (b) a 1-px checkerboard + single-pixel color gratings;
//   (c) 16-step and 256-step gradients (the banding witness);
//   (d) black/white/primary flat patches (range round-trip witness);
//   (e) one photographic frame (procedural — natural statistics from
//       seeded value noise, so the corpus stays code, not a binary).
//
// Every frame is a pure function of (width, height): no fonts, no
// ffmpeg, no platform rasterizer — the same bytes on every machine,
// forever. Glyphs are a hand-drawn 5×7 bitmap face embedded below;
// zoom is nearest-neighbor dst→src mapping (fractional 125% produces
// the uneven stroke widths real display scaling produces — that is
// the point, and it stays deterministic). The corpus is FROZEN by
// hash-pinned gate tests: a changed pin is a corpus-contract change
// to discuss, not a drift to absorb.
//
// Pixel format: packed BGRX ("bgr0"), byte order B,G,R,0 — exactly
// what the capture path hands the encoder and what lyte-encode-check
// feeds the production C leaf.

import Foundation

// MARK: - Manifest vocabulary (Codable — corpus-gen writes, corpus-gate reads)

public struct CorpusRect: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A flat patch with its authored color — the range round-trip
/// witness. `tolerance` is the pillar's gate: 0 for black/white
/// (0=0, 255=255, byte-exact), 1 for primaries. `gated` false marks
/// informational patches (mid-gray) that report but never fail.
public struct CorpusPatch: Codable, Equatable, Sendable {
    public var name: String
    public var rect: CorpusRect
    public var red: Int
    public var green: Int
    public var blue: Int
    public var tolerance: Int
    public var gated: Bool

    public init(name: String, rect: CorpusRect, red: Int, green: Int,
                blue: Int, tolerance: Int, gated: Bool) {
        self.name = name
        self.rect = rect
        self.red = red
        self.green = green
        self.blue = blue
        self.tolerance = tolerance
        self.gated = gated
    }
}

/// A single-pixel grating (or checkerboard) region — the chroma
/// torture. The gate is per-channel error ≤ ±2 codes over the region.
public struct CorpusGrating: Codable, Equatable, Sendable {
    public var name: String
    public var rect: CorpusRect

    public init(name: String, rect: CorpusRect) {
        self.name = name
        self.rect = rect
    }
}

public enum CorpusFrameKind: String, Codable, Sendable {
    case text, gratings, gradients, patches, photo
}

public struct CorpusFrameSpec: Codable, Equatable, Sendable {
    public var name: String
    public var kind: CorpusFrameKind
    /// Raw BGRX file name inside the corpus directory.
    public var file: String
    /// Glyph-band rects for the text-region PSNR gate (text frames).
    public var textRegions: [CorpusRect]
    public var gratings: [CorpusGrating]
    public var patches: [CorpusPatch]

    public init(name: String, kind: CorpusFrameKind, file: String,
                textRegions: [CorpusRect] = [],
                gratings: [CorpusGrating] = [],
                patches: [CorpusPatch] = []) {
        self.name = name
        self.kind = kind
        self.file = file
        self.textRegions = textRegions
        self.gratings = gratings
        self.patches = patches
    }
}

public struct CorpusManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var width: Int
    public var height: Int
    public var frames: [CorpusFrameSpec]

    public init(version: Int, width: Int, height: Int, frames: [CorpusFrameSpec]) {
        self.version = version
        self.width = width
        self.height = height
        self.frames = frames
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> CorpusManifest {
        try JSONDecoder().decode(CorpusManifest.self, from: data)
    }
}

// MARK: - The generator

public enum CorpusFrames {
    /// The reference-pair session geometry (V-1's probe posture).
    public static let defaultWidth = 2048
    public static let defaultHeight = 1280
    /// Bump only with a wire-worthy discussion: the corpus is a frozen
    /// measurement contract, not a fixture (Wire/Vectors doctrine).
    public static let corpusVersion = 1

    public struct GeneratedFrame: Sendable {
        public let spec: CorpusFrameSpec
        /// Packed BGRX, width × height × 4.
        public let bgrx: [UInt8]
    }

    public static func generate(width: Int = defaultWidth,
                                height: Int = defaultHeight) -> [GeneratedFrame] {
        [
            textFrame(width: width, height: height, zoomName: "100", scale: 1.0),
            textFrame(width: width, height: height, zoomName: "125", scale: 1.25),
            textFrame(width: width, height: height, zoomName: "200", scale: 2.0),
            gratingsFrame(width: width, height: height),
            gradientsFrame(width: width, height: height),
            patchesFrame(width: width, height: height),
            photoFrame(width: width, height: height),
        ]
    }

    public static func manifest(width: Int = defaultWidth,
                                height: Int = defaultHeight,
                                frames: [GeneratedFrame]) -> CorpusManifest {
        CorpusManifest(version: corpusVersion, width: width, height: height,
                       frames: frames.map(\.spec))
    }

    // MARK: - Canvas

    private struct Canvas {
        var px: [UInt8]
        let w: Int
        let h: Int

        init(width: Int, height: Int) {
            w = width
            h = height
            px = [UInt8](repeating: 0, count: width * height * 4)
        }

        @inline(__always)
        mutating func set(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            let i = (y * w + x) * 4
            px[i] = b
            px[i + 1] = g
            px[i + 2] = r
        }

        mutating func fill(_ rect: CorpusRect, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            for y in rect.y..<min(rect.y + rect.height, h) {
                for x in rect.x..<min(rect.x + rect.width, w) {
                    set(x, y, r, g, b)
                }
            }
        }
    }

    /// Deterministic 64-bit LCG (Knuth MMIX) — the only randomness in
    /// the corpus, fully seeded.
    private struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        mutating func next(_ bound: Int) -> Int {
            Int(next() % UInt64(bound))
        }
    }

    // MARK: - (a) Text frames

    /// Hand-drawn 5×7 face, MSB-left rows. The alphabet is hex-shaped
    /// on purpose: dense code-like lines from a tiny embedded face,
    /// single-pixel strokes throughout.
    private static let glyphs: [Character: [UInt8]] = [
        "0": [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110],
        "1": [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
        "2": [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111],
        "3": [0b01110, 0b10001, 0b00001, 0b00110, 0b00001, 0b10001, 0b01110],
        "4": [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],
        "5": [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110],
        "6": [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],
        "7": [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],
        "8": [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
        "9": [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100],
        "A": [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        "B": [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110],
        "C": [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110],
        "D": [0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110],
        "E": [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111],
        "F": [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000],
        "X": [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001],
        " ": [0, 0, 0, 0, 0, 0, 0],
        "=": [0, 0b11111, 0, 0b11111, 0, 0, 0],
        "(": [0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010],
        ")": [0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000],
        "+": [0, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0],
        "-": [0, 0, 0, 0b11111, 0, 0, 0],
        "*": [0, 0b10101, 0b01110, 0b11111, 0b01110, 0b10101, 0],
        "/": [0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000],
        ";": [0, 0b00100, 0, 0, 0b00100, 0b00100, 0b01000],
        ",": [0, 0, 0, 0, 0b00100, 0b00100, 0b01000],
        ".": [0, 0, 0, 0, 0, 0b01100, 0b01100],
        "_": [0, 0, 0, 0, 0, 0, 0b11111],
        "{": [0b00110, 0b00100, 0b00100, 0b01000, 0b00100, 0b00100, 0b00110],
        "}": [0b01100, 0b00100, 0b00100, 0b00010, 0b00100, 0b00100, 0b01100],
        "#": [0b01010, 0b11111, 0b01010, 0b01010, 0b01010, 0b11111, 0b01010],
        "\"": [0b01010, 0b01010, 0b01010, 0, 0, 0, 0],
    ]

    private static let cellW = 6
    private static let cellH = 9

    /// The saturated syntax palette — full-saturation single-pixel
    /// strokes are the 4:2:0-killing worst case the pillar names.
    /// Index 0 (white) doubles as the white-on-black block's only color.
    private static let palette: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (255, 255, 255), // 0 identifier / plain
        (0, 255, 255),   // 1 number / hex literal
        (255, 255, 0),   // 2 operator / punctuation
        (255, 0, 255),   // 3 brace / structure
        (0, 255, 0),     // 4 comment
        (255, 0, 0),     // 5 string
    ]

    private static let idents = [
        "FACE", "BEAD", "C0DE", "FEED", "BABE", "CAFE", "F00D", "DEAD",
        "DECADE", "EFFACE", "ACCEDE", "FACADE", "BEEF", "ABBA", "D00DAD",
        "DEFACED", "BAD_ACE", "0DDBA11",
    ]

    /// One dense code-shaped line: (character, palette index) cells,
    /// exactly `columns` wide.
    private static func makeLine(columns: Int, rng: inout LCG,
                                 syntax: Bool) -> [(Character, UInt8)] {
        var cells: [(Character, UInt8)] = []
        func add(_ s: String, _ color: UInt8) {
            for ch in s { cells.append((ch, syntax ? color : 0)) }
        }
        func ident() -> String { idents[rng.next(idents.count)] }
        func hexLit(_ digits: Int) -> String {
            let alphabet = Array("0123456789ABCDEF")
            return "0X" + String((0..<digits).map { _ in alphabet[rng.next(16)] })
        }
        func num() -> String { String(rng.next(9000) + 1) }

        var comment = false
        while cells.count < columns {
            if comment {
                add(ident(), 4)
                add(" ", 4)
                add(hexLit(4).dropFirst(2).description, 4)
                add(" ", 4)
                continue
            }
            switch rng.next(4) {
            case 0:
                add(ident(), 0); add(" ", 0); add("=", 2); add(" ", 0)
                add("(", 2); add(ident(), 0); add(" ", 0); add("+", 2)
                add(" ", 0); add(hexLit(4), 1); add(")", 2); add(" ", 0)
                add("*", 2); add(" ", 0); add(num(), 1); add(";", 2)
                add(" ", 0)
            case 1:
                add("{", 3); add(ident(), 0); add(".", 2); add("_", 0)
                add(ident(), 0); add("}", 3); add(" ", 0); add("=", 2)
                add(" ", 0); add(ident(), 0); add("/", 2); add(num(), 1)
                add(" ", 0); add("-", 2); add(" ", 0); add(hexLit(2), 1)
                add(";", 2); add(" ", 0)
            case 2:
                add(ident(), 0); add("(", 2); add(num(), 1); add(",", 2)
                add(" ", 0); add(hexLit(4), 1); add(",", 2); add(" ", 0)
                add("\"", 5); add(ident(), 5); add("\"", 5); add(")", 2)
                add(";", 2); add(" ", 0)
            default:
                add("# ", 4)
                comment = true
            }
        }
        return Array(cells.prefix(columns))
    }

    private static func textFrame(width: Int, height: Int,
                                  zoomName: String, scale: Double) -> GeneratedFrame {
        var canvas = Canvas(width: width, height: height)
        var rng = LCG(seed: 0x4C59_5445_5633_0000 | UInt64(zoomName.utf8.reduce(0) { $0 &+ UInt64($1) }))

        let margin = 16
        let blockGap = 16
        let availW = width - 2 * margin
        let blockH = (height - 2 * margin - blockGap) / 2

        var regions: [CorpusRect] = []
        for (block, syntax) in [(0, false), (1, true)] {
            let srcCols = Int(Double(availW) / scale) / cellW
            let srcRows = Int(Double(blockH) / scale) / cellH
            guard srcCols > 0, srcRows > 0 else { continue }
            let lines = (0..<srcRows).map { _ in
                makeLine(columns: srcCols, rng: &rng, syntax: syntax)
            }
            let dstW = Int(Double(srcCols * cellW) * scale)
            let dstH = Int(Double(srcRows * cellH) * scale)
            let ox = margin
            let oy = margin + block * (blockH + blockGap)
            for dy in 0..<dstH {
                let sy = Int(Double(dy) / scale)
                let line = sy / cellH
                let glyphRow = sy % cellH
                guard glyphRow < 7, line < lines.count else { continue }
                for dx in 0..<dstW {
                    let sx = Int(Double(dx) / scale)
                    let col = sx / cellW
                    let glyphCol = sx % cellW
                    guard glyphCol < 5, col < lines[line].count else { continue }
                    let (ch, colorIdx) = lines[line][col]
                    guard let rows = glyphs[ch],
                          rows[glyphRow] & (1 << (4 - glyphCol)) != 0 else { continue }
                    let c = palette[Int(colorIdx)]
                    canvas.set(ox + dx, oy + dy, c.r, c.g, c.b)
                }
            }
            regions.append(CorpusRect(x: ox, y: oy, width: dstW, height: dstH))
        }

        let name = "text-\(zoomName)"
        return GeneratedFrame(
            spec: CorpusFrameSpec(name: name, kind: .text, file: "\(name).raw",
                                  textRegions: regions),
            bgrx: canvas.px)
    }

    // MARK: - (b) Gratings frame

    private static func gratingsFrame(width: Int, height: Int) -> GeneratedFrame {
        var canvas = Canvas(width: width, height: height)
        let margin = 32
        let cols = 4
        let rows = 2
        let cw = (width - (cols + 1) * margin) / cols
        let ch = (height - (rows + 1) * margin) / rows

        typealias RGB = (r: UInt8, g: UInt8, b: UInt8)
        // (name, colorA, colorB, vertical stripes?)
        let cells: [(String, RGB, RGB, Bool)] = [
            ("checker-1px", (0, 0, 0), (255, 255, 255), true), // special-cased below
            ("v-red-blue", (255, 0, 0), (0, 0, 255), true),
            ("v-green-magenta", (0, 255, 0), (255, 0, 255), true),
            ("v-blue-yellow", (0, 0, 255), (255, 255, 0), true),
            ("h-red-blue", (255, 0, 0), (0, 0, 255), false),
            ("h-green-magenta", (0, 255, 0), (255, 0, 255), false),
            ("h-red-cyan", (255, 0, 0), (0, 255, 255), false),
            ("v-red-green", (255, 0, 0), (0, 255, 0), true),
        ]

        var gratings: [CorpusGrating] = []
        for (i, cell) in cells.enumerated() {
            let (name, a, b, vertical) = cell
            let rect = CorpusRect(
                x: margin + (i % cols) * (cw + margin),
                y: margin + (i / cols) * (ch + margin),
                width: cw, height: ch)
            for y in rect.y..<(rect.y + rect.height) {
                for x in rect.x..<(rect.x + rect.width) {
                    let phase: Int
                    if name == "checker-1px" {
                        phase = (x + y) % 2
                    } else {
                        phase = (vertical ? x : y) % 2
                    }
                    let c = phase == 0 ? a : b
                    canvas.set(x, y, c.r, c.g, c.b)
                }
            }
            gratings.append(CorpusGrating(name: name, rect: rect))
        }

        return GeneratedFrame(
            spec: CorpusFrameSpec(name: "gratings", kind: .gratings,
                                  file: "gratings.raw", gratings: gratings),
            bgrx: canvas.px)
    }

    // MARK: - (c) Gradients frame

    private static func gradientsFrame(width: Int, height: Int) -> GeneratedFrame {
        var canvas = Canvas(width: width, height: height)
        let margin = 16
        // (steps, channel mask r/g/b)
        let bands: [(steps: Int, r: Bool, g: Bool, b: Bool)] = [
            (256, true, true, true),
            (16, true, true, true),
            (256, true, false, false),
            (256, false, true, false),
            (256, false, false, true),
            (16, false, true, true), // 16-step cyan ramp — chroma banding witness
        ]
        let bandH = (height - (bands.count + 1) * margin) / bands.count
        for (i, band) in bands.enumerated() {
            let y0 = margin + i * (bandH + margin)
            for x in margin..<(width - margin) {
                let t = Double(x - margin) / Double(width - 2 * margin - 1)
                let step = min(band.steps - 1, Int(t * Double(band.steps)))
                let v = UInt8(step * 255 / (band.steps - 1))
                for y in y0..<(y0 + bandH) {
                    canvas.set(x, y, band.r ? v : 0, band.g ? v : 0, band.b ? v : 0)
                }
            }
        }
        return GeneratedFrame(
            spec: CorpusFrameSpec(name: "gradients", kind: .gradients,
                                  file: "gradients.raw"),
            bgrx: canvas.px)
    }

    // MARK: - (d) Patches frame

    private static func patchesFrame(width: Int, height: Int) -> GeneratedFrame {
        var canvas = Canvas(width: width, height: height)
        // Neutral mid-gray field so every patch has a real edge.
        canvas.fill(CorpusRect(x: 0, y: 0, width: width, height: height), 128, 128, 128)

        // (name, r, g, b, tolerance, gated)
        let defs: [(String, Int, Int, Int, Int, Bool)] = [
            ("black", 0, 0, 0, 0, true),
            ("white", 255, 255, 255, 0, true),
            ("red", 255, 0, 0, 1, true),
            ("green", 0, 255, 0, 1, true),
            ("blue", 0, 0, 255, 1, true),
            ("gray-128", 128, 128, 128, 1, false), // informational — mid-range witness
        ]
        let cols = 3
        let rows = 2
        let cellW = width / cols
        let cellH = height / rows
        let patchW = cellW * 3 / 4
        let patchH = cellH * 3 / 4
        var patches: [CorpusPatch] = []
        for (i, def) in defs.enumerated() {
            let (name, r, g, b, tol, gated) = def
            let rect = CorpusRect(
                x: (i % cols) * cellW + (cellW - patchW) / 2,
                y: (i / cols) * cellH + (cellH - patchH) / 2,
                width: patchW, height: patchH)
            canvas.fill(rect, UInt8(r), UInt8(g), UInt8(b))
            patches.append(CorpusPatch(name: name, rect: rect, red: r, green: g,
                                       blue: b, tolerance: tol, gated: gated))
        }
        return GeneratedFrame(
            spec: CorpusFrameSpec(name: "patches", kind: .patches,
                                  file: "patches.raw", patches: patches),
            bgrx: canvas.px)
    }

    // MARK: - (e) Photographic frame (procedural)

    /// Deterministic 2D lattice hash → [0, 1).
    private static func hash01(_ x: Int, _ y: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F
        h = (h ^ (h >> 31)) &* 0x94D0_49BB_1331_11EB
        h ^= h >> 33
        return Double(h % 1_048_576) / 1_048_576.0
    }

    /// Bilinear value noise at lattice spacing `cell`.
    private static func valueNoise(_ x: Int, _ y: Int, cell: Int, seed: Int) -> Double {
        let gx = x / cell, gy = y / cell
        let fx = Double(x % cell) / Double(cell)
        let fy = Double(y % cell) / Double(cell)
        let a = hash01(gx &+ seed, gy)
        let b = hash01(gx &+ seed &+ 1, gy)
        let c = hash01(gx &+ seed, gy &+ 1)
        let d = hash01(gx &+ seed &+ 1, gy &+ 1)
        let sx = fx * fx * (3 - 2 * fx)
        let sy = fy * fy * (3 - 2 * fy)
        let top = a + (b - a) * sx
        let bottom = c + (d - c) * sx
        return top + (bottom - top) * sy
    }

    private static func photoFrame(width: Int, height: Int) -> GeneratedFrame {
        var canvas = Canvas(width: width, height: height)
        let fw = Double(width), fh = Double(height)
        let horizonBase = 0.58

        for y in 0..<height {
            let ty = Double(y) / fh
            for x in 0..<width {
                let tx = Double(x) / fw
                // Rolling ridge line: two sine octaves.
                let ridge = horizonBase
                    + 0.05 * sin(tx * 9.2 + 1.3)
                    + 0.025 * sin(tx * 23.7 + 4.1)
                var r: Double, g: Double, b: Double
                if ty < ridge {
                    // Sky: vertical gradient with soft cloud noise + sun glow.
                    let t = ty / ridge
                    r = 110 + 120 * t
                    g = 155 + 65 * t
                    b = 220 - 25 * t
                    let cloud = valueNoise(x, y, cell: 160, seed: 7)
                        * valueNoise(x, y, cell: 48, seed: 19)
                    r += 60 * cloud
                    g += 55 * cloud
                    b += 30 * cloud
                    let dx = tx - 0.74, dy = ty - 0.22
                    let sun = max(0, 1 - sqrt(dx * dx + dy * dy * 2.4) * 6)
                    r += 120 * sun
                    g += 100 * sun
                    b += 40 * sun
                } else {
                    // Ground: green-brown with two-octave texture, darkening
                    // toward the ridge (distance haze in reverse).
                    let depth = (ty - ridge) / max(0.0001, 1 - ridge)
                    let n = 0.65 * valueNoise(x, y, cell: 96, seed: 41)
                        + 0.35 * valueNoise(x, y, cell: 12, seed: 97)
                    r = 60 + 70 * depth + 55 * n
                    g = 85 + 60 * depth + 70 * n
                    b = 45 + 35 * depth + 40 * n
                }
                canvas.set(x, y,
                           UInt8(max(0, min(255, r))),
                           UInt8(max(0, min(255, g))),
                           UInt8(max(0, min(255, b))))
            }
        }
        return GeneratedFrame(
            spec: CorpusFrameSpec(name: "photo", kind: .photo, file: "photo.raw"),
            bgrx: canvas.px)
    }
}
