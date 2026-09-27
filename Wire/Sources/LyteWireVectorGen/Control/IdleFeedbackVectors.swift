// The key-17 vector-file model: `Wire/Vectors/idle-feedback-v1.json` —
// the idleFeedback capability spine. The cadence it permits is behavior,
// covered by the session machine and client reporter suites.

import LyteWire
import LyteWireTestKit

/// One vector file: `Wire/Vectors/idle-feedback-v1.json`.
public struct IdleFeedbackVectorFile: FrozenVectorFile {
    public var format = Self.expectedFormat
    public var formatVersion = 1
    public var wireVersion = 1
    public var vectors: [CapabilitySpineVector]

    public static let expectedFormat = "lyte-wire-idle-feedback-vectors"
    public static let fileName = "idle-feedback-v1.json"

    public var vectorNameGroups: [[String]] {
        [vectors.map(\.name)]
    }
}
