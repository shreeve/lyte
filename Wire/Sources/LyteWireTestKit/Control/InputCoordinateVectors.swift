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
