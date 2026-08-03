// Clipboard-codec vector authoring (CL-15, the first H3 feature): the
// clipboard-text pair 0x1A/0x1B and the key-10 capability spine —
// codecs born in the registry rather than promoted, frozen at their
// birth slice. Run once, commit, freeze. The circularity is broken by
// the hand-computed anchor bytes in ClipboardCodecTests, which pin the
// same nominal messages.

import LyteCore
import LyteWire
import LyteWireTestKit

func makeClipboardVectorFile() throws -> ClipboardVectorFile {
    var vectors: [ClipboardVector] = []

    // MARK: Roundtrips — ASCII, multi-byte UTF-8, the exact ceiling

    let hello = "hello"
    vectors.append(ClipboardVector(
        name: "set-ascii-nominal",
        description: "type ‖ utf8: [0x1A] + \"hello\" — the "
            + "hand-computed anchor.",
        kind: .roundtrip, codec: .clipboardSet,
        messageHex: Hex.string(try ClipboardSet(text: hello).encode()),
        textUtf8Hex: Hex.string(Array(hello.utf8))
    ))
    vectors.append(ClipboardVector(
        name: "announce-ascii-nominal",
        description: "type ‖ utf8: [0x1B] + \"hello\" — the same body "
            + "under the host→client type.",
        kind: .roundtrip, codec: .clipboardAnnounce,
        messageHex: Hex.string(try ClipboardAnnounce(text: hello).encode()),
        textUtf8Hex: Hex.string(Array(hello.utf8))
    ))
    // Multi-byte UTF-8: 2-, 3-, and 4-byte sequences in one text
    // ("é" C3A9, "€" E282AC, "🙂" F09F9982).
    let unicode = "é€🙂"
    vectors.append(ClipboardVector(
        name: "set-multibyte-utf8",
        description: "2-, 3-, and 4-byte UTF-8 sequences round-trip "
            + "byte-exact (é € 🙂).",
        kind: .roundtrip, codec: .clipboardSet,
        messageHex: Hex.string(try ClipboardSet(text: unicode).encode()),
        textUtf8Hex: Hex.string(Array(unicode.utf8))
    ))
    vectors.append(ClipboardVector(
        name: "announce-multibyte-utf8",
        description: "The same multi-byte text under 0x1B.",
        kind: .roundtrip, codec: .clipboardAnnounce,
        messageHex: Hex.string(try ClipboardAnnounce(text: unicode).encode()),
        textUtf8Hex: Hex.string(Array(unicode.utf8))
    ))
    // The exact 65,536-byte ceiling: printable ASCII cycling pattern
    // (byte i = 0x20 + i % 0x5F), auditable by eye in a hex dump.
    let ceiling = String(decoding: (0..<ClipboardWire.maxTextByteCount).map {
        UInt8(0x20 + $0 % 0x5F)
    }, as: UTF8.self)
    vectors.append(ClipboardVector(
        name: "set-max-budget",
        description: "Exactly 65,536 UTF-8 bytes (printable-ASCII "
            + "cycle, byte i = 0x20 + i mod 0x5F) — the ceiling is "
            + "legal to the byte.",
        kind: .roundtrip, codec: .clipboardSet,
        messageHex: Hex.string(try ClipboardSet(text: ceiling).encode()),
        textUtf8Hex: Hex.string(Array(ceiling.utf8))
    ))

    // MARK: Decode rejects

    vectors.append(ClipboardVector(
        name: "set-empty-payload",
        description: "An empty payload rejects — there is no type byte "
            + "to dispatch on.",
        kind: .decodeReject, codec: .clipboardSet,
        messageHex: "",
        error: "truncatedMessage"
    ))
    vectors.append(ClipboardVector(
        name: "set-empty-text",
        description: "The bare type byte rejects — v1 does not sync "
            + "clearing, and an empty body is a zero-fill-adjacent bug.",
        kind: .decodeReject, codec: .clipboardSet,
        messageHex: "1a",
        error: "emptyText"
    ))
    vectors.append(ClipboardVector(
        name: "announce-empty-text",
        description: "Same rule under 0x1B.",
        kind: .decodeReject, codec: .clipboardAnnounce,
        messageHex: "1b",
        error: "emptyText"
    ))
    vectors.append(ClipboardVector(
        name: "set-cross-type",
        description: "An announce fed to the set decoder rejects with "
            + "what it found — they never cross-decode (the "
            + "role-confusion drop's codec half).",
        kind: .decodeReject, codec: .clipboardSet,
        messageHex: Hex.string([0x1B] + Array(hello.utf8)),
        error: "unexpectedType"
    ))
    vectors.append(ClipboardVector(
        name: "announce-cross-type",
        description: "A set fed to the announce decoder rejects the "
            + "same way.",
        kind: .decodeReject, codec: .clipboardAnnounce,
        messageHex: Hex.string([0x1A] + Array(hello.utf8)),
        error: "unexpectedType"
    ))
    vectors.append(ClipboardVector(
        name: "set-foreign-type",
        description: "A stranger's type byte (0x7F) rejects.",
        kind: .decodeReject, codec: .clipboardSet,
        messageHex: Hex.string([0x7F] + Array(hello.utf8)),
        error: "unexpectedType"
    ))
    vectors.append(ClipboardVector(
        name: "set-over-budget",
        description: "65,537 UTF-8 bytes reject — one byte past the "
            + "ceiling.",
        kind: .decodeReject, codec: .clipboardSet,
        messageHex: Hex.string(
            [0x1A] + [UInt8](repeating: 0x61,
                             count: ClipboardWire.maxTextByteCount + 1)
        ),
        error: "textOverBudget"
    ))
    vectors.append(ClipboardVector(
        name: "set-invalid-utf8-lone-byte",
        description: "0xFF is never valid UTF-8 — rejects, never "
            + "replaces (a clipboard must carry exactly what was "
            + "copied or nothing).",
        kind: .decodeReject, codec: .clipboardSet,
        messageHex: "1a68ff69",
        error: "invalidUtf8"
    ))
    vectors.append(ClipboardVector(
        name: "announce-invalid-utf8-truncated-sequence",
        description: "A 2-byte sequence's lead byte (0xC3) with no "
            + "continuation rejects.",
        kind: .decodeReject, codec: .clipboardAnnounce,
        messageHex: "1b61c3",
        error: "invalidUtf8"
    ))

    // MARK: Capability key 10 (the forward-compat spine as data —
    // the key-9 file's precedent)

    vectors.append(ClipboardVector(
        name: "capability-key10-declared",
        description: "wireDefault's frozen encoding plus exactly the "
            + "appended `0A F5` entry (map head 0xA8 → 0xA9): the "
            + "clipboardText accessor must read true and the set must "
            + "re-encode byte-exactly — the \"no frozen bytes moved\" "
            + "claim as data.",
        kind: .roundtrip, codec: .capabilitySet,
        messageHex: Hex.string(
            try Capabilities.wireDefault.declaringClipboardText()
                .encodeCbor()
        ),
        clipboardText: true
    ))
    vectors.append(ClipboardVector(
        name: "capability-key10-absent",
        description: "wireDefault's frozen encoding unchanged: absence "
            + "reads false — \"not supported\", never an error.",
        kind: .roundtrip, codec: .capabilitySet,
        messageHex: Hex.string(try Capabilities.wireDefault.encodeCbor()),
        clipboardText: false
    ))
    vectors.append(ClipboardVector(
        name: "capability-key9-and-key10",
        description: "Both spine keys together: map head 0xAA with "
            + "`09 F5 0A F5` trailing in canonical order — the two "
            + "features compose without moving each other's bytes.",
        kind: .roundtrip, codec: .capabilitySet,
        messageHex: Hex.string(
            try Capabilities.wireDefault
                .declaringHostAudioRouting()
                .declaringClipboardText()
                .encodeCbor()
        ),
        clipboardText: true
    ))

    return ClipboardVectorFile(
        format: ClipboardVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        vectors: vectors
    )
}
