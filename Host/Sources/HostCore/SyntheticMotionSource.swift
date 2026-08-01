/// Debug-only deterministic BGRX source used to isolate the production
/// encode/wire/client pipeline from PipeWire and the desktop compositor.
///
/// This is deliberately pixels-only policy: the executable owns pacing and
/// labels every run synthetic. Normal sessions never instantiate it.
public struct SyntheticMotionSource: Sendable {
    public let width: Int
    public let height: Int
    private let base: [UInt8]

    public init(width: Int, height: Int) {
        precondition(width >= 640)
        precondition(height >= 360)
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

    public var byteCount: Int { width * height * 4 }

    public func render(frameID: UInt32, into bytes: inout [UInt8]) {
        bytes = base
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
        let boxX = bounce(frame: frame, speed: 11, extent: width,
                          objectExtent: boxWidth)
        let boxY = bounce(frame: frame, speed: 7, extent: height,
                          objectExtent: boxHeight)
        fill(&bytes, x: boxX, y: boxY, width: boxWidth, height: boxHeight,
             b: colors[0].0, g: colors[0].1, r: colors[0].2)
        fill(&bytes, x: boxX + 12, y: boxY + 12,
             width: max(1, boxWidth - 24), height: max(1, boxHeight - 24),
             b: colors[1].0, g: colors[1].1, r: colors[1].2)

        let shapeSize = min(168, min(width, height) / 5)
        let shapeX = bounce(frame: frame, speed: -9, extent: width,
                            objectExtent: shapeSize)
        let shapeY = bounce(frame: frame, speed: 13, extent: height,
                            objectExtent: shapeSize)
        fill(&bytes, x: shapeX, y: shapeY, width: shapeSize,
             height: shapeSize, b: colors[3].0, g: colors[3].1,
             r: colors[3].2)

        drawMarker(frameID: frameID, into: &bytes)
    }

    public func decodedMarker(in bytes: [UInt8]) -> UInt32? {
        guard bytes.count == byteCount else { return nil }
        let block = 24
        guard width >= 26 * block, height >= block else { return nil }
        func bright(_ blockIndex: Int) -> Bool {
            let x = blockIndex * block + block / 2
            let y = block / 2
            let offset = (y * width + x) * 4
            return Int(bytes[offset]) + Int(bytes[offset + 1])
                + Int(bytes[offset + 2]) >= 384
        }
        var value: UInt32 = 0
        for bit in 0..<24 where bright(bit + 1) {
            value |= UInt32(1) << UInt32(bit)
        }
        return value
    }

    private func drawMarker(frameID: UInt32, into bytes: inout [UInt8]) {
        let block = 24
        guard width >= 26 * block, height >= block else { return }
        fill(&bytes, x: 0, y: 0, width: block, height: block,
             b: 255, g: 255, r: 0)
        for bit in 0..<24 {
            let on = frameID & (UInt32(1) << UInt32(bit)) != 0
            let sample: UInt8 = on ? 255 : 0
            fill(&bytes, x: (bit + 1) * block, y: 0,
                 width: block, height: block,
                 b: sample, g: sample, r: sample)
        }
        fill(&bytes, x: 25 * block, y: 0, width: block, height: block,
             b: 255, g: 0, r: 255)
    }

    private func bounce(
        frame: Int, speed: Int, extent: Int, objectExtent: Int
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

/// Absolute-deadline schedule for the synthetic source.
public struct SyntheticMotionSchedule: Sendable, Equatable {
    public let startNanoseconds: UInt64
    public let intervalNanoseconds: UInt64

    public init(startNanoseconds: UInt64, fps: UInt64 = 60) {
        precondition(fps > 0)
        self.startNanoseconds = startNanoseconds
        self.intervalNanoseconds = 1_000_000_000 / fps
    }

    public func deadline(frameID: UInt32) -> UInt64 {
        startNanoseconds
            &+ UInt64(frameID) &* intervalNanoseconds
    }
}
