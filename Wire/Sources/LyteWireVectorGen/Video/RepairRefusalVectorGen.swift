// Authors Vectors/repair-refusal-v1.json: the repair-refusal CTRL
// message (0x23). Roundtrip bytes come from the codec; reject bytes are
// hand-built.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeRepairRefusalVectorFile() throws -> RepairRefusalVectorFile {
    var vectors: [RepairRefusalVector] = []
    vectors.append(RepairRefusalVector(
        name: "refusal-stale-budget",
        description: "6-byte refusal: type 0x23, frame 258 u32 LE, reason 0x01 stale-budget — the hand-computed anchor.",
        kind: .roundtrip,
        messageHex: Hex.string(RepairRefusal(
            frame: FrameNumber(rawValue: 258), reason: .staleBudget
        ).encode()),
        frame: 258,
        reason: 1
    ))
    vectors.append(RepairRefusalVector(
        name: "refusal-superseded",
        description: "Reason 0x02 superseded: the frame is older than the last IDR — the newer IDR is the heal.",
        kind: .roundtrip,
        messageHex: Hex.string(RepairRefusal(
            frame: FrameNumber(rawValue: 77), reason: .superseded
        ).encode()),
        frame: 77,
        reason: 2
    ))
    vectors.append(RepairRefusalVector(
        name: "refusal-unknown-frame",
        description: "Reason 0x03 unknown-frame: the repair store no longer holds the frame.",
        kind: .roundtrip,
        messageHex: Hex.string(RepairRefusal(
            frame: FrameNumber(rawValue: 3735928559), reason: .unknownFrame
        ).encode()),
        frame: 3735928559,
        reason: 3
    ))
    vectors.append(RepairRefusalVector(
        name: "refusal-frame-zero",
        description: "Frame 0 is legal — the opening frame is exactly the one the exemption story cares about.",
        kind: .roundtrip,
        messageHex: Hex.string(RepairRefusal(
            frame: FrameNumber(rawValue: 0), reason: .staleBudget
        ).encode()),
        frame: 0,
        reason: 1
    ))
    vectors.append(RepairRefusalVector(
        name: "refusal-frame-max",
        description: "Frame u32-max — the numbering boundary.",
        kind: .roundtrip,
        messageHex: Hex.string(RepairRefusal(
            frame: FrameNumber(rawValue: 4294967295), reason: .superseded
        ).encode()),
        frame: 4294967295,
        reason: 2
    ))
    vectors.append(RepairRefusalVector(
        name: "refusal-truncated",
        description: "5 bytes: the message is exactly its layout.",
        kind: .decodeReject,
        messageHex: "2302010000",
        error: "truncatedMessage"
    ))
    vectors.append(RepairRefusalVector(
        name: "refusal-trailing-byte",
        description: "7 bytes reject — exactly its fixed size.",
        kind: .decodeReject,
        messageHex: "23020100000100",
        error: "trailingBytes"
    ))
    vectors.append(RepairRefusalVector(
        name: "refusal-bad-type",
        description: "An IDR-request type byte at refusal length rejects with what it found.",
        kind: .decodeReject,
        messageHex: "100201000001",
        error: "unexpectedType"
    ))
    vectors.append(RepairRefusalVector(
        name: "refusal-reason-zero",
        description: "Reason 0x00 rejects — the loud zero-fill bug.",
        kind: .decodeReject,
        messageHex: "230201000000",
        error: "unknownReason"
    ))
    vectors.append(RepairRefusalVector(
        name: "refusal-reason-unknown",
        description: "Reason 0x7f rejects — the reason space is exactly its three values.",
        kind: .decodeReject,
        messageHex: "23020100007f",
        error: "unknownReason"
    ))
    return RepairRefusalVectorFile(
        format: RepairRefusalVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        vectors: vectors
    )
}
