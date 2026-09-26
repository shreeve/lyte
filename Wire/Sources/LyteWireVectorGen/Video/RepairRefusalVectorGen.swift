// Authors Vectors/repair-refusal-v1.json: the repair-refusal CTRL
// message (0x23). Roundtrip bytes come from the codec; reject bytes are
// hand-built.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeRepairRefusalVectorFile() throws -> RepairRefusalVectorFile {
    var vectors: [RepairRefusalVector] = []
    for (name, description, frame, reason) in [
        ("refusal-stale-budget",
         "6-byte refusal: type 0x23, frame 258 u32 LE, reason 0x01 stale-budget — the hand-computed anchor.",
         258, RepairRefusalReason.staleBudget),
        ("refusal-superseded",
         "Reason 0x02 superseded: the frame is older than the last IDR — the newer IDR is the heal.",
         77, .superseded),
        ("refusal-unknown-frame",
         "Reason 0x03 unknown-frame: the repair store no longer holds the frame.",
         3735928559, .unknownFrame),
        ("refusal-frame-zero",
         "Frame 0 is legal — the opening frame is exactly the one the exemption story cares about.",
         0, .staleBudget),
        ("refusal-frame-max", "Frame u32-max — the numbering boundary.",
         UInt32.max, .superseded),
    ] as [(String, String, UInt32, RepairRefusalReason)] {
        vectors.append(RepairRefusalVector(
            name: name, description: description, kind: .roundtrip,
            messageHex: Hex.string(RepairRefusal(
                frame: FrameNumber(rawValue: frame), reason: reason
            ).encode()),
            frame: frame, reason: reason.rawValue
        ))
    }
    for (name, description, hex, error) in [
        ("refusal-truncated", "5 bytes: the message is exactly its layout.",
         "2302010000", "truncatedMessage"),
        ("refusal-trailing-byte", "7 bytes reject — exactly its fixed size.",
         "23020100000100", "trailingBytes"),
        ("refusal-bad-type",
         "An IDR-request type byte at refusal length rejects with what it found.",
         "100201000001", "unexpectedType"),
        ("refusal-reason-zero", "Reason 0x00 rejects — the loud zero-fill bug.",
         "230201000000", "unknownReason"),
        ("refusal-reason-unknown",
         "Reason 0x7f rejects — the reason space is exactly its three values.",
         "23020100007f", "unknownReason"),
    ] {
        vectors.append(RepairRefusalVector(
            name: name, description: description, kind: .decodeReject,
            messageHex: hex, error: error
        ))
    }
    return RepairRefusalVectorFile(vectors: vectors)
}
