// Lifecycle-message vector authoring (W4b): the mode transition 0x09
// and the session teardown 0x0A. Run once, commit, freeze. The
// circularity is broken by the hand-computed anchor bytes in
// SessionLifecycleCodecTests, which pin the same nominal messages.

import LyteCore
import LyteWire
import LyteWireTestKit

func makeLifecycleVectorFile() throws -> LifecycleVectorFile {
    var vectors: [LifecycleVector] = []

    // MARK: Round trips — every legal value of both codecs.

    for mode in SessionWireMode.allCases {
        let message = ModeTransition(mode: mode)
        vectors.append(LifecycleVector(
            name: "mode-\(mode == .active ? "active" : "idle")",
            description: "Mode transition to \(mode == .active ? "ACTIVE" : "IDLE")"
                + (mode == .active
                    ? " — the WAKE flip, IDR pre-armed."
                    : " — sent only after the converged frame's one-shot"
                        + " is acknowledged."),
            kind: .roundtrip,
            codec: .modeTransition,
            messageHex: Hex.string(message.encode()),
            value: mode.rawValue
        ))
    }

    for reason in SessionTeardownReason.allCases {
        let message = SessionTeardown(reason: reason)
        vectors.append(LifecycleVector(
            name: "teardown-\(reason == .takenOver ? "taken-over" : "shutting-down")",
            description: reason == .takenOver
                ? "Teardown: taken-over-by — the transport pillar's"
                    + " multi-client ruling."
                : "Teardown: orderly local shutdown.",
            kind: .roundtrip,
            codec: .sessionTeardown,
            messageHex: Hex.string(message.encode()),
            value: reason.rawValue
        ))
    }

    // MARK: Decode rejects

    vectors.append(LifecycleVector(
        name: "mode-truncated",
        description: "The type byte alone — a mode transition is exactly"
            + " 2 bytes.",
        kind: .decodeReject, codec: .modeTransition,
        messageHex: "09", error: "truncatedMessage"
    ))
    vectors.append(LifecycleVector(
        name: "mode-trailing-byte",
        description: "3 bytes where the message is exactly its layout.",
        kind: .decodeReject, codec: .modeTransition,
        messageHex: "090100", error: "trailingBytes"
    ))
    vectors.append(LifecycleVector(
        name: "mode-bad-type",
        description: "A teardown type byte fed to the mode decoder.",
        kind: .decodeReject, codec: .modeTransition,
        messageHex: "0a01", error: "unexpectedType"
    ))
    vectors.append(LifecycleVector(
        name: "mode-zero",
        description: "Mode 0x00 — the loud zero-fill bug, never a value.",
        kind: .decodeReject, codec: .modeTransition,
        messageHex: "0900", error: "unknownMode"
    ))
    vectors.append(LifecycleVector(
        name: "mode-unknown",
        description: "Mode 0x03 — FROZEN/RECOVERY are local overlay"
            + " states, never wire values.",
        kind: .decodeReject, codec: .modeTransition,
        messageHex: "0903", error: "unknownMode"
    ))
    vectors.append(LifecycleVector(
        name: "teardown-truncated",
        description: "The type byte alone — a teardown is exactly"
            + " 2 bytes.",
        kind: .decodeReject, codec: .sessionTeardown,
        messageHex: "0a", error: "truncatedMessage"
    ))
    vectors.append(LifecycleVector(
        name: "teardown-trailing-byte",
        description: "3 bytes where the message is exactly its layout.",
        kind: .decodeReject, codec: .sessionTeardown,
        messageHex: "0a0200", error: "trailingBytes"
    ))
    vectors.append(LifecycleVector(
        name: "teardown-bad-type",
        description: "A mode type byte fed to the teardown decoder.",
        kind: .decodeReject, codec: .sessionTeardown,
        messageHex: "0901", error: "unexpectedType"
    ))
    vectors.append(LifecycleVector(
        name: "teardown-zero",
        description: "Reason 0x00 — the loud zero-fill bug, never a"
            + " value.",
        kind: .decodeReject, codec: .sessionTeardown,
        messageHex: "0a00", error: "unknownReason"
    ))
    vectors.append(LifecycleVector(
        name: "teardown-unknown",
        description: "Reason 0x7f — unassigned reasons reject.",
        kind: .decodeReject, codec: .sessionTeardown,
        messageHex: "0a7f", error: "unknownReason"
    ))

    return LifecycleVectorFile(
        format: LifecycleVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        vectors: vectors
    )
}
