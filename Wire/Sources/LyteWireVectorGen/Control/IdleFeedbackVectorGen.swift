// Authors Vectors/idle-feedback-v1.json: the key-17 (idleFeedback)
// capability spine declared, absent, and beside key 16, the video quiet
// posture whose still screen idle feedback exists for. Anchored by
// IdleFeedbackVectorFileTests.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeIdleFeedbackVectorFile() throws -> IdleFeedbackVectorFile {
    IdleFeedbackVectorFile(vectors: try [
        ("capability-key17-declared",
         "wireDefault's frozen encoding plus exactly the appended `11 F5` "
            + "entry (map head 0xA8 → 0xA9): idleFeedback reads true and "
            + "the set re-encodes byte-exactly.",
         Capabilities.wireDefault.declaringIdleFeedback()),
        ("capability-key17-absent",
         "wireDefault's frozen encoding unchanged: idleFeedback reads "
            + "false — \"not supported\", so the client keeps its 25–50 ms "
            + "report cadence.",
         Capabilities.wireDefault),
        ("capability-key16-and-key17",
         "Video quiet and idle feedback together: map head 0xAA with "
            + "`10 F5 11 F5` trailing in canonical order.",
         Capabilities.wireDefault.declaringIdleFeedback()
            .declaringVideoQuietPosture()),
    ].map { name, description, set in
        CapabilitySpineVector(
            name: name, description: description,
            messageHex: Hex.string(try set.encodeCbor()),
            flags: [
                "idleFeedback": set.idleFeedback,
                "videoQuietPosture": set.videoQuietPosture,
            ]
        )
    })
}
