// Authors Vectors/clipboard-v1.json: the clipboard-text pair 0x1A/0x1B
// and the key-10 capability spine. Anchored by ClipboardCodecTests.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeClipboardVectorFile() throws -> ClipboardVectorFile {
    var vectors: [ClipboardVector] = []

    // MARK: Roundtrips — ASCII, multi-byte UTF-8, the exact ceiling

    let hello = "hello"
    // Multi-byte UTF-8: 2-, 3-, and 4-byte sequences in one text
    // ("é" C3A9, "€" E282AC, "🙂" F09F9982).
    let unicode = "é€🙂"
    for (name, description, codec, text) in [
        ("set-ascii-nominal",
         "type ‖ utf8: [0x1A] + \"hello\" — the hand-computed anchor.",
         ClipboardVector.ClipboardCodec.clipboardSet, hello),
        ("announce-ascii-nominal",
         "type ‖ utf8: [0x1B] + \"hello\" — the same body under the "
            + "host→client type.",
         .clipboardAnnounce, hello),
        ("set-multibyte-utf8",
         "2-, 3-, and 4-byte UTF-8 sequences round-trip byte-exact (é € 🙂).",
         .clipboardSet, unicode),
        ("announce-multibyte-utf8", "The same multi-byte text under 0x1B.",
         .clipboardAnnounce, unicode),
        ("set-max-budget",
         "Exactly 65,536 UTF-8 bytes (printable-ASCII cycle, byte i = 0x20 "
            + "+ i mod 0x5F) — the ceiling is legal to the byte.",
         .clipboardSet, printableASCII(count: ClipboardWire.maxTextByteCount)),
    ] {
        vectors.append(ClipboardVector(
            name: name, description: description,
            kind: .roundtrip, codec: codec,
            messageHex: Hex.string(codec == .clipboardSet
                ? try ClipboardSet(text: text).encode()
                : try ClipboardAnnounce(text: text).encode()),
            textUtf8Hex: Hex.string(Array(text.utf8))
        ))
    }

    // MARK: Decode rejects

    for (name, description, codec, hex, error) in [
        ("set-empty-payload",
         "An empty payload rejects — there is no type byte to dispatch on.",
         ClipboardVector.ClipboardCodec.clipboardSet, "", "truncatedMessage"),
        ("set-empty-text",
         "The bare type byte rejects — v1 does not sync clearing, and an "
            + "empty body is a zero-fill-adjacent bug.",
         .clipboardSet, "1a", "emptyText"),
        ("announce-empty-text", "Same rule under 0x1B.",
         .clipboardAnnounce, "1b", "emptyText"),
        ("set-cross-type",
         "An announce fed to the set decoder rejects with what it found — "
            + "they never cross-decode (the role-confusion drop's codec half).",
         .clipboardSet, Hex.string([0x1B] + Array(hello.utf8)),
         "unexpectedType"),
        ("announce-cross-type",
         "A set fed to the announce decoder rejects the same way.",
         .clipboardAnnounce, Hex.string([0x1A] + Array(hello.utf8)),
         "unexpectedType"),
        ("set-foreign-type", "A stranger's type byte (0x7F) rejects.",
         .clipboardSet, Hex.string([0x7F] + Array(hello.utf8)),
         "unexpectedType"),
        ("set-over-budget",
         "65,537 UTF-8 bytes reject — one byte past the ceiling.",
         .clipboardSet,
         Hex.string([0x1A] + [UInt8](
            repeating: 0x61, count: ClipboardWire.maxTextByteCount + 1
         )),
         "textOverBudget"),
        ("set-invalid-utf8-lone-byte",
         "0xFF is never valid UTF-8 — rejects, never replaces (a clipboard "
            + "must carry exactly what was copied or nothing).",
         .clipboardSet, "1a68ff69", "invalidUtf8"),
        ("announce-invalid-utf8-truncated-sequence",
         "A 2-byte sequence's lead byte (0xC3) with no continuation rejects.",
         .clipboardAnnounce, "1b61c3", "invalidUtf8"),
    ] {
        vectors.append(ClipboardVector(
            name: name, description: description,
            kind: .decodeReject, codec: codec,
            messageHex: hex, error: error
        ))
    }

    // MARK: Capability key 10 (the forward-compat spine as data)

    for (name, description, set) in [
        ("capability-key10-declared",
         "wireDefault's frozen encoding plus exactly the appended `0A F5` "
            + "entry (map head 0xA8 → 0xA9): the clipboardText accessor must "
            + "read true and the set must re-encode byte-exactly — the \"no "
            + "frozen bytes moved\" claim as data.",
         Capabilities.wireDefault.declaringClipboardText()),
        ("capability-key10-absent",
         "wireDefault's frozen encoding unchanged: absence reads false — "
            + "\"not supported\", never an error.",
         Capabilities.wireDefault),
        ("capability-key9-and-key10",
         "Both spine keys together: map head 0xAA with `09 F5 0A F5` "
            + "trailing in canonical order — the two features compose without "
            + "moving each other's bytes.",
         Capabilities.wireDefault.declaringHostAudioRouting()
            .declaringClipboardText()),
    ] {
        vectors.append(ClipboardVector(
            name: name, description: description,
            kind: .roundtrip, codec: .capabilitySet,
            messageHex: Hex.string(try set.encodeCbor()),
            clipboardText: set.clipboardText
        ))
    }

    return ClipboardVectorFile(vectors: vectors)
}
