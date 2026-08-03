/// Client-side mirror of Scripts/motion-presenter.py — the byte-exact
/// twin of the GTK canvas that the benchmark puts on the host's glass.
///
/// The visible 24-bit marker picks the exact authored frame, preventing
/// accidental cross-phase PSNR/SSIM. Any edit here must land in the
/// presenter too: shared SHA-256 fixtures (SyntheticMotionReferenceTests
/// ↔ test_analyze_app_benchmark.py) fail loudly if the twins drift.
public struct SyntheticMotionReference: Sendable {
    public let width: Int
    public let height: Int
    private let base: [UInt8]

    public init(width: Int, height: Int) {
        precondition(width >= 960 && height >= 600)
        self.width = width
        self.height = height
        var background = [UInt8](repeating: 0, count: width * height * 4)
        // The definition's background [18, 12, 32] is (r, g, b), exactly
        // as the GTK canvas reads it: BGRA bytes 32, 12, 18, 255.
        background.withUnsafeMutableBytes { raw in
            raw.bindMemory(to: UInt32.self)
                .initialize(repeating: 0xFF12_0C20)
        }
        for x in stride(from: 0, to: width, by: 64) {
            for y in 0..<height {
                let offset = (y * width + x) * 4
                background[offset] = 74
                background[offset + 1] = 74
                background[offset + 2] = 74
            }
        }
        for y in stride(from: 0, to: height, by: 64) {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                background[offset] = 74
                background[offset + 1] = 74
                background[offset + 2] = 74
            }
        }
        self.base = background
    }

    public func marker(in bgra: [UInt8]) -> UInt32? {
        guard bgra.count == width * height * 4, width >= 624 else { return nil }
        func bright(_ block: Int) -> Bool {
            let offset = ((12 * width) + block * 24 + 12) * 4
            return Int(bgra[offset]) + Int(bgra[offset + 1])
                + Int(bgra[offset + 2]) >= 384
        }
        guard bright(0), bright(25) else { return nil }
        var value: UInt32 = 0
        for bit in 0..<24 where bright(bit + 1) {
            value |= UInt32(1) << UInt32(bit)
        }
        return value
    }

    public func frame(_ frameID: UInt32) -> [UInt8] {
        var bytes = base
        // Definition colors in the authored (r, g, b) order — the same
        // order the GTK canvas feeds Gdk.RGBA.
        let colors: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (255, 54, 92), (36, 220, 255), (255, 224, 48),
            (116, 255, 88), (210, 72, 255),
        ]
        let frame = Int(frameID)
        for (index, color) in colors.enumerated() {
            let x = (frame * 7 + index * 313) % width
            let y = (frame * 5 + index * 197) % height
            fill(&bytes, x: x, y: 0, width: min(5, width - x),
                 height: height, b: color.b, g: color.g, r: color.r)
            fill(&bytes, x: 0, y: y, width: width,
                 height: min(5, height - y),
                 b: color.b, g: color.g, r: color.r)
        }
        // The glass draws fixed geometry (the init precondition keeps it
        // in frame): 240×150 box, 12 px inset, 168 px square.
        let boxWidth = 240
        let boxHeight = 150
        let boxX = bounce(frame, 11, width, boxWidth)
        let boxY = bounce(frame, 7, height, boxHeight)
        fill(&bytes, x: boxX, y: boxY, width: boxWidth, height: boxHeight,
             b: colors[0].b, g: colors[0].g, r: colors[0].r)
        fill(&bytes, x: boxX + 12, y: boxY + 12,
             width: boxWidth - 24, height: boxHeight - 24,
             b: colors[1].b, g: colors[1].g, r: colors[1].r)
        let radius = 84
        let shapeX = bounce(frame, -9, width, radius * 2)
        let shapeY = bounce(frame, 13, height, radius * 2)
        fill(&bytes, x: shapeX, y: shapeY, width: radius * 2,
             height: radius * 2, b: colors[3].b, g: colors[3].g,
             r: colors[3].r)
        drawMarker(frameID, into: &bytes)
        return bytes
    }

    private func drawMarker(_ frameID: UInt32, into bytes: inout [UInt8]) {
        fill(&bytes, x: 0, y: 0, width: 24, height: 24,
             b: 255, g: 255, r: 0)
        for bit in 0..<24 {
            let on = frameID & (UInt32(1) << UInt32(bit)) != 0
            let sample: UInt8 = on ? 255 : 0
            fill(&bytes, x: (bit + 1) * 24, y: 0, width: 24, height: 24,
                 b: sample, g: sample, r: sample)
        }
        fill(&bytes, x: 600, y: 0, width: 24, height: 24,
             b: 255, g: 0, r: 255)
    }

    private func bounce(
        _ frame: Int, _ speed: Int, _ extent: Int, _ objectExtent: Int
    ) -> Int {
        let span = max(1, extent - objectExtent)
        let phase = (frame * abs(speed)) % (2 * span)
        let position = phase <= span ? phase : 2 * span - phase
        return speed >= 0 ? position : span - position
    }

    private func fill(
        _ bytes: inout [UInt8],
        x: Int, y: Int, width fillWidth: Int, height fillHeight: Int,
        b: UInt8, g: UInt8, r: UInt8
    ) {
        guard fillWidth > 0, fillHeight > 0 else { return }
        for row in y..<min(y + fillHeight, height) {
            var offset = (row * width + x) * 4
            for _ in x..<min(x + fillWidth, width) {
                bytes[offset] = b
                bytes[offset + 1] = g
                bytes[offset + 2] = r
                bytes[offset + 3] = 255
                offset += 4
            }
        }
    }
}
