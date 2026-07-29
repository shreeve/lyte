// Clipboard-image vector authoring (P-1, clipboard v2): the 0x22
// cargo marker and the key-12 capability spine — codecs born in the
// registry rather than promoted, frozen at their birth slice (the
// clipboard-v1 precedent). Run once, commit, freeze. The circularity
// is broken by the hand-computed anchor bytes in
// ClipboardImageCodecTests, which pin the same nominal message.

import Foundation
import LyteWire
import LyteWireTestKit

func makeClipboardImageVectorFile() throws -> ClipboardImageVectorFile {
    var vectors: [ClipboardImageVector] = []

    func hex(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }

    // MARK: Cargo-marker roundtrips

    let nominal = try ClipboardImageCargo(
        transferId: 0x0102_0304_0506_0708, mime: "image/png"
    )
    vectors.append(ClipboardImageVector(
        name: "cargo-png-nominal",
        description: "type ‖ id u64 LE ‖ mimeLen u8 ‖ mime: [0x22] + "
            + "08…01 + [0x09] + \"image/png\" — the hand-computed "
            + "anchor.",
        kind: .roundtrip, codec: .imageCargo,
        messageHex: Hex.string(nominal.encode()),
        transferIdHex: hex(nominal.transferId),
        mimeUtf8Hex: Hex.string(Array(nominal.mime.utf8))
    ))
    let maxId = try ClipboardImageCargo(
        transferId: .max, mime: "image/png"
    )
    vectors.append(ClipboardImageVector(
        name: "cargo-max-id",
        description: "The u64 ceiling id (all FF) rides LE without "
            + "precision loss — ids ride as hex in this file for the "
            + "same reason.",
        kind: .roundtrip, codec: .imageCargo,
        messageHex: Hex.string(maxId.encode()),
        transferIdHex: hex(maxId.transferId),
        mimeUtf8Hex: Hex.string(Array(maxId.mime.utf8))
    ))
    // A well-formed marker with a mime this build doesn't carry:
    // legal AT THE CODEC — unsupported-mime is channel policy
    // (abort(declined)), not a parse error, so a future format
    // never breaks old decoders.
    let foreign = try ClipboardImageCargo(
        transferId: 0xCAFE, mime: "image/jxl"
    )
    vectors.append(ClipboardImageVector(
        name: "cargo-foreign-mime-wellformed",
        description: "A mime v2 does not carry still DECODES — "
            + "unsupported-mime is channel policy (abort declined), "
            + "never a parse error, so future formats stay speakable.",
        kind: .roundtrip, codec: .imageCargo,
        messageHex: Hex.string(foreign.encode()),
        transferIdHex: hex(foreign.transferId),
        mimeUtf8Hex: Hex.string(Array(foreign.mime.utf8))
    ))
    // The 255-byte mime ceiling, legal to the byte: "image/" + 249
    // a's — the u8 length field's exact top.
    let ceilingMime = "image/" + String(repeating: "a", count: 249)
    let atCeiling = try ClipboardImageCargo(
        transferId: 0x0BAD_CAFE_0000_0001, mime: ceilingMime
    )
    vectors.append(ClipboardImageVector(
        name: "cargo-max-mime",
        description: "Exactly 255 mime bytes (\"image/\" + 249 × 'a') "
            + "— the u8 length ceiling is legal to the byte.",
        kind: .roundtrip, codec: .imageCargo,
        messageHex: Hex.string(atCeiling.encode()),
        transferIdHex: hex(atCeiling.transferId),
        mimeUtf8Hex: Hex.string(Array(ceilingMime.utf8))
    ))

    // MARK: Decode rejects

    vectors.append(ClipboardImageVector(
        name: "cargo-empty-payload",
        description: "An empty payload rejects — no type byte to "
            + "dispatch on.",
        kind: .decodeReject, codec: .imageCargo,
        messageHex: "",
        error: "truncatedMessage"
    ))
    vectors.append(ClipboardImageVector(
        name: "cargo-truncated-header",
        description: "The type byte plus seven id bytes — one short "
            + "of the fixed header.",
        kind: .decodeReject, codec: .imageCargo,
        messageHex: Hex.string(Array(nominal.encode().prefix(8))),
        error: "truncatedMessage"
    ))
    vectors.append(ClipboardImageVector(
        name: "cargo-truncated-mime",
        description: "mimeLen promises more bytes than remain.",
        kind: .decodeReject, codec: .imageCargo,
        messageHex: Hex.string(Array(nominal.encode().dropLast())),
        error: "truncatedMessage"
    ))
    vectors.append(ClipboardImageVector(
        name: "cargo-foreign-type",
        description: "A ClipboardSet's type byte (0x1A) rejects with "
            + "what it found — the marker never cross-decodes.",
        kind: .decodeReject, codec: .imageCargo,
        messageHex: Hex.string(
            [0x1A] + Array(nominal.encode().dropFirst())
        ),
        error: "unexpectedType"
    ))
    vectors.append(ClipboardImageVector(
        name: "cargo-trailing-bytes",
        description: "One byte past the mime rejects — exactly its "
            + "layout.",
        kind: .decodeReject, codec: .imageCargo,
        messageHex: Hex.string(nominal.encode() + [0x00]),
        error: "trailingBytes"
    ))
    vectors.append(ClipboardImageVector(
        name: "cargo-zero-transfer-id",
        description: "id 0 is always some layer's zero-fill bug.",
        kind: .decodeReject, codec: .imageCargo,
        messageHex: Hex.string(
            [0x22] + [UInt8](repeating: 0, count: 8)
                + [0x09] + Array("image/png".utf8)
        ),
        error: "zeroTransferId"
    ))
    vectors.append(ClipboardImageVector(
        name: "cargo-empty-mime",
        description: "A mime-less marker is unroutable — v2 requires "
            + "the format.",
        kind: .decodeReject, codec: .imageCargo,
        messageHex: Hex.string(
            [0x22, 0x07, 0, 0, 0, 0, 0, 0, 0, 0x00]
        ),
        error: "emptyMime"
    ))
    vectors.append(ClipboardImageVector(
        name: "cargo-invalid-utf8-mime",
        description: "0xFF is never valid UTF-8 — rejects, never "
            + "replaces.",
        kind: .decodeReject, codec: .imageCargo,
        messageHex: Hex.string(
            [0x22, 0x07, 0, 0, 0, 0, 0, 0, 0, 0x01, 0xFF]
        ),
        error: "invalidUtf8"
    ))

    // MARK: Encode rejects (wire-inexpressible bounds)

    vectors.append(ClipboardImageVector(
        name: "cargo-mime-over-budget",
        description: "256 mime bytes cannot ride a u8 length — "
            + "construction refuses (the wire form cannot even exist).",
        kind: .encodeReject, codec: .imageCargo,
        mimeUtf8Hex: Hex.string(
            [UInt8](repeating: 0x61, count: 256)
        ),
        error: "mimeOverBudget"
    ))

    // MARK: Capability key 12 (the forward-compat spine as data —
    // the key-10/key-11 files' precedent)

    vectors.append(ClipboardImageVector(
        name: "capability-key12-declared",
        description: "wireDefault's frozen encoding plus exactly the "
            + "appended `0C F5` entry (map head 0xA8 → 0xA9): the "
            + "clipboardImages accessor must read true and the set "
            + "must re-encode byte-exactly — the \"no frozen bytes "
            + "moved\" claim as data.",
        kind: .roundtrip, codec: .capabilitySet,
        messageHex: Hex.string(
            try Capabilities.wireDefault.declaringClipboardImages()
                .encodeCbor()
        ),
        clipboardImages: true
    ))
    vectors.append(ClipboardImageVector(
        name: "capability-key12-absent",
        description: "wireDefault's frozen encoding unchanged: "
            + "absence reads false — \"not supported\", never an "
            + "error.",
        kind: .roundtrip, codec: .capabilitySet,
        messageHex: Hex.string(try Capabilities.wireDefault.encodeCbor()),
        clipboardImages: false
    ))
    vectors.append(ClipboardImageVector(
        name: "capability-keys-10-11-12",
        description: "All three spine keys together: map head 0xAB "
            + "with `0A F5 0B F5 0C F5` trailing in canonical order — "
            + "clipboard, file consent, and image dialect compose "
            + "without moving each other's bytes (the image GATE is "
            + "10∧12; key 11 stays independent file consent).",
        kind: .roundtrip, codec: .capabilitySet,
        messageHex: Hex.string(
            try Capabilities.wireDefault
                .declaringClipboardText()
                .declaringBulkTransfer()
                .declaringClipboardImages()
                .encodeCbor()
        ),
        clipboardImages: true
    ))

    return ClipboardImageVectorFile(
        format: ClipboardImageVectorFile.expectedFormat,
        formatVersion: 1,
        wireVersion: Int(WireVersion.major),
        vectors: vectors
    )
}
