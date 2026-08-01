/// Client-side mirror of HostCore.SyntheticMotionSource.
///
/// It exists only for the debug motion gate: the visible 24-bit marker picks
/// the exact authored frame, preventing accidental cross-phase PSNR/SSIM.
public struct SyntheticMotionReference: Sendable {
    public let width: Int
    public let height: Int
    private let base: [UInt8]

    public init(width: Int, height: Int) {
        precondition(width >= 640 && height >= 360)
        self.width = width
        self.height = height
        var background = [UInt8](repeating: 0, count: width * height * 4)
        background.withUnsafeMutableBytes { raw in
            raw.bindMemory(to: UInt32.self)
                .initialize(repeating: 0xFF20_0C12)
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
        let colors: [(UInt8, UInt8, UInt8)] = [
            (255, 54, 92), (36, 220, 255), (255, 224, 48),
            (116, 255, 88), (210, 72, 255),
        ]
        let frame = Int(frameID)
        for (index, color) in colors.enumerated() {
            let x = (frame * 7 + index * 313) % width
            let y = (frame * 5 + index * 197) % height
            fill(&bytes, x: x, y: 0, width: min(5, width - x),
                 height: height, b: color.0, g: color.1, r: color.2)
            fill(&bytes, x: 0, y: y, width: width,
                 height: min(5, height - y),
                 b: color.0, g: color.1, r: color.2)
        }
        let boxWidth = min(240, width / 4)
        let boxHeight = min(150, height / 4)
        let boxX = bounce(frame, 11, width, boxWidth)
        let boxY = bounce(frame, 7, height, boxHeight)
        fill(&bytes, x: boxX, y: boxY, width: boxWidth, height: boxHeight,
             b: colors[0].0, g: colors[0].1, r: colors[0].2)
        fill(&bytes, x: boxX + 12, y: boxY + 12,
             width: max(1, boxWidth - 24), height: max(1, boxHeight - 24),
             b: colors[1].0, g: colors[1].1, r: colors[1].2)
        let shapeSize = min(168, min(width, height) / 5)
        let shapeX = bounce(frame, -9, width, shapeSize)
        let shapeY = bounce(frame, 13, height, shapeSize)
        fill(&bytes, x: shapeX, y: shapeY, width: shapeSize,
             height: shapeSize, b: colors[3].0, g: colors[3].1,
             r: colors[3].2)
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
