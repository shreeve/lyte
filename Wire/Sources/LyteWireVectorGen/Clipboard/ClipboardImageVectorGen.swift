// Authors Vectors/clipboard-images-v1.json: the 0x22 cargo marker and
// the key-12 capability spine. Anchored by ClipboardImageCodecTests.

import LyteCore
import LyteWire
import LyteWireTestKit

public func makeClipboardImageVectorFile() throws -> ClipboardImageVectorFile {
    var vectors: [ClipboardImageVector] = []

    // MARK: Cargo-marker roundtrips

    let nominal = try ClipboardImageCargo(
        transferId: 0x0102_0304_0506_0708, mime: "image/png"
    )
    for (name, description, cargo) in [
        ("cargo-png-nominal",
         "type ‖ id u64 LE ‖ mimeLen u8 ‖ mime: [0x22] + 08…01 + [0x09] + "
            + "\"image/png\" — the hand-computed anchor.",
         nominal),
        ("cargo-max-id",
         "The u64 ceiling id (all FF) rides LE without precision loss — ids "
            + "ride as hex in this file for the same reason.",
         try ClipboardImageCargo(transferId: .max, mime: "image/png")),
        // A mime this build doesn't carry is legal at the codec:
        // unsupported-mime is channel policy, so a future format never
        // breaks old decoders.
        ("cargo-foreign-mime-wellformed",
         "A mime v2 does not carry still DECODES — unsupported-mime is "
            + "channel policy (abort declined), never a parse error, so "
            + "future formats stay speakable.",
         try ClipboardImageCargo(transferId: 0xCAFE, mime: "image/jxl")),
        // The u8 length field's exact top: "image/" + 249 a's.
        ("cargo-max-mime",
         "Exactly 255 mime bytes (\"image/\" + 249 × 'a') — the u8 length "
            + "ceiling is legal to the byte.",
         try ClipboardImageCargo(
            transferId: 0x0BAD_CAFE_0000_0001,
            mime: "image/" + String(repeating: "a", count: 249)
         )),
    ] {
        vectors.append(ClipboardImageVector(
            name: name, description: description,
            kind: .roundtrip, codec: .imageCargo,
            messageHex: Hex.string(cargo.encode()),
            transferIdHex: Hex.string(cargo.transferId, width: 16),
            mimeUtf8Hex: Hex.string(Array(cargo.mime.utf8))
        ))
    }

    // MARK: Decode rejects

    let nominalBytes = nominal.encode()
    for (name, description, bytes, error) in [
        ("cargo-empty-payload",
         "An empty payload rejects — no type byte to dispatch on.",
         [], "truncatedMessage"),
        ("cargo-truncated-header",
         "The type byte plus seven id bytes — one short of the fixed header.",
         Array(nominalBytes.prefix(8)), "truncatedMessage"),
        ("cargo-truncated-mime", "mimeLen promises more bytes than remain.",
         Array(nominalBytes.dropLast()), "truncatedMessage"),
        ("cargo-foreign-type",
         "A ClipboardSet's type byte (0x1A) rejects with what it found — "
            + "the marker never cross-decodes.",
         [0x1A] + Array(nominalBytes.dropFirst()), "unexpectedType"),
        ("cargo-trailing-bytes",
         "One byte past the mime rejects — exactly its layout.",
         nominalBytes + [0x00], "trailingBytes"),
        ("cargo-zero-transfer-id", "id 0 is always some layer's zero-fill bug.",
         [0x22] + [UInt8](repeating: 0, count: 8) + [0x09]
            + Array("image/png".utf8),
         "zeroTransferId"),
        ("cargo-empty-mime",
         "A mime-less marker is unroutable — v2 requires the format.",
         [0x22, 0x07, 0, 0, 0, 0, 0, 0, 0, 0x00], "emptyMime"),
        ("cargo-invalid-utf8-mime",
         "0xFF is never valid UTF-8 — rejects, never replaces.",
         [0x22, 0x07, 0, 0, 0, 0, 0, 0, 0, 0x01, 0xFF], "invalidUtf8"),
    ] as [(String, String, [UInt8], String)] {
        vectors.append(ClipboardImageVector(
            name: name, description: description,
            kind: .decodeReject, codec: .imageCargo,
            messageHex: Hex.string(bytes), error: error
        ))
    }

    // MARK: Encode rejects (wire-inexpressible bounds)

    vectors.append(ClipboardImageVector(
        name: "cargo-mime-over-budget",
        description: "256 mime bytes cannot ride a u8 length — "
            + "construction refuses (the wire form cannot even exist).",
        kind: .encodeReject, codec: .imageCargo,
        mimeUtf8Hex: Hex.string([UInt8](repeating: 0x61, count: 256)),
        error: "mimeOverBudget"
    ))

    // MARK: Capability key 12 (the forward-compat spine as data)

    for (name, description, set) in [
        ("capability-key12-declared",
         "wireDefault's frozen encoding plus exactly the appended `0C F5` "
            + "entry (map head 0xA8 → 0xA9): the clipboardImages accessor "
            + "must read true and the set must re-encode byte-exactly — the "
            + "\"no frozen bytes moved\" claim as data.",
         Capabilities.wireDefault.declaringClipboardImages()),
        ("capability-key12-absent",
         "wireDefault's frozen encoding unchanged: absence reads false — "
            + "\"not supported\", never an error.",
         Capabilities.wireDefault),
        ("capability-keys-10-11-12",
         "All three spine keys together: map head 0xAB with `0A F5 0B F5 0C "
            + "F5` trailing in canonical order — clipboard, file consent, and "
            + "image dialect compose without moving each other's bytes (the "
            + "image GATE is 10∧12; key 11 stays independent file consent).",
         Capabilities.wireDefault.declaringClipboardText()
            .declaringBulkTransfer().declaringClipboardImages()),
    ] {
        vectors.append(ClipboardImageVector(
            name: name, description: description,
            kind: .roundtrip, codec: .capabilitySet,
            messageHex: Hex.string(try set.encodeCbor()),
            clipboardImages: set.clipboardImages
        ))
    }

    return ClipboardImageVectorFile(vectors: vectors)
}
