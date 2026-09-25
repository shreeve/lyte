// Authors Vectors/lifecycle-v1.json: the mode transition 0x09 and the
// session teardown 0x0A. Anchored by SessionLifecycleCodecTests.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeLifecycleVectorFile() throws -> LifecycleVectorFile {
    var vectors: [LifecycleVector] = []

    // MARK: Round trips — every legal value of both codecs.

    for (mode, name, description) in [
        (SessionWireMode.active, "mode-active",
         "Mode transition to ACTIVE — the WAKE flip, IDR pre-armed."),
        (.idle, "mode-idle",
         "Mode transition to IDLE — sent only after the converged frame's one-shot is acknowledged."),
    ] {
        vectors.append(LifecycleVector(
            name: name, description: description,
            kind: .roundtrip, codec: .modeTransition,
            messageHex: Hex.string(ModeTransition(mode: mode).encode()),
            value: mode.rawValue
        ))
    }
    for (reason, name, description) in [
        (SessionTeardownReason.takenOver, "teardown-taken-over",
         "Teardown: taken-over-by — the transport pillar's multi-client ruling."),
        (.shuttingDown, "teardown-shutting-down",
         "Teardown: orderly local shutdown."),
    ] {
        vectors.append(LifecycleVector(
            name: name, description: description,
            kind: .roundtrip, codec: .sessionTeardown,
            messageHex: Hex.string(SessionTeardown(reason: reason).encode()),
            value: reason.rawValue
        ))
    }

    // MARK: Decode rejects

    let rejects: [(String, LifecycleVector.LifecycleCodec, String, String, String)] = [
        ("mode-truncated", .modeTransition,
         "The type byte alone — a mode transition is exactly 2 bytes.",
         "09", "truncatedMessage"),
        ("mode-trailing-byte", .modeTransition,
         "3 bytes where the message is exactly its layout.",
         "090100", "trailingBytes"),
        ("mode-bad-type", .modeTransition,
         "A teardown type byte fed to the mode decoder.",
         "0a01", "unexpectedType"),
        ("mode-zero", .modeTransition,
         "Mode 0x00 — the loud zero-fill bug, never a value.",
         "0900", "unknownMode"),
        ("mode-unknown", .modeTransition,
         "Mode 0x03 — FROZEN/RECOVERY are local overlay states, never wire values.",
         "0903", "unknownMode"),
        ("teardown-truncated", .sessionTeardown,
         "The type byte alone — a teardown is exactly 2 bytes.",
         "0a", "truncatedMessage"),
        ("teardown-trailing-byte", .sessionTeardown,
         "3 bytes where the message is exactly its layout.",
         "0a0200", "trailingBytes"),
        ("teardown-bad-type", .sessionTeardown,
         "A mode type byte fed to the teardown decoder.",
         "0901", "unexpectedType"),
        ("teardown-zero", .sessionTeardown,
         "Reason 0x00 — the loud zero-fill bug, never a value.",
         "0a00", "unknownReason"),
        ("teardown-unknown", .sessionTeardown,
         "Reason 0x7f — unassigned reasons reject.",
         "0a7f", "unknownReason"),
    ]
    for (name, codec, description, hex, error) in rejects {
        vectors.append(LifecycleVector(
            name: name, description: description,
            kind: .decodeReject, codec: codec,
            messageHex: hex, error: error
        ))
    }

    return LifecycleVectorFile(vectors: vectors)
}
