// The input-coordinate vector-file model and loader:
// `Wire/Vectors/input-coordinates-v1.json` — the f64 coordinate domain of
// InputEvent (0x16): finite extremes roundtrip, NaN and ±Inf reject. The
// vectors reuse the control file's `ControlVector` shape with
// `codec = inputEvent`.

import Foundation
import LyteWire

/// One vector file: `Wire/Vectors/input-coordinates-v1.json`.
public struct InputCoordinateVectorFile: FrozenVectorFile {
    public var format: String
    public var formatVersion: Int
    public var wireVersion: Int
    public var vectors: [ControlVector]

    public static let expectedFormat = "lyte-wire-input-coordinate-vectors"
    public static let fileName = "input-coordinates-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
    }

    public init(
        format: String,
        formatVersion: Int,
        wireVersion: Int,
        vectors: [ControlVector]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.wireVersion = wireVersion
        self.vectors = vectors
    }
}

extension InputEvent {
    /// This event's bytes with every coordinate's raw f64 bit pattern,
    /// NaN and ±Inf included — what a peer that skips the encoder's
    /// finiteness refusal would send, so decoder rejects stay testable.
    public func rawCoordinateBytes() -> [UInt8] {
        let coordinates: [Double]
        let finite: Body
        switch body {
        case .pointerMotionAbsolute(let x, let y):
            coordinates = [x, y]
            finite = .pointerMotionAbsolute(x: 0, y: 0)
        case .pointerMotionRelative(let dx, let dy):
            coordinates = [dx, dy]
            finite = .pointerMotionRelative(dx: 0, dy: 0)
        case .pointerAxis(let dx, let dy, let finish):
            coordinates = [dx, dy]
            finite = .pointerAxis(dx: 0, dy: 0, finish: finish)
        case .keyKeycode, .pointerButton:
            coordinates = []
            finite = body
        }
        // Finite coordinates only, so the encoder cannot refuse.
        var bytes = try! InputEvent(
            seq: seq, clientMicroseconds: clientMicroseconds, body: finite
        ).encode()
        for (slot, value) in coordinates.enumerated() {
            let offset = InputEvent.headerByteCount + 8 * slot
            for index in 0..<8 {
                bytes[offset + index] = UInt8(
                    truncatingIfNeeded: value.bitPattern >> (8 * index))
            }
        }
        return bytes
    }
}
